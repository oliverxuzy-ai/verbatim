import AppKit
import Foundation

/// "System Audio Recording" (kTCCServiceAudioCapture) has no public status
/// API, and a missing grant does not fail the tap: it just delivers silence.
/// Like AudioCap and anarlog, query and request it through the private TCC
/// framework so the app can tell the user before a meeting is lost.
nonisolated enum SystemAudioPermission {
    enum Status: Equatable {
        case granted, denied, notDetermined, unknown
    }

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the macOS prompt when undecided; returns whether access is granted.
    static func request() async -> Bool {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return status == .granted }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
