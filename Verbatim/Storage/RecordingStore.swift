import AVFAudio
import Foundation
import Observation

/// Recordings live as plain folders so they are easy to inspect and back up:
/// ~/Library/Application Support/Verbatim/Recordings/<uuid>/
///   recording.json, mic.m4a, system.m4a (Apple Lossless)
@Observable
final class RecordingStore {
    private(set) var recordings: [Recording] = []

    let rootURL: URL

    init(rootURL: URL? = nil) {
        let base = rootURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        self.rootURL = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for id: UUID, channel: AudioChannel) -> URL {
        folder(for: id).appendingPathComponent("\(channel.rawValue).m4a")
    }

    /// Crash-safe PCM written while recording; compressed into audioURL on stop.
    func liveAudioURL(for id: UUID, channel: AudioChannel) -> URL {
        folder(for: id).appendingPathComponent("\(channel.rawValue).caf")
    }

    /// Compress a finished recording's live audio files. A continued
    /// recording's new part is appended to the audio already saved.
    nonisolated static func finalizeAudio(in folder: URL) {
        for channel in AudioChannel.allCases {
            let caf = folder.appendingPathComponent("\(channel.rawValue).caf")
            guard FileManager.default.fileExists(atPath: caf.path) else { continue }
            let m4a = folder.appendingPathComponent("\(channel.rawValue).m4a")
            do {
                let saved = hasSavedAudio(m4a) ? [m4a] : []
                try AudioFileSink.compress(saved + [caf], to: m4a)
            } catch {
                Log.audio.error("Compressing \(caf.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a channel already has audio saved (a valid file with frames).
    nonisolated static func hasSavedAudio(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && AudioFileSink.seconds(url) > 0
    }

    /// Recordings interrupted by a crash, a force quit or a hang: add what
    /// the transcript journal has beyond the last autosave, compress leftover
    /// audio and close them at the length of what was captured. Returns the
    /// recovered recordings.
    @discardableResult
    func recoverInterrupted(except liveID: UUID?, myName: String = "Me") -> [Recording] {
        var recovered: [Recording] = []
        for var rec in recordings where rec.endedAt == nil && rec.id != liveID {
            let folder = folder(for: rec.id)
            // A continued recording: channels that had audio before the
            // continue keep their file offsets (see ContinuationPlan).
            let saved: Set<AudioChannel> = rec.continuations == nil ? [] : Set(AudioChannel.allCases.filter { Self.hasSavedAudio(audioURL(for: rec.id, channel: $0)) })
            let merged = JournalRecovery.merge(TranscriptJournal.read(in: folder), into: rec, myName: myName, savedChannels: saved)
            rec = merged.recording
            Self.finalizeAudio(in: folder)
            // The mic file covers the whole timeline (also across a continue).
            let mic = audioURL(for: rec.id, channel: .mic)
            let audioEnd = Self.hasSavedAudio(mic) ? AudioFileSink.seconds(mic) + (rec.channelOffsets?[AudioChannel.mic.rawValue] ?? 0) : 0
            let lastLine = rec.segments.map(\.end).max() ?? 0
            rec.endedAt = rec.startedAt.addingTimeInterval(rec.unrecordedTime + max(audioEnd, lastLine))
            let note = merged.replayed > 0
                ? "Verbatim quit unexpectedly while recording. The transcript was restored from the autosave plus \(merged.replayed) lines from the crash journal."
                : "Verbatim quit unexpectedly while recording. The transcript was restored from the autosave."
            rec.diagnostics = (rec.diagnostics ?? []) + [note]
            save(rec)
            TranscriptJournal.remove(in: folder)
            recovered.append(rec)
            Log.app.info("Recovered interrupted recording \(rec.id) (\(merged.replayed) lines from the journal)")
        }
        return recovered
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Recording] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: file),
                  let rec = try? Self.decoder.decode(Recording.self, from: data) else { continue }
            loaded.append(rec)
        }
        recordings = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    /// Insert or replace in memory and persist to disk.
    func save(_ recording: Recording) {
        if let i = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[i] = recording
        } else {
            recordings.insert(recording, at: 0)
            recordings.sort { $0.startedAt > $1.startedAt }
        }
        persist(recording)
    }

    /// Write to disk without touching the in-memory list (used for autosave
    /// while a recording is live and the UI reads the live model instead).
    /// Waits for any background autosave still queued, so an older snapshot
    /// can never land on top of this one.
    func persist(_ recording: Recording) {
        let dir = folder(for: recording.id)
        writeQueue.sync { Self.write(recording, to: dir) }
    }

    /// Autosave without blocking the main thread: a long meeting's JSON takes
    /// a while to encode. Writes stay in order with `persist` and `save`.
    func persistInBackground(_ recording: Recording) {
        let dir = folder(for: recording.id)
        writeQueue.async { Self.write(recording, to: dir) }
    }

    private let writeQueue = DispatchQueue(label: "dev.verbatim.store", qos: .utility)

    nonisolated private static func write(_ recording: Recording, to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(recording)
            try data.write(to: dir.appendingPathComponent("recording.json"), options: .atomic)
        } catch {
            Log.app.error("Failed to save recording \(recording.id): \(error.localizedDescription)")
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.trashItem(at: folder(for: id), resultingItemURL: nil)
        recordings.removeAll { $0.id == id }
    }

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
