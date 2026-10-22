import Foundation
import Testing
@testable import Verbatim

/// Naming voices in a first meeting from how people address each other.
struct NameMentionTests {
    let invitees = [
        Attendee(name: "Oliver", email: "oliver@example.com", isSelf: true),
        Attendee(name: "Kevin Walsh", email: "kevin@example.com"),
        Attendee(name: "Grant Ellis", email: "grant@example.com"),
    ]

    func recording(_ lines: [(String, String)], attendees: [Attendee], room: Bool = false) -> Recording {
        var rec = Recording(meeting: MeetingInfo(title: "Launch sync", attendees: attendees), startedAt: .now, endedAt: .now,
                            language: "en-US", engine: "apple", micMode: .solo)
        var ids: [String] = []
        for line in lines where line.0 != "me" && !ids.contains(line.0) { ids.append(line.0) }
        rec.speakers = [Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true)]
            + ids.enumerated().map { Speaker(id: $1, name: room ? "In room \($0 + 1)" : "Speaker \($0 + 1)", colorIndex: $0 + 1) }
        rec.segments = lines.enumerated().map { i, line in
            Segment(channel: line.0 == "me" || room ? .mic : .system, speakerID: line.0,
                    start: Double(i * 6), end: Double(i * 6 + 5), text: line.1, isFinal: true)
        }
        return rec
    }

    @Test func addressedVoicesAreNamedThenEliminationNamesTheOther() {
        let rec = recording([
            ("system:0", "Thanks everyone for joining. Grant, can you start with the migration?"),
            ("system:1", "Sure. The migration finished last night."),
            ("system:0", "Great. And the dashboards, Grant?"),
            ("system:1", "Already pointing at the new tables. Kevin, do you need anything else for Friday?"),
            ("system:0", "No, that covers it. Thanks, Grant."),
        ], attendees: invitees)
        let named = CalendarRules.apply(rec, myName: "Me")
        #expect(named.speaker("system:1")?.name == "Grant Ellis")
        #expect(named.speaker("system:1")?.email == "grant@example.com")
        #expect(named.speakerSources?["system:1"] == "mention")
        #expect(named.speaker("system:0")?.name == "Kevin Walsh")
        #expect(named.speakerSources?["system:0"] == "calendar")
        // Suggestions only: the user still confirms.
        #expect(named.speakers.filter { !$0.isMe }.allSatisfy { !$0.isConfirmed })
    }

    @Test func introductionNamesAnInRoomVoice() {
        let three = invitees + [Attendee(name: "Ananya Iyer", email: "ananya@example.com")]
        let rec = recording([
            ("room:0", "Hi, this is Grant from the data team."),
            ("room:1", "Nice to meet you. Shall we start?"),
            ("me", "Let's start."),
        ], attendees: three, room: true)
        let named = CalendarRules.apply(rec, myName: "Me")
        #expect(named.speaker("room:0")?.name == "Grant Ellis")
        #expect(named.speaker("room:1")?.name == "In room 2")
    }

    @Test func thirdPersonAndCommonWordsNameNobody() {
        let three = invitees + [Attendee(name: "Ananya Iyer", email: "ananya@example.com")]
        let rec = recording([
            ("system:0", "Grant said the migration is done."),
            ("system:1", "Grant access to the dashboard before Friday."),
            ("system:0", "Let's ask Kevin's team about it."),
            ("system:1", "I think Kevin will be fine with that."),
        ], attendees: three)
        let named = CalendarRules.apply(rec, myName: "Me")
        #expect(named.speakers.filter { !$0.isMe }.allSatisfy { CalendarRules.isGeneric($0.name) })
    }

    @Test func oneCueIsNotEnough() {
        let three = invitees + [Attendee(name: "Ananya Iyer", email: "ananya@example.com")]
        let rec = recording([
            ("system:0", "Grant, can you share your screen?"),
            ("system:1", "Sure, one second."),
        ], attendees: three)
        #expect(CalendarRules.apply(rec, myName: "Me").speaker("system:1")?.name == "Speaker 2")
    }

    @Test func sharedFirstNamesAreIgnored() {
        let twins = [invitees[0], Attendee(name: "Kevin Walsh", email: "kevin@example.com"),
                     Attendee(name: "Kevin Park", email: "kpark@example.com"), Attendee(name: "Ananya Iyer")]
        let rec = recording([
            ("system:0", "Kevin, can you start?"),
            ("system:1", "Sure."),
            ("system:0", "And the numbers, Kevin?"),
            ("system:1", "They look good."),
        ], attendees: twins)
        #expect(CalendarRules.apply(rec, myName: "Me").speaker("system:1")?.name == "Speaker 2")
    }

    /// Verbatim from a live run: the recognizer wrote "Grand" and moved
    /// the punctuation, which left each person with one exact cue.
    @Test func misheardNamesStillCount() {
        let rec = recording([
            ("system:0", "Thanks everyone for joining. Grant, can you start with the data migration?"),
            ("system:1", "Sure. The migration finished last night, and the dashboards are already pointing at the new tables."),
            ("system:0", "Great. And is the pricing page ready? Grand?"),
            ("system:1", "Almost. Kevin, do you want the final copy by Wednesday?"),
            ("system:0", "Wednesday works for me. Thanks. Grand."),
        ], attendees: invitees)
        let named = CalendarRules.apply(rec, myName: "Me")
        #expect(named.speaker("system:1")?.name == "Grant Ellis")
        #expect(named.speaker("system:0")?.name == "Kevin Walsh")
        #expect(CalendarRules.normalizingNames("Grand opening today", ["Grant"]) == "Grant opening today")
        #expect(CalendarRules.addressCue("Grant opening today", "Grant") == nil)
        #expect(CalendarRules.normalizingNames("Ask Mark", ["Marc"]) == "Ask Mark") // short names: exact only
        #expect(CalendarRules.editDistance("Grant", "Grand") == 1)
    }

    @Test func cuesPointAtTheRightTurn() {
        #expect(CalendarRules.addressCue("Grant, can you start?", "Grant") == .next)
        #expect(CalendarRules.addressCue("Can you send it by Friday, Grant?", "Grant") == .next)
        #expect(CalendarRules.addressCue("Okay. Thanks, Grant.", "Grant") == .previous)
        #expect(CalendarRules.addressCue("Grant access to the dashboard.", "Grant") == nil)
        #expect(CalendarRules.introduces("Hey, I'm Grant.", "Grant"))
        #expect(!CalendarRules.introduces("This is Grant's dashboard.", "Grant"))
        #expect(CalendarRules.firstName("Oliverxzy179") == nil)
        #expect(CalendarRules.firstName("Grant Ellis") == "Grant")
    }
}

