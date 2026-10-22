import Foundation
import Observation

nonisolated enum EngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple
    case soniox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple on-device"
        case .soniox: "Soniox (cloud)"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Free and private. Runs on this Mac. Speakers separated with an on-device model. One language per meeting."
        case .soniox: "Highest accuracy, mixed Chinese and English in one meeting, built-in speaker separation. About $0.12 per audio hour per channel."
        }
    }
}

nonisolated struct LanguageOption: Hashable, Sendable, Identifiable {
    let id: String
    let label: String

    static let all: [LanguageOption] = [
        .init(id: "en-US", label: "English"),
        .init(id: "zh-CN", label: "中文 (普通话)"),
        .init(id: "mixed", label: "中英混合"),
        .init(id: "zh-TW", label: "中文 (台灣)"),
        .init(id: "ja-JP", label: "日本語"),
        .init(id: "ko-KR", label: "한국어"),
        .init(id: "es-ES", label: "Español"),
        .init(id: "fr-FR", label: "Français"),
        .init(id: "de-DE", label: "Deutsch"),
    ]

    static func label(for id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

@Observable
final class AppSettings {
    static let defaultNotionDataSource = "b5ef1419-6051-453b-a494-e59c7d8abbab"

    private let defaults = UserDefaults.standard

    var engine: EngineKind { didSet { save("engine", engine.rawValue) } }
    var language: String { didSet { save("language", language) } }
    var myName: String { didSet { save("myName", myName) } }
    var vocabulary: String { didSet { save("vocabulary", vocabulary) } }
    var echoCancellation: Bool { didSet { save("echoCancellation", echoCancellation) } }
    var liveDiarization: Bool { didSet { save("liveDiarization", liveDiarization) } }
    var notionDataSourceID: String { didSet { save("notionDataSourceID", notionDataSourceID) } }
    var notionSourceOption: String { didSet { save("notionSourceOption", notionSourceOption) } }
    var autoExportOnStop: Bool { didSet { save("autoExportOnStop", autoExportOnStop) } }
    var autoRefine: Bool { didSet { save("autoRefine", autoRefine) } }
    var meetingReminders: Bool { didSet { save("meetingReminders", meetingReminders) } }
    var autoStartVideoMeetings: Bool { didSet { save("autoStartVideoMeetings", autoStartVideoMeetings) } }
    var autoStopWhenMeetingEnds: Bool { didSet { save("autoStopWhenMeetingEnds", autoStopWhenMeetingEnds) } }
    var claudeNaming: Bool { didSet { save("claudeNaming", claudeNaming) } }
    var showInDock: Bool { didSet { save("showInDock", showInDock) } }
    var hiddenCalendarIDs: [String] { didSet { save("hiddenCalendarIDs", hiddenCalendarIDs) } }
    var hasCompletedOnboarding: Bool { didSet { save("hasCompletedOnboarding", hasCompletedOnboarding) } }

    // Secrets live in a private file (see Keychain); these only say whether one is set.
    private(set) var hasNotionToken: Bool
    private(set) var hasSonioxKey: Bool
    private(set) var hasAnthropicKey: Bool

    init() {
        let d = UserDefaults.standard
        engine = EngineKind(rawValue: d.string(forKey: "engine") ?? "") ?? .apple
        language = d.string(forKey: "language") ?? "en-US"
        myName = d.string(forKey: "myName") ?? AppSettings.defaultMyName()
        vocabulary = d.string(forKey: "vocabulary") ?? ""
        echoCancellation = d.object(forKey: "echoCancellation") as? Bool ?? true
        liveDiarization = d.object(forKey: "liveDiarization") as? Bool ?? true
        notionDataSourceID = d.string(forKey: "notionDataSourceID") ?? AppSettings.defaultNotionDataSource
        notionSourceOption = d.string(forKey: "notionSourceOption") ?? "Verbatim"
        autoExportOnStop = d.object(forKey: "autoExportOnStop") as? Bool ?? false
        autoRefine = d.object(forKey: "autoRefine") as? Bool ?? true
        meetingReminders = d.object(forKey: "meetingReminders") as? Bool ?? true
        autoStartVideoMeetings = d.object(forKey: "autoStartVideoMeetings") as? Bool ?? false
        autoStopWhenMeetingEnds = d.object(forKey: "autoStopWhenMeetingEnds") as? Bool ?? true
        claudeNaming = d.object(forKey: "claudeNaming") as? Bool ?? true
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        hiddenCalendarIDs = d.stringArray(forKey: "hiddenCalendarIDs") ?? []
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        hasNotionToken = Keychain.get(SecretKey.notionToken) != nil
        hasSonioxKey = Keychain.get(SecretKey.sonioxKey) != nil
        hasAnthropicKey = Keychain.get(SecretKey.anthropicKey) != nil
    }

    var vocabularyTerms: [String] {
        vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "，" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    func setNotionToken(_ token: String?) {
        Keychain.set(token?.trimmed, for: SecretKey.notionToken)
        hasNotionToken = Keychain.get(SecretKey.notionToken) != nil
    }

    func setSonioxKey(_ key: String?) {
        Keychain.set(key?.trimmed, for: SecretKey.sonioxKey)
        hasSonioxKey = Keychain.get(SecretKey.sonioxKey) != nil
    }

    func setAnthropicKey(_ key: String?) {
        Keychain.set(key?.trimmed, for: SecretKey.anthropicKey)
        hasAnthropicKey = Keychain.get(SecretKey.anthropicKey) != nil
    }

    var anthropicKey: String? { Keychain.get(SecretKey.anthropicKey) }
    var notionToken: String? { Keychain.get(SecretKey.notionToken) }
    var sonioxKey: String? { Keychain.get(SecretKey.sonioxKey) }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    /// "Me" matches the existing Notion AI transcripts in the database.
    private static func defaultMyName() -> String { "Me" }
}
