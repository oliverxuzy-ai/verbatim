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

    /// A crash or hang right after an autosave: the lines recognized since
    /// then (and the words still being recognized) come back from the journal.
    @Test func journalRestoresLinesMissingFromTheLastAutosave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        var rec = Recording(meeting: MeetingInfo(title: "Crashed"), startedAt: .now.addingTimeInterval(-60),
                            language: "en-US", engine: "apple", micMode: .solo)
        rec.speakers = [Speaker(id: Speaker.meID, name: "Me", colorIndex: 0, isMe: true, isConfirmed: true)]
        rec.segments = [Segment(channel: .mic, speakerID: Speaker.meID, start: 0.5, end: 2, text: "Let's start with the budget.", isFinal: true)]
        store.save(rec) // the last autosave before the crash

        let journal = TranscriptJournal(folder: store.folder(for: rec.id))
        journal.noteOffset(0.5, for: .mic)
        journal.noteOffset(1, for: .system)
        journal.record(EngineUpdate(finals: [EngineResult(start: 0, end: 1.5, text: "Let's start with the budget.")]), channel: .mic)
        journal.record(EngineUpdate(finals: [EngineResult(start: 2, end: 4, text: "Marketing asked for twenty more.")]), channel: .system)
        journal.record(EngineUpdate(finals: [EngineResult(start: 5, end: 6.5, text: "That works for me.")]), channel: .mic)
        journal.record(EngineUpdate(volatile: EngineResult(start: 6, end: 7, text: "Then we ship on")), channel: .system)
        journal.flush()

        let reopened = RecordingStore(rootURL: root)
        let recovered = reopened.recoverInterrupted(except: nil, myName: "Me")
        #expect(recovered.map(\.id) == [rec.id])
        let out = try #require(reopened.recording(rec.id))
        let texts = out.visibleSegments.map(\.text)
        #expect(texts.filter { $0.contains("budget") }.count == 1)
        #expect(texts.contains { $0.contains("Marketing asked for twenty more") })
        #expect(texts.contains { $0.contains("That works for me") })
        #expect(texts.contains { $0.contains("Then we ship on") })
        #expect(out.visibleSegments.filter { $0.channel == .mic }.allSatisfy { $0.speakerID == Speaker.meID })
        #expect(out.visibleSegments.filter { $0.channel == .system }.allSatisfy { out.speaker($0.speakerID) != nil })
        #expect(out.channelOffsets?["mic"] == 0.5)
        #expect(out.channelOffsets?["system"] == 1)
        #expect(out.endedAt != nil)
        #expect(abs(out.duration - 8) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
    }

    @Test func journalSkipsALineCutShortByTheCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = TranscriptJournal(folder: dir)
        journal.record(EngineUpdate(finals: [EngineResult(start: 0, end: 1, text: "Hello there.")]), channel: .mic)
        journal.flush()
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"final","channel":"mic","sta"#.utf8))
        try handle.close()
        let entries = TranscriptJournal.read(in: dir)
        #expect(entries.count == 1)
        #expect(entries.first?.text == "Hello there.")
    }

    @Test func journalIsGoneAfterACleanStop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = TranscriptJournal(folder: dir)
        journal.record(EngineUpdate(finals: [EngineResult(start: 0, end: 1, text: "Hello there.")]), channel: .mic)
        journal.discard()
        journal.record(EngineUpdate(finals: [EngineResult(start: 1, end: 2, text: "Late result.")]), channel: .mic)
        journal.flush()
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
    }

    @Test func backgroundAutosaveNeverOverwritesALaterSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-autosave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        var rec = Recording(meeting: MeetingInfo(title: "Live"), startedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.segments = (0..<2000).map { i in
            Segment(channel: .mic, speakerID: Speaker.meID, start: Double(i), end: Double(i) + 0.9, text: "Line \(i)", isFinal: true)
        }
        store.persistInBackground(rec)
        var finished = rec
        finished.endedAt = .now
        store.save(finished)
        #expect(RecordingStore(rootURL: root).recording(rec.id)?.endedAt != nil)
    }
}
