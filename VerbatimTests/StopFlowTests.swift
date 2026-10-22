import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// The path a user hits after pressing stop: AppModel.postProcess (voices,
/// calendar rules, refine with automatic online / in-person detection).
/// Runs on an isolated store; no cloud calls, no real voiceprints.
@MainActor
struct StopFlowTests {
    func model() -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-stop-\(UUID().uuidString)/Recordings")
        return (AppModel(storeRoot: root), root.deletingLastPathComponent())
    }

    func addRecording(_ model: AppModel, mic: String?, system: String?, attendees: [Attendee], live: [Segment] = []) throws -> Recording {
        var rec = Recording(meeting: MeetingInfo(title: "Test", attendees: attendees), startedAt: .now.addingTimeInterval(-60),
                            endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.channelOffsets = ["mic": 0, "system": 0]
        rec.segments = live
        rec.speakers = live.isEmpty ? [] : [Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true)]
        try FileManager.default.createDirectory(at: model.store.folder(for: rec.id), withIntermediateDirectories: true)
        for (channel, fixture) in [(AudioChannel.mic, mic), (.system, system)] {
            let target = model.store.audioURL(for: rec.id, channel: channel)
            if let fixture {
                try FileManager.default.copyItem(at: PipelineIntegrationTests.fixtures.appendingPathComponent(fixture), to: target)
            } else {
                let caf = model.store.liveAudioURL(for: rec.id, channel: channel)
                AudioFileSink.makeEmpty(at: caf)
                try AudioFileSink.compress(caf, to: target)
            }
        }
        model.store.save(rec)
        return rec
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(5)))
    func onlineMeetingKeepsMicAsMeAndSplitsRemoteVoices() async throws {
        let (model, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try addRecording(model, mic: "meeting-mic.m4a", system: "meeting-system.m4a",
                                   attendees: [Attendee(name: "Me", isSelf: true), Attendee(name: "Samantha"), Attendee(name: "Daniel")],
                                   live: [Segment(channel: .mic, speakerID: "me", start: 9, end: 15, text: "Sounds good.", isFinal: true)])
        await model.postProcess(rec)
        let out = try #require(model.store.recording(rec.id))
        print("ONLINE state=\(model.refineStates[rec.id].map { "\($0)" } ?? "nil") mode=\(out.micMode) speakers=\(out.speakers.map(\.name))")
        #expect(model.refineStates[rec.id] == .done)
        #expect(out.micMode == .solo)
        #expect(out.visibleSegments.filter { $0.channel == .mic }.allSatisfy { $0.speakerID == Speaker.meID })
        #expect(Set(out.visibleSegments.filter { $0.channel == .system }.map(\.speakerID)).count == 2)
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(5)))
    func inPersonMeetingIsDetectedWithoutAnyToggle() async throws {
        let (model, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try addRecording(model, mic: "meeting-room-mic.m4a", system: nil,
                                   attendees: [Attendee(name: "Me", isSelf: true), Attendee(name: "Bea"), Attendee(name: "Carl"), Attendee(name: "Dana")])
        let started = Date()
        await model.postProcess(rec)
        let out = try #require(model.store.recording(rec.id))
        let micSpeakers = Set(out.visibleSegments.filter { $0.channel == .mic }.map(\.speakerID))
        print("IN-PERSON took \(Int(Date().timeIntervalSince(started)))s state=\(model.refineStates[rec.id].map { "\($0)" } ?? "nil") mode=\(out.micMode) mic speakers=\(micSpeakers.count)")
        #expect(model.refineStates[rec.id] == .done)
        #expect(out.micMode == .room)
        #expect(micSpeakers.count >= 3)
    }

    @Test(.timeLimit(.minutes(2)))
    func silentRecordingEndsWithAClearMessage() async throws {
        let (model, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try addRecording(model, mic: nil, system: nil, attendees: [])
        await model.postProcess(rec)
        print("SILENT state=\(model.refineStates[rec.id].map { "\($0)" } ?? "nil")")
        if case .failed = model.refineStates[rec.id] {} else { Issue.record("expected a failed state with a message") }
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(5)))
    func speakersLeakingIntoMicStayOnlineAndAreNotAttributedToMe() async throws {
        let (model, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try addRecording(model, mic: "meeting-mic-leak.m4a", system: "meeting-system.m4a",
                                   attendees: [Attendee(name: "Me", isSelf: true), Attendee(name: "Samantha"), Attendee(name: "Daniel")],
                                   live: [Segment(channel: .mic, speakerID: "me", start: 9, end: 15, text: "Sounds good.", isFinal: true)])
        await model.postProcess(rec)
        let out = try #require(model.store.recording(rec.id))
        let mine = out.visibleSegments.filter { $0.speakerID == Speaker.meID }.map { $0.text.lowercased() }
        print("LEAK mode=\(out.micMode) me=\(mine)")
        #expect(out.micMode == .solo)
        for phrase in ["thanks for joining", "remind us", "rule-based", "wednesday"] {
            #expect(!mine.contains { $0.contains(phrase) }, "leaked line attributed to me: \(phrase)")
        }
        #expect(mine.contains { $0.contains("calls per month") })
    }
}
