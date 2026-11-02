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

    /// Recordings interrupted by a crash or force quit: compress leftover
    /// audio and close them at the length of what was captured.
    func recoverInterrupted(except liveID: UUID?) {
        for var rec in recordings where rec.endedAt == nil && rec.id != liveID {
            let folder = folder(for: rec.id)
            Self.finalizeAudio(in: folder)
            // The mic file covers the whole timeline (also across a continue).
            let mic = audioURL(for: rec.id, channel: .mic)
            let seconds = Self.hasSavedAudio(mic)
                ? (rec.channelOffsets?[AudioChannel.mic.rawValue] ?? 0) + AudioFileSink.seconds(mic)
                : rec.segments.map(\.end).max() ?? 0
            rec.endedAt = rec.startedAt.addingTimeInterval(rec.unrecordedTime + seconds)
            save(rec)
            Log.app.info("Recovered interrupted recording \(rec.id)")
        }
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
    func persist(_ recording: Recording) {
        let dir = folder(for: recording.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(recording)
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
