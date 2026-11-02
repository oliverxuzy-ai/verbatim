import Foundation

/// Crash and hang protection for the live transcript.
///
/// Every engine result is appended to `transcript.journal` (one JSON object
/// per line) the moment the engine delivers it, on a background queue that
/// never waits for the main thread. recording.json is only autosaved every
/// few seconds from the main thread, so after a crash, a force quit or a
/// frozen window it can be behind; on the next launch `JournalRecovery`
/// replays whatever the journal has beyond it. A clean stop deletes the
/// journal.
nonisolated final class TranscriptJournal: @unchecked Sendable {
    static let fileName = "transcript.journal"

    nonisolated struct Entry: Codable, Sendable, Equatable {
        nonisolated enum Kind: String, Codable, Sendable {
            /// A finalized engine result.
            case result = "final"
            /// The latest still-changing text, so the last words before a
            /// crash survive even if the engine never finalized them.
            case partial = "volatile"
            /// The channel's offset in recording time (stored in `start`).
            case offset
        }

        var kind: Kind
        var channel: AudioChannel
        /// Seconds in the channel's own audio, like `EngineResult`.
        var start: Double = 0
        var end: Double = 0
        var text: String = ""
        var speaker: String?
        var words: [TimedWord]?

        var result: EngineResult {
            EngineResult(start: start, end: end, text: text, words: words ?? [], speaker: speaker)
        }
    }

    let url: URL
    /// A partial is journaled at most this often per channel.
    static let partialInterval: TimeInterval = 1

    private let queue = DispatchQueue(label: "dev.verbatim.journal", qos: .utility)
    // Touched only on `queue`.
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var lastSync = Date.distantPast
    private var closed = false

    private let lastPartial = Locked<[AudioChannel: (text: String, at: Date)]>([:])
    private let lastOffset = Locked<[AudioChannel: Double]>([:])

    init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
    }

    /// Called from the engine's own thread for every update.
    func record(_ update: EngineUpdate, channel: AudioChannel) {
        var entries = update.finals.filter { !$0.text.trimmed.isEmpty }.map {
            Entry(kind: .result, channel: channel, start: $0.start, end: $0.end,
                  text: $0.text, speaker: $0.speaker, words: $0.words.isEmpty ? nil : $0.words)
        }
        if !entries.isEmpty { lastPartial.withLock { $0[channel] = nil } }
        if let v = update.volatile, !v.text.trimmed.isEmpty, takePartial(v.text, channel: channel) {
            entries.append(Entry(kind: .partial, channel: channel, start: v.start, end: v.end, text: v.text, speaker: v.speaker))
        }
        append(entries)
    }

    func noteOffset(_ offset: Double, for channel: AudioChannel) {
        let changed = lastOffset.withLock { known -> Bool in
            if let old = known[channel], abs(old - offset) < 0.001 { return false }
            known[channel] = offset
            return true
        }
        if changed { append([Entry(kind: .offset, channel: channel, start: offset)]) }
    }

    private func takePartial(_ text: String, channel: AudioChannel) -> Bool {
        let now = Date.now
        return lastPartial.withLock { last in
            if let prev = last[channel], prev.text == text || now.timeIntervalSince(prev.at) < Self.partialInterval {
                return false
            }
            last[channel] = (text, now)
            return true
        }
    }

    private func append(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            var data = Data()
            for entry in entries {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            do {
                let h = try openHandle()
                try h.write(contentsOf: data)
                // A crash or force quit keeps everything already written;
                // syncing now and then also survives a power loss.
                if Date.now.timeIntervalSince(lastSync) > 5 {
                    try? h.synchronize()
                    lastSync = .now
                }
            } catch {
                Log.app.error("Transcript journal write failed: \(error.localizedDescription)")
            }
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }

    /// Wait until everything recorded so far is on disk.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// After a clean stop recording.json is complete; the journal can go.
    func discard() {
        queue.sync {
            closed = true
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Every complete line of a recording's journal. A line cut short by a
    /// crash is skipped.
    static func read(in folder: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    static func remove(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
    }
}

/// Rebuilds the part of an interrupted recording's transcript that never
/// reached recording.json, by replaying its journal through the same
/// `LiveTranscript` logic the live session uses.
enum JournalRecovery {
    /// The recording with the missing lines added, and how many engine
    /// results were replayed.
    static func merge(_ entries: [TranscriptJournal.Entry], into recording: Recording, myName: String) -> (recording: Recording, replayed: Int) {
        guard !entries.isEmpty else { return (recording, 0) }

        var offsets: [AudioChannel: Double] = [:]
        for channel in AudioChannel.allCases { offsets[channel] = recording.channelOffsets?[channel.rawValue] }
        for entry in entries where entry.kind == .offset { offsets[entry.channel] = entry.start }

        let soniox = recording.engine == EngineKind.soniox.rawValue
        let live = LiveTranscript(recording: recording, myName: myName)
        live.configure(.mic, .init(
            offset: offsets[.mic] ?? 0,
            fixedSpeaker: recording.micMode == .solo ? Speaker.meID : nil,
            engineDiarizes: soniox && recording.micMode == .room,
            fallbackLabel: "In room"
        ))
        live.configure(.system, .init(
            offset: offsets[.system] ?? 0,
            engineDiarizes: soniox,
            fallbackLabel: "Speaker"
        ))

        // How far each channel already got in recording.json. Results on a
        // channel arrive in order and don't overlap, so one that starts
        // before that point was already committed.
        var covered: [AudioChannel: Double] = [:]
        for segment in recording.segments {
            covered[segment.channel] = max(covered[segment.channel] ?? -.infinity, segment.end)
        }
        func isMissing(_ entry: TranscriptJournal.Entry) -> Bool {
            entry.start + (offsets[entry.channel] ?? 0) >= (covered[entry.channel] ?? -.infinity) - 0.001
        }

        var replayed = 0
        var lastPartial: [AudioChannel: (index: Int, entry: TranscriptJournal.Entry)] = [:]
        var lastFinal: [AudioChannel: Int] = [:]
        for (index, entry) in entries.enumerated() {
            switch entry.kind {
            case .offset:
                continue
            case .partial:
                lastPartial[entry.channel] = (index, entry)
            case .result:
                lastFinal[entry.channel] = index
                guard isMissing(entry) else { continue }
                live.apply(EngineUpdate(finals: [entry.result]), channel: entry.channel)
                replayed += 1
            }
        }
        // Words still being recognized when the app went down.
        let tails = lastPartial.values
            .filter { $0.index > (lastFinal[$0.entry.channel] ?? -1) && isMissing($0.entry) }
            .sorted { $0.index < $1.index }
        for tail in tails {
            live.apply(EngineUpdate(finals: [tail.entry.result]), channel: tail.entry.channel)
            replayed += 1
        }
        live.finalizeLive()

        var out = live.recording
        if !offsets.isEmpty {
            out.channelOffsets = Dictionary(uniqueKeysWithValues: offsets.map { ($0.key.rawValue, $0.value) })
        }
        return (out, replayed)
    }
}