/// Guards on what the post-meeting pass may change.
struct RefineGuardTests {
    func rec(_ lines: [(AudioChannel, Double, String)]) -> Recording {
        var r = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        r.segments = lines.map { Segment(channel: $0.0, speakerID: $0.0 == .mic ? "me" : "system:0", start: $0.1, end: $0.1 + 5, text: $0.2, isFinal: true) }
        return r
    }

    /// The live run where re-transcription lost the second sentence.
    @Test func lostSentenceKeepsTheLiveVersion() {
        let live = rec([
            (.system, 2, "Welcome back. Let's check where we landed on the pricing page since last week."),
            (.system, 8, "The copy is final. Design signed off yesterday, so we can publish it on Monday morning."),
        ])
        let refined = rec([
            (.system, 2, "Welcome back. The copy is final. Design signed off yesterday, so we can publish it on Monday morning."),
        ])
        #expect(TranscriptRefiner.dropsSpeech(original: live, refined: refined))
    }

    @Test func rewordedButCompleteIsFine() {
        let live = rec([(.system, 2, "Let's check where we landed on the pricing page since last week.")])
        let refined = rec([(.system, 2.4, "Let us check where we landed on the pricing page since last week.")])
        #expect(!TranscriptRefiner.dropsSpeech(original: live, refined: refined))
    }

    @Test func micLeakMovedToCallAudioIsNotALoss() {
        let live = rec([(.mic, 2, "The copy is final and design signed off yesterday.")])
        let refined = rec([(.system, 2, "The copy is final and design signed off yesterday.")])
        #expect(!TranscriptRefiner.dropsSpeech(original: live, refined: refined))
    }

    /// Chinese has no spaces: a re-transcription with slightly different
    /// wording or punctuation still has the same speech.
    @Test func chineseRewordedIsFine() {
        let live = rec([(.mic, 2, "我们今天先过一下项目进度，然后讨论一下下周的发布计划，最后看看还有什么风险。")])
        let refined = rec([(.mic, 2.3, "我们今天先过一下项目的进度，然后讨论下周发布计划。最后看看还有什么风险")])
        #expect(!TranscriptRefiner.dropsSpeech(original: live, refined: refined))
    }

    @Test func chineseLostSentenceKeepsTheLiveVersion() {
        let live = rec([
            (.mic, 2, "我们今天先过一下项目进度。"),
            (.mic, 20, "设计稿昨天已经确认了，所以周一早上就可以发布。"),
        ])
        let refined = rec([(.mic, 2, "我们今天先过一下项目进度。")])
        #expect(TranscriptRefiner.dropsSpeech(original: live, refined: refined))
    }

    @Test func mixedChineseEnglishWords() {
        #expect(TranscriptRefiner.words("我们用dbt跑一下, OK?") == ["我", "们", "用", "dbt", "跑", "一", "下", "ok"])
        #expect(TranscriptRefiner.words("Hello there.") == ["hello", "there"])
    }

    @Test func punctuationOnlyLinesAreHidden() {
        let r = rec([(.mic, 1, "."), (.system, 2, "Hello there.")])
        #expect(r.visibleSegments.map(\.text) == ["Hello there."])
    }
}
