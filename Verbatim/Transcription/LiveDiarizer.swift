import AVFAudio
import FluidAudio
import Foundation

/// Streaming on-device speaker diarization (FluidAudio LS-EEND, CoreML).
/// Keeps a 10 Hz track of "who is speaking" so transcript words can be
/// assigned to speakers by their timestamps.
nonisolated final class LiveDiarizer: @unchecked Sendable {
    enum Variant: Sendable {
        /// Remote call audio: broad, up to 10 speakers.
        case call
        /// A microphone in a meeting room.
        case room
    }

    private let variant: Variant
    private let model: LSEENDVariant
    private var diarizer: LSEENDDiarizer?
    private let queue = DispatchQueue(label: "dev.verbatim.diarizer", qos: .utility)
    private let track = Locked(Track())

    private struct Track {
        var frameDuration: Double = 0.1
        /// Speaker index per frame, -1 for silence.
        var labels: [Int8] = []
    }

    init(variant: Variant, model: LSEENDVariant = .dihard3) {
        self.variant = variant
        self.model = model
    }

    /// Loads (and on first use downloads) the CoreML model. The DIHARD III
    /// variant is used for both channels: on a single far-field mic with
    /// reverb the AMI variant collapsed four speakers into one, while
    /// DIHARD III attributed every turn correctly (RoomDiarizationTests).
    func prepare() async throws {
        let d = try await LSEENDDiarizer(variant: model)
        let frameHz = d.modelFrameHz ?? 10
        track.withLock { $0.frameDuration = 1 / frameHz }
        queue.sync { self.diarizer = d }
    }

    var isReady: Bool { queue.sync { diarizer != nil } }

    /// Feed 16 kHz mono Float32 audio.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        queue.async { [weak self] in
            guard let self, let diarizer = self.diarizer else { return }
            do {
                try diarizer.addAudio(samples, sourceSampleRate: 16_000)
                if let update = try diarizer.process() {
                    self.record(update.chunkResult, speakers: diarizer.numSpeakers ?? 1)
                }
            } catch {
                Log.asr.error("Diarizer error: \(error.localizedDescription)")
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                if let self, let diarizer = self.diarizer {
                    if let update = try? diarizer.finalizeSession() {
                        self.record(update.chunkResult, speakers: diarizer.numSpeakers ?? 1)
                    }
                }
                c.resume()
            }
        }
    }

    private func record(_ chunk: DiarizerChunkResult, speakers: Int) {
        guard chunk.finalizedFrameCount > 0, speakers > 0 else { return }
        var labels = [Int8](repeating: -1, count: chunk.finalizedFrameCount)
        for f in 0..<chunk.finalizedFrameCount {
            var best = -1
            var bestP: Float = 0.5
            for s in 0..<speakers {
                let p = chunk.probability(speaker: s, frame: f, numSpeakers: speakers)
                if p > bestP { bestP = p; best = s }
            }
            labels[f] = Int8(best)
        }
        track.withLock { t in
            let start = chunk.startFrame
            if t.labels.count < start { t.labels.append(contentsOf: repeatElement(-1, count: start - t.labels.count)) }
            for (i, l) in labels.enumerated() {
                let idx = start + i
                if idx < t.labels.count { t.labels[idx] = l } else { t.labels.append(l) }
            }
        }
    }

    /// Seconds of audio with finalized speaker decisions.
    var coveredUntil: Double {
        track.withLock { Double($0.labels.count) * $0.frameDuration }
    }

    /// Majority speaker over [start, end]; falls back to the nearest labeled
    /// frame within one second when the span itself is marked silent.
    func speaker(from start: Double, to end: Double) -> Int? {
        track.withLock { t in
            guard !t.labels.isEmpty else { return nil }
            let a = max(0, Int((start / t.frameDuration).rounded(.down)))
            let b = min(t.labels.count - 1, Int((end / t.frameDuration).rounded(.up)))
            if a <= b {
                var counts: [Int8: Int] = [:]
                for i in a...b where t.labels[i] >= 0 { counts[t.labels[i], default: 0] += 1 }
                if let best = counts.max(by: { $0.value < $1.value }) { return Int(best.key) }
            }
            let radius = Int(1.0 / t.frameDuration)
            let center = min(max(0, (a + b) / 2), t.labels.count - 1)
            for d in 1...max(1, radius) {
                for i in [center - d, center + d] where i >= 0 && i < t.labels.count && t.labels[i] >= 0 {
                    return Int(t.labels[i])
                }
            }
            return nil
        }
    }

    /// Download models ahead of the first meeting.
    static func warmUp() async {
        do { try await LiveDiarizer(variant: .call).prepare() } catch {
            Log.asr.error("Diarizer warm-up failed: \(error.localizedDescription)")
        }
    }
}
