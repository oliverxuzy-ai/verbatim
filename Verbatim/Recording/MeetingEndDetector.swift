import Foundation

/// Decides when a meeting is over so a forgotten recording stops by itself.
///
/// "Speech" means the engine transcribed words on that channel, so fans,
/// typing and room noise don't keep a recording alive. Two rules:
/// - **Call ended**: other participants were heard, then the call audio went
///   quiet for 3 minutes while you were quiet for 2 (or the calendar slot is
///   over, so talking to someone in the room afterwards doesn't count).
/// - **Silence**: nobody on either channel for 10 minutes (20 if nobody has
///   spoken yet, so waiting in a lobby doesn't end the recording).
///
/// When a rule fires the session starts a short countdown; any new speech or
/// "Keep recording" cancels it.
nonisolated struct MeetingEndDetector: Sendable {
    nonisolated enum Reason: Equatable, Sendable {
        case callEnded
        case silence

        var message: String {
            switch self {
            case .callEnded: "The call audio stopped a few minutes ago."
            case .silence: "Nobody has spoken for 10 minutes."
            }
        }
    }

    nonisolated struct Thresholds: Sendable {
        var callSilence: TimeInterval = 3 * 60
        var micSilenceAfterCall: TimeInterval = 2 * 60
        var allSilence: TimeInterval = 10 * 60
        var allSilenceBeforeAnySpeech: TimeInterval = 20 * 60
    }

    let thresholds: Thresholds
    var scheduledEnd: Date?
    private(set) var lastRemoteSpeech: Date?
    private(set) var lastMicSpeech: Date?
    /// Start of the recording, moved forward by pause/resume and "Keep
    /// recording" so quiet time before that doesn't count.
    private(set) var quietSince: Date

    init(start: Date, scheduledEnd: Date?, thresholds: Thresholds = .init()) {
        self.quietSince = start
        self.scheduledEnd = scheduledEnd
        self.thresholds = thresholds
    }

    mutating func heardSpeech(on channel: AudioChannel, at date: Date) {
        switch channel {
        case .system: lastRemoteSpeech = max(lastRemoteSpeech ?? date, date)
        case .mic: lastMicSpeech = max(lastMicSpeech ?? date, date)
        }
    }

    /// Restart the quiet timers (after resuming from pause, or when the user
    /// says the meeting is still going).
    mutating func resetQuiet(at date: Date) {
        quietSince = max(quietSince, date)
    }

    /// Why the meeting looks over at `now`, or nil while it's still going.
    /// `callAudioWorks` is false when system audio isn't captured: then a
    /// quiet call channel means nothing and only the silence rule applies.
    func verdict(at now: Date, callAudioWorks: Bool = true) -> Reason? {
        let remoteQuiet = now.timeIntervalSince(max(lastRemoteSpeech ?? quietSince, quietSince))
        let micQuiet = now.timeIntervalSince(max(lastMicSpeech ?? quietSince, quietSince))

        if callAudioWorks, lastRemoteSpeech != nil, remoteQuiet >= thresholds.callSilence {
            let slotOver = scheduledEnd.map { now >= $0 } ?? false
            if micQuiet >= thresholds.micSilenceAfterCall || slotOver { return .callEnded }
        }

        let anySpeech = lastRemoteSpeech != nil || lastMicSpeech != nil
        let limit = anySpeech ? thresholds.allSilence : thresholds.allSilenceBeforeAnySpeech
        if min(remoteQuiet, micQuiet) >= limit { return .silence }
        return nil
    }
}
