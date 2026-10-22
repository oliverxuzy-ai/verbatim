import AVFAudio
import Foundation

nonisolated struct TimedWord: Sendable, Hashable, Codable {
    var text: String
    /// Seconds from the start of this stream.
    var start: Double
    var end: Double
    var speaker: String?
}

/// One recognized span from an engine. Times are seconds from the start of
/// the audio fed to that engine.
nonisolated struct EngineResult: Sendable, Hashable {
    var start: Double
    var end: Double
    var text: String
    var words: [TimedWord] = []
    /// Engine-provided speaker label when the engine diarizes itself.
    var speaker: String?
    var confidence: Double?
    var language: String?
}

/// Engines emit finalized spans to append plus at most one volatile (still
/// changing) span that replaces the previous volatile span.
nonisolated struct EngineUpdate: Sendable {
    var finals: [EngineResult] = []
    var volatile: EngineResult?

    /// True when the engine heard words (not just an empty refresh).
    var hasSpeech: Bool {
        finals.contains { !$0.text.trimmed.isEmpty } || !(volatile?.text.trimmed.isEmpty ?? true)
    }
}

nonisolated protocol StreamingTranscriber: AnyObject, Sendable {
    var displayName: String { get }
    /// True when results already carry speaker labels.
    var providesDiarization: Bool { get }
    func start(updates: @escaping @Sendable (EngineUpdate) -> Void) async throws
    /// Feed 16 kHz mono Float32 audio. Called from one serial queue.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Flush and finalize everything fed so far.
    func finish() async
}

nonisolated struct TranscriptionContext: Sendable {
    var language: String
    var terms: [String]
    var meetingTitle: String
    var attendeeNames: [String]
}

nonisolated enum TranscriberError: LocalizedError {
    case unsupportedLanguage(String)
    case assetsUnavailable(String)
    case missingAPIKey(String)
    case server(String)
    case audioFormat

    var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(l): "On-device transcription does not support \(l) on this Mac."
        case let .assetsUnavailable(m): "Speech model unavailable: \(m)"
        case let .missingAPIKey(e): "Add your \(e) API key in Settings."
        case let .server(m): m
        case .audioFormat: "Could not prepare the audio format for transcription."
        }
    }
}

/// Builds custom vocabulary from the meeting itself (names, title words) and
/// the user's own term list. This is one of the cheapest accuracy wins:
/// names and jargon are what generic models get wrong most.
nonisolated enum VocabularyBuilder {
    static func terms(meeting: MeetingInfo, userTerms: [String], myName: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmed
            guard t.count >= 2, !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            out.append(t)
        }
        userTerms.forEach(add)
        for a in meeting.attendees {
            let name = a.displayName
            add(name)
            for part in name.split(separator: " ") where part.count >= 3 { add(String(part)) }
        }
        add(myName)
        for part in myName.split(separator: " ") where part.count >= 3 { add(String(part)) }
        // Title words that look like proper nouns or acronyms.
        let titleWords = meeting.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
        for w in titleWords where w.count >= 3 {
            if w.first?.isUppercase == true || w.allSatisfy({ $0.isUppercase || $0.isNumber }) { add(String(w)) }
        }
        return Array(out.prefix(100))
    }
}
