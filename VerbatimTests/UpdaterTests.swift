import Foundation
import Testing
@testable import Verbatim

struct AppVersionTests {
    @Test func parsesTagsAndPlainVersions() {
        #expect(AppVersion("v0.5.1")?.parts == [0, 5, 1])
        #expect(AppVersion("0.5.1")?.description == "0.5.1")
        #expect(AppVersion(" 1.2 ")?.parts == [1, 2])
        #expect(AppVersion("0.6.0-beta") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesNumericallyNotAlphabetically() {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        #expect(v("0.5.10") > v("0.5.9"))
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(v("1.0") > v("0.99.99"))
        #expect(v("0.6") == v("0.6.0"))
        #expect(!(v("0.6.0") < v("0.6")))
        #expect(v("0.5.1") < v("0.5.2"))
    }
}

struct AvailableUpdateTests {
    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: String? = nil) throws -> GitHubRelease {
        let assetsJSON = assets ?? """
        [{"name": "Verbatim-\(tag.dropFirst()).dmg", "size": 1234,
          "browser_download_url": "https://github.com/oliverxuzy-ai/verbatim/releases/download/\(tag)/Verbatim-\(tag.dropFirst()).dmg",
          "digest": "sha256:ABCDEF0123"}]
        """
        let json = """
        {"tag_name": "\(tag)", "name": "Verbatim \(tag.dropFirst())", "body": "notes",
         "html_url": "https://github.com/oliverxuzy-ai/verbatim/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": \(prerelease), "assets": \(assetsJSON), "extra": {"ignored": true}}
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private let current = AppVersion("0.5.1")!

    @Test func offersANewerReleaseWithItsDMG() throws {
        let update = try #require(AvailableUpdate.from(release(tag: "v0.6.0"), current: current))
        #expect(update.version == AppVersion("0.6.0")!)
        #expect(update.dmgURL.lastPathComponent == "Verbatim-0.6.0.dmg")
        #expect(update.size == 1234)
        #expect(update.sha256 == "abcdef0123")
        #expect(update.releaseURL.absoluteString.hasSuffix("/releases/tag/v0.6.0"))
        #expect(update.notes == "notes")
    }

    @Test func ignoresSameOrOlderVersions() throws {
        #expect(try AvailableUpdate.from(release(tag: "v0.5.1"), current: current) == nil)
        #expect(try AvailableUpdate.from(release(tag: "v0.5.0"), current: current) == nil)
    }

    @Test func ignoresDraftsAndPrereleases() throws {
        #expect(try AvailableUpdate.from(release(tag: "v0.6.0", draft: true), current: current) == nil)
        #expect(try AvailableUpdate.from(release(tag: "v0.6.0", prerelease: true), current: current) == nil)
    }

    @Test func needsADMG() throws {
        let none = try release(tag: "v0.6.0", assets: "[]")
        #expect(AvailableUpdate.from(none, current: current) == nil)
        let zipOnly = try release(tag: "v0.6.0", assets: """
        [{"name": "Verbatim.zip", "size": 1, "browser_download_url": "https://example.com/Verbatim.zip"}]
        """)
        #expect(AvailableUpdate.from(zipOnly, current: current) == nil)
    }

    @Test func prefersTheVersionedDMGAndToleratesNoDigest() throws {
        let rel = try release(tag: "v0.6.0", assets: """
        [{"name": "Other.dmg", "size": 1, "browser_download_url": "https://example.com/Other.dmg"},
         {"name": "Verbatim-0.6.0.dmg", "size": 2, "browser_download_url": "https://example.com/Verbatim-0.6.0.dmg", "digest": null}]
        """)
        let update = try #require(AvailableUpdate.from(rel, current: current))
        #expect(update.dmgURL.lastPathComponent == "Verbatim-0.6.0.dmg")
        #expect(update.sha256 == nil)
    }
}

struct UpdateInstallerTests {
    @Test func onlyReplacesCopiesInApplications() {
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/Volumes/Verbatim 0.5.1/Verbatim.app")))
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Verbatim.app")))
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Verbatim.app")))
    }

    @Test func hashesFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try UpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The swap script against throwaway folders: replaces the app, keeps
    /// no backup, and restores the old app when the new one is missing.
    @Test func swapScriptReplacesTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("verbatim-swap-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let new = root.appendingPathComponent("staged/Verbatim.app", isDirectory: true)
        let dest = root.appendingPathComponent("Applications/Verbatim.app", isDirectory: true)
        let backup = root.appendingPathComponent("backup.app", isDirectory: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: dest.appendingPathComponent("marker"))
        // `open` would launch something; stub it out via PATH.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let openStub = bin.appendingPathComponent("open")
        try Data("#!/bin/sh\necho \"$@\" > \"\(root.path)/opened\"\n".utf8).write(to: openStub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openStub.path)
        let script = root.appendingPathComponent("install.sh")
        try UpdateInstaller.swapScript.write(to: script, atomically: true, encoding: .utf8)

        func runScript() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // A pid that has already exited: the script proceeds at once.
            let gone = Process()
            gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try gone.run()
            gone.waitUntilExit()
            p.arguments = [script.path, String(gone.processIdentifier), new.path, dest.path, backup.path, "--updated-from", "0.5.1"]
            p.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }

        try runScript()
        #expect(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: new.path))
        #expect(!fm.fileExists(atPath: backup.path))
        let opened = try String(contentsOf: root.appendingPathComponent("opened"), encoding: .utf8)
        #expect(opened.contains(dest.path) && opened.contains("--updated-from 0.5.1"))

        // Nothing staged any more: the installed app must survive untouched.
        try runScript()
        #expect(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8) == "new")
    }
}
