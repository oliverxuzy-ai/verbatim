import AppKit
import CryptoKit
import Foundation
import Observation

// Self-update from GitHub Releases. Verbatim is ad-hoc signed (no Apple
// Developer ID), so it can't use the Mac App Store or a notarized update
// feed. Instead it reads the latest release, downloads the DMG the release
// workflow attaches, checks it against GitHub's SHA-256 digest, and swaps
// the app bundle in place while Verbatim isn't in use. Files downloaded by
// the app itself carry no quarantine flag, so the new copy opens without the
// "unverified developer" prompt, and privacy grants survive because the
// designated requirement is the bundle identifier (see project.yml).

/// A dotted release version such as "0.5.1". A leading "v" (as in git tags)
/// is ignored; anything else non-numeric (e.g. "0.6.0-beta") is rejected.
nonisolated struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let parts: [Int]

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        var parts: [Int] = []
        for piece in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// The version of the running app.
    static var running: AppVersion {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
            ?? AppVersion("0")!
    }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> [(Int, Int)] {
        let n = max(a.parts.count, b.parts.count)
        return (0..<n).map { (i: Int) in
            (i < a.parts.count ? a.parts[i] : 0, i < b.parts.count ? b.parts[i] : 0)
        }
    }

    /// "0.6" and "0.6.0" are the same version.
    static func == (a: AppVersion, b: AppVersion) -> Bool {
        padded(a, b).allSatisfy { $0.0 == $0.1 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for (x, y) in padded(a, b) where x != y { return x < y }
        return false
    }
}

/// The parts of GitHub's release JSON the updater needs.
nonisolated struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let browserDownloadURL: URL
        /// "sha256:<hex>", computed by GitHub on upload.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A newer release with a DMG the updater can install.
nonisolated struct AvailableUpdate: Equatable, Sendable {
    let version: AppVersion
    let dmgURL: URL
    let size: Int
    /// Lowercase hex, when GitHub published a digest for the DMG.
    let sha256: String?
    let releaseURL: URL
    let notes: String

    /// Nil when the release isn't newer than `current`, is a draft or
    /// pre-release, or has no DMG attached.
    static func from(_ release: GitHubRelease, current: AppVersion) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tagName), version > current else { return nil }
        let dmgs = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard let asset = dmgs.first(where: { $0.name == "Verbatim-\(version).dmg" }) ?? dmgs.first else { return nil }
        let sha = asset.digest.flatMap { digest -> String? in
            guard digest.lowercased().hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst("sha256:".count)).lowercased()
        }
        return AvailableUpdate(
            version: version, dmgURL: asset.browserDownloadURL, size: asset.size, sha256: sha,
            releaseURL: release.htmlURL, notes: release.body ?? ""
        )
    }
}

nonisolated enum UpdateError: LocalizedError {
    case http(Int)
    case rateLimited
    case badDownload(String)
    case badApp(String)
    case tool(String, String)

    var errorDescription: String? {
        switch self {
        case let .http(code): "GitHub answered with HTTP \(code)."
        case .rateLimited: "GitHub is rate limiting update checks. Verbatim will try again later."
        case let .badDownload(why): "The download looks damaged (\(why))."
        case let .badApp(why): "The downloaded app isn't a valid Verbatim (\(why))."
        case let .tool(name, output): "\(name) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// File and process work for an update. Everything here blocks, so it runs
/// off the main actor.
nonisolated enum UpdateInstaller {
    static let repo = "oliverxuzy-ai/verbatim"

    /// ~/Library/Caches/dev.verbatim.app/Updates
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.verbatim.app/Updates", isDirectory: true)
    }

    static func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Verbatim/\(AppVersion.running)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 403 || status == 429 ? UpdateError.rateLimited : UpdateError.http(status) }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Whether this copy can replace itself: it must sit in an Applications
    /// folder the user can write to. A copy run from the disk image, from
    /// Downloads (App Translocation) or from Xcode is updated by hand.
    static func canReplace(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent()
        guard !app.path.contains("/AppTranslocation/"), parent.lastPathComponent == "Applications" else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: parent.path) && fm.isWritableFile(atPath: app.path)
    }

    /// Download, verify and unpack `update`. Returns the new Verbatim.app,
    /// staged in the cache folder and ready to swap in.
    static func prepare(_ update: AvailableUpdate, bundleID: String) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var request = URLRequest(url: update.dmgURL)
        request.timeoutInterval = 120
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? fm.removeItem(at: downloaded)
            throw UpdateError.http(status)
        }
        let dmg = folder.appendingPathComponent("Verbatim-\(update.version).dmg")
        try fm.moveItem(at: downloaded, to: dmg)

        return try await Task.detached(priority: .utility) {
            try verify(dmg: dmg, update: update)
            return try unpack(dmg: dmg, version: update.version, bundleID: bundleID)
        }.value
    }

    static func verify(dmg: URL, update: AvailableUpdate) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? -1
        guard size == update.size else { throw UpdateError.badDownload("expected \(update.size) bytes, got \(size)") }
        if let expected = update.sha256 {
            let actual = try sha256(of: dmg)
            guard actual == expected else { throw UpdateError.badDownload("checksum mismatch") }
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copy Verbatim.app out of the disk image and check it is the expected
    /// app and version with an intact signature.
    static func unpack(dmg: URL, version: AppVersion, bundleID: String) throws -> URL {
        let fm = FileManager.default
        let mount = folder.appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }
        let apps = (try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
        guard let source = apps.first(where: { $0.lastPathComponent == "Verbatim.app" }) ?? apps.first else {
            throw UpdateError.badApp("no app in the disk image")
        }
        let staged = folder.appendingPathComponent("Verbatim.app", isDirectory: true)
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [source.path, staged.path])

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badApp("wrong bundle identifier") }
        guard let found = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), found == version else {
            throw UpdateError.badApp("version is not \(version)")
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
        // Downloaded by Verbatim itself, the copy shouldn't be quarantined;
        // make sure, or Gatekeeper would block the ad-hoc signed app.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Start a small script that waits for this process to exit, swaps the
    /// staged app into `destination` (restoring the old one if that fails)
    /// and opens it. The caller quits right after.
    static func launchSwap(staged: URL, into destination: URL, relaunchArguments: [String]) throws {
        let script = folder.appendingPathComponent("install.sh")
        let backup = folder.appendingPathComponent("Verbatim-previous.app", isDirectory: true)
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, destination.path, backup.path] + relaunchArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let swapScript = """
    #!/bin/sh
    # Verbatim self-update: $1 pid of the running app, $2 new app, $3 installed
    # app, $4 backup path; the rest are passed to the relaunched app.
    trap '' HUP
    pid="$1"; new="$2"; dest="$3"; backup="$4"; shift 4
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 600 ] && exit 1
        sleep 0.1
    done
    rm -rf "$backup"
    if mv "$dest" "$backup"; then
        if mv "$new" "$dest"; then
            rm -rf "$backup"
        else
            mv "$backup" "$dest"
        fi
    fi
    open "$dest" --args "$@"
    """

    /// Leftovers from a previous update (or one that was never installed).
    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.tool(URL(fileURLWithPath: tool).lastPathComponent, output) }
        return output
    }
}

