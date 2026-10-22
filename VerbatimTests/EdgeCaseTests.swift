import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// Edge cases from real use: a channel that captured nothing (system audio
/// permission missing), a recording with no speech, very short recordings.
@MainActor
struct EdgeCaseTests {
    func storeWithRecording(micFixture: String?, emptySystem: Bool, micMode: MicMode = .solo) throws -> (RecordingStore, Recording, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-edge-\(UUID().uuidString)")
        let store = RecordingStore(rootURL: root)
        var rec = Recording(meeting: MeetingInfo(title: "Edge"), startedAt: .now.addingTimeInterval(-60), endedAt: .now,
                            language: "en-US", engine: "apple", micMode: micMode)
        rec.channelOffsets = ["mic": 0, "system": 0]
        try FileManager.default.createDirectory(at: store.folder(for: rec.id), withIntermediateDirectories: true)
        if let micFixture {
            try FileManager.default.copyItem(at: PipelineIntegrationTests.fixtures.appendingPathComponent(micFixture),
                                             to: store.audioURL(for: rec.id, channel: .mic))
            rec.speakers = [Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true)]
            rec.segments = [Segment(channel: .mic, speakerID: "me", start: 8, end: 15, text: "Sounds good.", isFinal: true)]
        }
        if emptySystem {
            // What a denied system-audio permission leaves behind: a valid file with zero frames.
            let caf = store.liveAudioURL(for: rec.id, channel: .system)
            AudioFileSink.makeEmpty(at: caf)
            try AudioFileSink.compress(caf, to: store.audioURL(for: rec.id, channel: .system))
        }
        store.save(rec)
        return (store, rec, root)
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(2)))
    func refineCompletesWhenSystemAudioIsEmpty() async throws {
        let (store, rec, root) = try storeWithRecording(micFixture: "meeting-mic.m4a", emptySystem: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let refined = try await TranscriptRefiner.refine(rec, store: store, myName: "Me", terms: [], retranscribe: true) { print("progress:", $0) }
        print("refine with empty system channel took \(Int(Date().timeIntervalSince(started)))s, \(refined.visibleSegments.count) segments")
        #expect(refined.visibleSegments.contains { $0.channel == .mic && $0.text.lowercased().contains("calls per month") })
        #expect(!refined.visibleSegments.contains { $0.channel == .system })
    }

    @Test(.timeLimit(.minutes(2)))
    func refineOfSilentRecordingFailsFastInsteadOfHanging() async throws {
        let (store, rec, root) = try storeWithRecording(micFixture: nil, emptySystem: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: RefineError.self) {
            _ = try await TranscriptRefiner.refine(rec, store: store, myName: "Me", terms: [], retranscribe: true) { _ in }
        }
    }
}

@MainActor
struct RecoveryTests {
    @Test func interruptedRecordingIsRecoveredOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let rec = Recording(meeting: MeetingInfo(title: "Crashed"), startedAt: .now.addingTimeInterval(-120),
                            language: "en-US", engine: "apple", micMode: .solo)
        try FileManager.default.createDirectory(at: store.folder(for: rec.id), withIntermediateDirectories: true)
        let sink = try AudioFileSink(url: store.liveAudioURL(for: rec.id, channel: .mic))
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormats.mono16k, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        sink.write(buffer)
        sink.close()
        store.save(rec) // endedAt == nil, as after a crash
        let reopened = RecordingStore(rootURL: root)
        reopened.recoverInterrupted(except: nil)
        let recovered = try #require(reopened.recording(rec.id))
        #expect(recovered.endedAt != nil)
        #expect(abs(recovered.duration - 2) < 0.1)
        #expect(FileManager.default.fileExists(atPath: reopened.audioURL(for: rec.id, channel: .mic).path))
    }
}
