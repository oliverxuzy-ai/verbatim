import AVFAudio
import Foundation

/// One audio channel's processing chain, run on its own serial queue:
/// capture buffer → mono → level meter → 16 kHz → file + transcriber + diarizer.
nonisolated final class ChannelPipeline: @unchecked Sendable {
    let channel: AudioChannel
    private let policy: MonoPolicy
    private let queue: DispatchQueue
    private let converter = StreamConverter(to: AudioFormats.mono16k)
    private let sink: AudioFileSink?
    private let transcriber: StreamingTranscriber?
    private let diarizer: LiveDiarizer?

    private let meter = Locked(Meter())
    /// While paused, audio is replaced by silence so every timeline (files,
    /// engines, diarizer) keeps running in step with the wall clock.
    let paused = Locked(false)
    private let firstHostTime = Locked<UInt64?>(nil)

    private struct Meter {
        var level: Float = 0
        var peakSinceRead: Float = 0
        var seconds: Double = 0
        var voicedSeconds: Double = 0
    }

    init(channel: AudioChannel, policy: MonoPolicy, sink: AudioFileSink?, transcriber: StreamingTranscriber?, diarizer: LiveDiarizer?) {
        self.channel = channel
        self.policy = policy
        self.sink = sink
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.queue = DispatchQueue(label: "dev.verbatim.pipeline.\(channel.rawValue)", qos: .userInitiated)
    }

    func ingest(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let box = SendableBuffer(buffer: buffer)
        queue.async { [self] in
            firstHostTime.withLock { if $0 == nil { $0 = hostTime } }
            guard let mono = box.buffer.monoFloat(policy) else { return }
            if paused.current, let data = mono.floatChannelData?[0] {
                data.update(repeating: 0, count: Int(mono.frameLength))
            }
            updateMeter(mono)
            guard let normalized = converter.convert(mono) else { return }
            sink?.write(normalized)
            transcriber?.feed(normalized)
            diarizer?.feed(normalized)
        }
    }

    private func updateMeter(_ buffer: AVAudioPCMBuffer) {
        let db = buffer.rmsDecibels()
        // Map -60…0 dBFS to 0…1 with a gentle curve so speech fills the bars.
        let norm = Float(max(0, min(1, (Double(db) + 60) / 60)))
        let shaped = pow(norm, 1.6)
        meter.withLock { m in
            m.level = shaped > m.level ? m.level * 0.3 + shaped * 0.7 : m.level * 0.8 + shaped * 0.2
            m.peakSinceRead = max(m.peakSinceRead, shaped)
            m.seconds += buffer.duration
            if db > -45 { m.voicedSeconds += buffer.duration }
        }
    }

    /// Smoothed level for the UI (0…1). Reading resets the peak hold.
    func readLevel() -> Float {
        meter.withLock { m in
            let v = max(m.level, m.peakSinceRead * 0.85)
            m.peakSinceRead = 0
            return v
        }
    }

    /// Seconds of audio with a non-trivial signal (used to warn when system
    /// audio permission was denied, which yields pure silence).
    var voicedSeconds: Double { meter.withLock { $0.voicedSeconds } }
    var receivedSeconds: Double { meter.withLock { $0.seconds } }

    var startHostTime: UInt64? { firstHostTime.current }

    /// Wait until everything queued so far has been processed.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
    }

    func finish() async {
        await drain()
        await transcriber?.finish()
        await diarizer?.finish()
        sink?.close()
    }
}
