@preconcurrency import AVFAudio
import Accelerate
import CoreAudio
import Foundation

nonisolated enum AudioFormats {
    /// Canonical internal format: 16 kHz mono Float32. Every channel is
    /// normalized to this once, then engines adapt it to what they need.
    static let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func hostTimeToSeconds(_ hostTime: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(hostTime) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    static var nowHostSeconds: Double { hostTimeToSeconds(mach_absolute_time()) }
}

/// Wrapper to move a buffer across concurrency domains. Buffers are copied
/// out of real-time callbacks before being wrapped, so ownership is unique.
nonisolated struct SendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

nonisolated extension AVAudioPCMBuffer {
    /// Deep copy (callbacks hand out buffers that are only valid briefly).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameLength, 1)) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let bytes = min(src[i].mDataByteSize, dst[i].mDataByteSize)
            memcpy(d, s, Int(bytes))
            dst[i].mDataByteSize = bytes
        }
        return copy
    }

    /// Mono Float32 at the same sample rate. `channelPolicy` picks how
    /// multi-channel input is reduced.
    func monoFloat(_ policy: MonoPolicy) -> AVAudioPCMBuffer? {
        let frames = Int(frameLength)
        guard frames > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)

        if format.commonFormat == .pcmFormatFloat32, let src = floatChannelData {
            if format.isInterleaved {
                let p = src[0]
                switch policy {
                case .firstChannel:
                    for i in 0..<frames { dst[i] = p[i * channels] }
                case .average:
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += p[i * channels + c] }
                        dst[i] = sum / Float(channels)
                    }
                }
            } else {
                switch policy {
                case .firstChannel:
                    memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                case .average:
                    memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                    if channels > 1 {
                        for c in 1..<channels { vDSP_vadd(dst, 1, src[c], 1, dst, 1, vDSP_Length(frames)) }
                        var scale = 1 / Float(channels)
                        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
                    }
                }
            }
            return out
        }
        if format.commonFormat == .pcmFormatInt16, let src = int16ChannelData {
            let scale = Float(1) / Float(Int16.max)
            let stride = format.isInterleaved ? channels : 1
            let p = src[0]
            for i in 0..<frames { dst[i] = Float(p[i * stride]) * scale }
            return out
        }
        return nil
    }

    /// RMS level of the first channel in dBFS.
    func rmsDecibels() -> Float {
        guard let data = floatChannelData?[0], frameLength > 0 else { return -160 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(frameLength))
        return 20 * log10(max(rms, 1e-8))
    }

    var duration: Double { Double(frameLength) / format.sampleRate }
}

nonisolated enum MonoPolicy: Sendable {
    /// Use channel 0 (voice-processed mic output lives there).
    case firstChannel
    /// Average all channels (stereo system mix).
    case average
}

/// Streaming sample-rate / format converter. Not thread-safe: call it from a
/// single serial queue per stream.
nonisolated final class StreamConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(to outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        // The input block runs synchronously inside convert(), on this thread.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            Log.audio.error("Conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}

/// Writes the normalized 16 kHz mono stream while recording. Plain 16-bit
/// PCM in CAF stays readable even if the app dies mid-meeting (a compressed
/// m4a without its trailer is unreadable); it is compressed to Apple
/// Lossless when the recording stops.
nonisolated final class AudioFileSink: @unchecked Sendable {
    private var file: AVAudioFile?
    let url: URL

    init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        do { try file?.write(from: buffer) } catch {
            Log.audio.error("Audio write failed: \(error.localizedDescription)")
        }
    }

    func close() {
        file?.close()
        file = nil
    }

    /// A valid, zero-length live file (tests and failed captures).
    static func makeEmpty(at url: URL) {
        (try? AudioFileSink(url: url))?.close()
    }

    /// Re-encode a recording to Apple Lossless (16 kHz mono, about 60 MB/h)
    /// and remove the source on success.
    static func compress(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 64_000) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: 64_000)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        output.close()
        try FileManager.default.removeItem(at: source)
    }
}

nonisolated enum CoreAudioError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(what, code): "\(what) failed (OSStatus \(code))"
        }
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError.status(what, status) }
    }
}
