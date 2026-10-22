import Foundation

nonisolated struct Attendee: Codable, Hashable, Sendable {
    var name: String
    var email: String?
    var isSelf: Bool = false
    var isOrganizer: Bool = false

    /// Best human label: the display name, else the local part of the email.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains("@") { return trimmed }
        if let email, let local = email.split(separator: "@").first {
            return local.split(whereSeparator: { $0 == "." || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        return trimmed
    }
}

nonisolated struct MeetingInfo: Codable, Hashable, Sendable {
    var calendarEventID: String?
    var title: String
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var attendees: [Attendee] = []
    var conferenceURL: URL?
    var calendarName: String?
    var location: String?

    static func adHoc(at date: Date = .now) -> MeetingInfo {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return MeetingInfo(title: "Untitled meeting · \(f.string(from: date))")
    }

    var conferenceProvider: ConferenceProvider? {
        ConferenceProvider.detect(conferenceURL?.absoluteString ?? location ?? "")
    }

    /// Online meetings mean the mic is (almost always) just you.
    var looksOnline: Bool { conferenceURL != nil || conferenceProvider != nil }
}

nonisolated enum ConferenceProvider: String, Codable, Sendable {
    case googleMeet, zoom, teams, feishu, tencent, webex

    var label: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .feishu: "Feishu / Lark"
        case .tencent: "Tencent Meeting"
        case .webex: "Webex"
        }
    }

    static func detect(_ text: String) -> ConferenceProvider? {
        let s = text.lowercased()
        if s.contains("meet.google.com") { return .googleMeet }
        if s.contains("zoom.us") || s.contains("zoom.com") { return .zoom }
        if s.contains("teams.microsoft.com") || s.contains("teams.live.com") { return .teams }
        if s.contains("feishu.cn") || s.contains("larksuite.com") || s.contains("vc.feishu") { return .feishu }
        if s.contains("meeting.tencent.com") || s.contains("voovmeeting") { return .tencent }
        if s.contains("webex.com") { return .webex }
        return nil
    }
}

nonisolated enum AudioChannel: String, Codable, Sendable, CaseIterable {
    /// Local microphone. In online meetings this is you.
    case mic
    /// Audio played by other apps (the remote participants).
    case system
}

/// Whether the microphone hears only the user or a whole room.
nonisolated enum MicMode: String, Codable, Sendable, CaseIterable {
    case solo
    case room

    var label: String {
        switch self {
        case .solo: "Just me (online call)"
        case .room: "People in the room"
        }
    }
}

nonisolated struct Speaker: Codable, Hashable, Sendable, Identifiable {
    /// Stable key: "me", or "<channel>:<engine label>" such as "system:1".
    var id: String
    var name: String
    var email: String?
    var colorIndex: Int
    var isMe: Bool = false
    /// True once the user has confirmed or renamed this speaker.
    var isConfirmed: Bool = false

    static let meID = "me"
}

nonisolated struct Segment: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var channel: AudioChannel
    var speakerID: String
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isFinal: Bool
    var confidence: Double?
    /// Mic segment detected as the speakers' audio leaking into the mic.
    var isEcho: Bool = false
    /// Word timings in recording time, used to re-split turns when speakers
    /// are re-clustered after the meeting.
    var words: [TimedWord]?
}

nonisolated struct Recording: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var meeting: MeetingInfo
    var startedAt: Date
    var endedAt: Date?
    /// BCP-47 language tag, e.g. "en-US" or "zh-CN".
    var language: String
    var engine: String
    var micMode: MicMode
    var speakers: [Speaker] = []
    var segments: [Segment] = []
    var notionPageURL: URL?
    var exportedAt: Date?
    var refinedAt: Date?
    /// How each non-me speaker's name was decided: "user", "voiceprint",
    /// "calendar", "llm". Keyed by speaker ID.
    var speakerSources: [String: String]?
    /// Problems noticed while recording (e.g. no call audio), kept for support.
    var diagnostics: [String]?
    /// Seconds between the recording start and each channel file's first
    /// sample, keyed by channel raw value. Lets re-transcription line up.
    var channelOffsets: [String: Double]?

    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }

    var visibleSegments: [Segment] {
        // A line with no letters or digits ("." from a cough) is not speech.
        segments.filter { !$0.isEcho && $0.text.contains { $0.isLetter || $0.isNumber } }
            .sorted { $0.start < $1.start }
    }

    /// Where a moment in recording time sits in a channel's audio file. Each
    /// file starts with its channel's first audio, which can be minutes into
    /// the recording (call audio that only arrived once the call did).
    func fileTime(_ time: TimeInterval, channel: AudioChannel) -> TimeInterval {
        time - (channelOffsets?[channel.rawValue] ?? 0)
    }

    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    func speakerName(_ id: String) -> String { speaker(id)?.name ?? "Unknown" }
}

extension TimeInterval {
    /// 00:12:34 style timestamp, hours always shown for alignment.
    nonisolated var clockString: String {
        let total = Int(self.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 12:34 style for short live displays.
    nonisolated var shortClockString: String {
        let total = Int(self.rounded(.down))
        if total >= 3600 { return clockString }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
