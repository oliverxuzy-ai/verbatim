import Foundation

/// How "Continue recording" lines new audio up with a finished recording.
///
/// The new part starts on the timeline exactly where the recording stopped;
/// the time in between isn't recorded (`Recording.continuations`). Each
/// channel's file keeps one timeline: the new audio is appended to the saved
/// file, after silence covering the moment between the stop and its first
/// new sample. A channel with nothing saved yet starts its file where its
/// first new audio lands, just like in a fresh recording.
nonisolated struct ContinuationPlan: Sendable, Equatable {
    /// Recording time where the new part starts (the old part's length).
    let base: TimeInterval
    /// Where each channel's saved file ends, in recording time. Only
    /// channels that already have audio saved.
    let fileEnds: [AudioChannel: TimeInterval]
    /// File start offsets as saved before continuing.
    let savedOffsets: [String: Double]

    /// `savedSeconds`: length of each channel's saved audio file (0 or
    /// missing when there is none).
    init(recording: Recording, savedSeconds: [AudioChannel: TimeInterval]) {
        base = recording.duration
        savedOffsets = recording.channelOffsets ?? [:]
        var ends: [AudioChannel: TimeInterval] = [:]
        for (channel, seconds) in savedSeconds where seconds > 0 {
            ends[channel] = (savedOffsets[channel.rawValue] ?? 0) + seconds
        }
        fileEnds = ends
    }

    /// Offsets to save once the new part is recorded. `live` holds where each
    /// channel's new audio started (recording time). Saved files keep their
    /// start; a channel heard for the first time starts at its new audio.
    func fileOffsets(live: [String: Double]) -> [String: Double] {
        var out = live
        for channel in fileEnds.keys {
            out[channel.rawValue] = savedOffsets[channel.rawValue] ?? 0
        }
        return out
    }

    /// The recording as it is while the new part records: open again, with
    /// the unrecorded gap noted.
    func reopened(_ recording: Recording, at now: Date) -> Recording {
        var rec = recording
        let gap = max(0, now.timeIntervalSince(recording.endedAt ?? now))
        rec.continuations = (rec.continuations ?? []) + [Recording.Continuation(at: base, gap: gap)]
        rec.endedAt = nil
        rec.refinedAt = nil
        return rec
    }

    /// Speaker keys for the new part get their own namespace, so a new voice
    /// labelled "1" by a fresh diarizer isn't merged into the old part's
    /// speaker "1" (often a different person). Refine re-clusters the whole
    /// meeting afterwards.
    static func labelPrefix(for recording: Recording) -> String {
        "p\((recording.continuations?.count ?? 0) + 2)."
    }
}
