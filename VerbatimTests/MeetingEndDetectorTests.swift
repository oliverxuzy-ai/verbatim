import Foundation
import Testing
@testable import Verbatim

struct MeetingEndDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test func keepsGoingWhilePeopleTalk() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: at(30))
        for m in stride(from: 0.0, through: 25, by: 0.5) {
            d.heardSpeech(on: m.truncatingRemainder(dividingBy: 1) == 0 ? .system : .mic, at: at(m))
        }
        #expect(d.verdict(at: at(26)) == nil)
    }

    @Test func stopsWhenTheCallGoesQuiet() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: nil)
        d.heardSpeech(on: .system, at: at(20))
        d.heardSpeech(on: .mic, at: at(20.5))
        #expect(d.verdict(at: at(22)) == nil)
        #expect(d.verdict(at: at(23)) == .callEnded)
    }

    @Test func aLongMonologueIsNotTheEnd() {
        // You present for 5 minutes while the others listen.
        var d = MeetingEndDetector(start: t0, scheduledEnd: at(60))
        d.heardSpeech(on: .system, at: at(10))
        for m in stride(from: 10.0, through: 15, by: 0.25) { d.heardSpeech(on: .mic, at: at(m)) }
        #expect(d.verdict(at: at(15.5)) == nil)
    }

    @Test func talkingInTheRoomAfterTheSlotDoesNotKeepItGoing() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: at(30))
        d.heardSpeech(on: .system, at: at(29))
        for m in stride(from: 29.0, through: 33, by: 0.25) { d.heardSpeech(on: .mic, at: at(m)) }
        #expect(d.verdict(at: at(32)) == .callEnded)
    }

    @Test func quietCallChannelMeansNothingWithoutSystemAudio() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: nil)
        d.heardSpeech(on: .system, at: at(1))
        d.heardSpeech(on: .mic, at: at(2))
        #expect(d.verdict(at: at(8), callAudioWorks: false) == nil)
        #expect(d.verdict(at: at(12), callAudioWorks: false) == .silence)
    }

    @Test func inPersonMeetingStopsAfterLongSilence() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: nil)
        d.heardSpeech(on: .mic, at: at(40))
        #expect(d.verdict(at: at(49)) == nil)
        #expect(d.verdict(at: at(50)) == .silence)
    }

    @Test func waitingInTheLobbyGetsLonger() {
        let d = MeetingEndDetector(start: t0, scheduledEnd: nil)
        #expect(d.verdict(at: at(15)) == nil)
        #expect(d.verdict(at: at(20)) == .silence)
    }

    @Test func keepRecordingRestartsTheTimers() {
        var d = MeetingEndDetector(start: t0, scheduledEnd: nil)
        d.heardSpeech(on: .system, at: at(5))
        #expect(d.verdict(at: at(9)) == .callEnded)
        d.resetQuiet(at: at(9))
        #expect(d.verdict(at: at(11)) == nil)
        #expect(d.verdict(at: at(12)) == .callEnded)
    }

    @Test func emptyEngineUpdatesAreNotSpeech() {
        #expect(!EngineUpdate().hasSpeech)
        #expect(!EngineUpdate(volatile: EngineResult(start: 0, end: 1, text: "  ")).hasSpeech)
        #expect(EngineUpdate(volatile: EngineResult(start: 0, end: 1, text: "hi")).hasSpeech)
        #expect(EngineUpdate(finals: [EngineResult(start: 0, end: 1, text: "好的")]).hasSpeech)
    }
}
