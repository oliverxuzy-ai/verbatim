import AVFAudio
import Foundation

/// Microphone capture through AVAudioEngine. With voice processing on,
/// Apple's echo canceller removes what the speakers play (the remote side of
/// the call) from the mic signal, so "Me" stays clean even without headphones.
nonisolated final class MicCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private let engine = AVAudioEngine()
    private var voiceProcessingOn = false
    private(set) var isRunning = false
    private var handler: Handler?
    private var observer: NSObjectProtocol?
    /// What the caller asked for; re-evaluated against the route on changes.
    private var echoCancellationRequested = false
    /// Toggling voice processing itself posts a configuration change; ignore
    /// changes right after a (re)start so one device switch can't loop.
    private var lastStart = Date.distantPast

    func start(voiceProcessing: Bool, handler: @escaping Handler) throws {
        self.handler = handler
        if observer == nil {
            echoCancellationRequested = voiceProcessing || echoCancellationRequested
            // The engine stops itself when the input device changes (AirPods
            // connect, a headset is plugged in). Re-arm on the new device.
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restartAfterDeviceChange() }
        }
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                input.isVoiceProcessingAGCEnabled = true
                voiceProcessingOn = true
            } catch {
                Log.audio.error("Voice processing unavailable, continuing without echo cancellation: \(error.localizedDescription)")
                voiceProcessingOn = false
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError.status("Microphone format", -1)
        }
        Log.audio.info("Mic format: \(format.sampleRate) Hz, \(format.channelCount) ch, VP=\(self.voiceProcessingOn)")

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let copy = buffer.deepCopy() else { return }
            let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            handler(copy, host)
        }
        engine.prepare()
        lastStart = .now
        do {
            try engine.start()
        } catch where voiceProcessingOn {
            // Some device combinations refuse the voice-processing unit; a
            // recording without echo cancellation beats no recording.
            Log.audio.error("Mic start failed with voice processing, retrying without: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            voiceProcessingOn = false
            try start(voiceProcessing: false, handler: handler)
            return
        }
        isRunning = true
    }

    var echoCancellationActive: Bool { voiceProcessingOn }

    private func restartAfterDeviceChange() {
        guard isRunning, let handler, Date.now.timeIntervalSince(lastStart) > 2 else { return }
        Log.audio.error("Audio device changed; restarting microphone capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        if voiceProcessingOn {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingOn = false
        }
        // Headphones now? Then echo cancellation is no longer needed.
        try? start(voiceProcessing: echoCancellationRequested && !AudioRouting.outputIsHeadphones(), handler: handler)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if voiceProcessingOn {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingOn = false
        }
        isRunning = false
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
}
