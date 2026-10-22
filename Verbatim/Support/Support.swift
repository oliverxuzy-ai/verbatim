import Foundation
import OSLog
import Security

nonisolated enum Log {
    static let app = Logger(subsystem: "dev.verbatim.app", category: "app")
    static let audio = Logger(subsystem: "dev.verbatim.app", category: "audio")
    static let asr = Logger(subsystem: "dev.verbatim.app", category: "asr")
    static let calendar = Logger(subsystem: "dev.verbatim.app", category: "calendar")
    static let notion = Logger(subsystem: "dev.verbatim.app", category: "notion")
}

/// API secrets in a private file (~/Library/Application Support/Verbatim/
/// secrets.json, mode 0600). The login keychain ties item access to the
/// exact code signature, so a locally built app asked for the user's
/// password after every rebuild (and even a "no UI" read of an old item
/// raised the dialog); a user-only file avoids the keychain entirely.
nonisolated enum Keychain {
    private static let cache = Locked<[String: String]?>(nil)

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim/secrets.json")
    }

    static func get(_ account: String) -> String? {
        load()[account]
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        var all = load()
        if let value, !value.isEmpty { all[account] = value } else { all.removeValue(forKey: account) }
        cache.withLock { $0 = all }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    private static func load() -> [String: String] {
        if let cached = cache.current { return cached }
        let data = try? Data(contentsOf: fileURL)
        let all = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        cache.withLock { $0 = all }
        return all
    }
}

nonisolated enum SecretKey {
    static let notionToken = "notion.token"
    static let sonioxKey = "soniox.apiKey"
    static let anthropicKey = "anthropic.apiKey"
    static let googleClientID = "google.clientID"
    static let googleClientSecret = "google.clientSecret"
    static let googleRefreshToken = "google.refreshToken"
    static let googleEmail = "google.email"
}

/// A small thread-safe box for state shared with audio callbacks.
nonisolated final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
