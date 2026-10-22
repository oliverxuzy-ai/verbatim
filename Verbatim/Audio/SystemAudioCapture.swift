import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything other apps play (Zoom, Meet in a browser, Teams…)
/// with a Core Audio process tap (macOS 14.2+). No virtual audio driver and
/// no screen recording permission: macOS asks once for "System Audio
/// Recording" access.
nonisolated final class SystemAudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.verbatim.system-audio", qos: .userInitiated)
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false
    /// IO proc invocations that delivered audio (diagnostics).
    let callbacks = Locked(0)

    /// `clockedByOutput`: add the output device as the aggregate's clock
    /// (AudioCap's layout). The tap-only aggregate is the default because it
    /// is what captured call audio on the user's Mac; the clocked variant is
    /// the fallback when no audio arrives.
    func start(clockedByOutput: Bool = false, handler: @escaping Handler) throws {
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Verbatim system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try CoreAudioError.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Read tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.status("Tap format", -1)
        }
        format = tapFormat
        Log.audio.info("System tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch, interleaved=\(tapFormat.isInterleaved)")

        // A private aggregate device around the tap. With an output device
        // added, its input streams (if any) come first in the buffer list;
        // the IO proc takes the trailing tap buffers either way.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verbatim Tap",
            kAudioAggregateDeviceUIDKey: "dev.verbatim.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        if clockedByOutput, let outputUID = AudioRouting.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice),
            "Create aggregate device"
        )
        aggregateID = aggregateDevice

        let channels = Int(tapFormat.channelCount)
        let counter = callbacks
        try CoreAudioError.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDevice, queue) { _, inputData, inputTime, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                guard list.count > 0 else { return }
                // Taps come after any sub-device streams, so take the last
                // buffers that match the tap's layout.
                let bytesPerFrame = Int(tapFormat.streamDescription.pointee.mBytesPerFrame)
                guard bytesPerFrame > 0 else { return }
                let frames: Int
                if tapFormat.isInterleaved {
                    frames = Int(list[list.count - 1].mDataByteSize) / bytesPerFrame
                } else {
                    frames = Int(list[list.count - 1].mDataByteSize) / bytesPerFrame
                }
                guard frames > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
                buffer.frameLength = AVAudioFrameCount(frames)
                let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let needed = tapFormat.isInterleaved ? 1 : channels
                let offset = max(0, list.count - needed)
                for i in 0..<min(needed, dst.count) where offset + i < list.count {
                    let src = list[offset + i]
                    guard let s = src.mData, let d = dst[i].mData else { continue }
                    let bytes = min(src.mDataByteSize, dst[i].mDataByteSize)
                    memcpy(d, s, Int(bytes))
                }
                let host = inputTime.pointee.mFlags.contains(.hostTimeValid)
                    ? inputTime.pointee.mHostTime : mach_absolute_time()
                counter.withLock { $0 += 1 }
                handler(buffer, host)
            },
            "Create IO proc"
        )
        try CoreAudioError.check(AudioDeviceStart(aggregateDevice, procID), "Start aggregate device")
        isRunning = true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    deinit { stop() }

    /// The Core Audio process object for this app, so our own sounds are not
    /// recorded. Returns nil if the app has not touched audio yet.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