/// Checks for a new release a few times a day, downloads it in the
/// background, and installs it when Verbatim is idle (or right away when the
/// user clicks "Restart to update").
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate)
        case ready(AvailableUpdate)
        case installing(AvailableUpdate)
        case failed(String)
    }

    static let checkInterval: TimeInterval = 6 * 3600
    static let tickInterval: Duration = .seconds(10 * 60)

    let current = AppVersion.running
    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    weak var model: AppModel?
    private var stagedApp: URL?
    private var loop: Task<Void, Never>?

    /// False when this copy can't replace itself (see `UpdateInstaller.canReplace`):
    /// updates then open the release page instead.
    let canInstall = UpdateInstaller.canReplace(Bundle.main.bundleURL)

    /// The newer version found, whatever stage it is in.
    var update: AvailableUpdate? {
        switch state {
        case let .available(u), let .downloading(u), let .ready(u), let .installing(u): u
        default: nil
        }
    }

    func start() {
        UpdateInstaller.cleanUp()
        loop?.cancel()
        loop = Task { [weak self] in
            // Let launch work (calendar, models) settle first.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Background step: check when due, install when ready and idle.
    func tick() async {
        guard let model, model.settings.autoUpdate else { return }
        switch state {
        case .ready:
            if model.isIdleForUpdate { install() }
        case .checking, .downloading, .installing:
            return
        case .idle, .upToDate, .available, .failed:
            if let lastChecked, Date.now.timeIntervalSince(lastChecked) < Self.checkInterval { return }
            await check(userInitiated: false)
        }
    }

    /// Look for a newer release and, if this copy can update itself,
    /// download it. Background checks fail silently.
    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .ready, .installing: return
        case .idle, .upToDate, .available, .failed: break
        }
        state = .checking
        do {
            let release = try await UpdateInstaller.latestRelease()
            lastChecked = .now
            guard let found = AvailableUpdate.from(release, current: current) else {
                state = .upToDate
                return
            }
            Log.app.info("Update available: \(found.version.description, privacy: .public)")
            state = .available(found)
            if canInstall, userInitiated || model?.settings.autoUpdate == true {
                await download(found)
            }
        } catch {
            Log.app.error("Update check failed: \(error.localizedDescription)")
            lastChecked = .now
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func download(_ found: AvailableUpdate) async {
        state = .downloading(found)
        do {
            stagedApp = try await UpdateInstaller.prepare(found, bundleID: Bundle.main.bundleIdentifier ?? "dev.verbatim.app")
            state = .ready(found)
        } catch {
            Log.app.error("Update download failed: \(error.localizedDescription)")
            state = .failed("Couldn't download Verbatim \(found.version): \(error.localizedDescription)")
        }
    }

    /// The button next to an update: install it, or open the release page
    /// when this copy can't replace itself.
    func act() {
        switch state {
        case .ready: install()
        case let .available(found):
            if canInstall {
                Task { await download(found) }
            } else {
                NSWorkspace.shared.open(found.releaseURL)
            }
        case .idle, .upToDate, .failed:
            Task { await check(userInitiated: true) }
        case .checking, .downloading, .installing:
            break
        }
    }

    /// Quit, swap in the new app and reopen it. Never while recording.
    func install() {
        guard case let .ready(found) = state, let stagedApp, let model, !model.isRecording else { return }
        var arguments = ["--updated-from", current.description]
        if model.windows.isMainVisible { arguments.append("--show-main") }
        do {
            try UpdateInstaller.launchSwap(staged: stagedApp, into: Bundle.main.bundleURL, relaunchArguments: arguments)
        } catch {
            state = .failed("Couldn't install Verbatim \(found.version): \(error.localizedDescription)")
            return
        }
        Log.app.info("Installing update \(found.version.description, privacy: .public)")
        state = .installing(found)
        NSApp.terminate(nil)
    }
}
