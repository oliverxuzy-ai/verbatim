import CoreAudio
import Foundation

nonisolated enum AudioRouting {
    /// True when the default output is headphones (wired or Bluetooth), in
    /// which case the mic cannot hear the remote side and echo cancellation
    /// is unnecessary.
    static func outputIsHeadphones() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let transport: UInt32 = property(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        if transport == kAudioDeviceTransportTypeBuiltIn {
            let source: UInt32? = property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            return source == 0x6864_706E // 'hdpn'
        }
        return false
    }

    /// The pid of another app that is capturing audio input right now (the
    /// browser or app running the call), or nil when nobody else is.
    /// Turning on voice processing reconfigures the shared built-in mic: the
    /// other app's stream is stopped and restarted and the mic's hardware
    /// processing switches mode, so the other side hears you drop out or go
    /// quiet for a few seconds. Callers skip voice processing when this is set.
    static func otherProcessCapturingInput() -> pid_t? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            let capturing: UInt32 = property(process, kAudioProcessPropertyIsRunningInput, scope: kAudioObjectPropertyScopeGlobal) ?? 0
            guard capturing != 0 else { continue }
            let pid: pid_t = property(process, kAudioProcessPropertyPID, scope: kAudioObjectPropertyScopeGlobal) ?? -1
            if pid > 0, pid != me { return pid }
        }
        return nil
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func defaultOutputUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Calls `onChange` (on the main queue) when the default output device
    /// changes, e.g. AirPods connect mid-meeting. Returns a token to cancel.
    static func observeDefaultOutput(_ onChange: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return block
    }

    static func stopObservingDefaultOutput(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    static func defaultOutputName() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }
}
