import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// "Continue recording" after a stop: the new part goes on the same
/// timeline, the audio files stay continuous, and the break isn't counted.
@MainActor
struct ContinueRecordingTests {
    func tone(seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormats.mono16k, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.3) }
        return buffer
    }

    func writeLive(_ url: URL, seconds: Double) throws {
        let sink = try AudioFileSink(url: url)
        sink.write(tone(seconds: seconds))
        sink.close()
    }

    func writeSaved(_ url: URL, seconds: Double) throws {
        let caf = url.deletingPathExtension().appendingPathExtension("tmp.caf")
        try writeLive(caf, seconds: seconds)
        try AudioFileSink.compress(caf, to: url)
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-continue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func durationLeavesOutTheBreak() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: start, endedAt: start.addingTimeInterval(600),
                            language: "en-US", engine: "apple", micMode: .solo)
        #expect(rec.duration == 600)
        rec.continuations = [.init(at: 300, gap: 120)]
        #expect(rec.duration == 480)
    }

    @Test func planLinesUpTimelineAndFiles() {
        let now = Date.now
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: now.addingTimeInterval(-400), endedAt: now.addingTimeInterval(-100),
                            language: "en-US", engine: "apple", micMode: .solo)
        rec.channelOffsets = ["mic": 0, "system": 0]
        rec.refinedAt = now
        // The mic has audio; the call audio never arrived in the first part.
        let plan = ContinuationPlan(recording: rec, savedSeconds: [.mic: 299.5, .system: 0])
        #expect(abs(plan.base - 300) < 0.001)
        #expect(plan.fileEnds[.mic] == 299.5)
        #expect(plan.fileEnds[.system] == nil)
        // The mic file keeps its start; the call audio's file starts where it
        // was first heard in the new part.
        #expect(plan.fileOffsets(live: ["mic": 300.2, "system": 305]) == ["mic": 0, "system": 305])

        #expect(ContinuationPlan.labelPrefix(for: rec) == "p2.")
        let reopened = plan.reopened(rec, at: now)
        #expect(reopened.endedAt == nil)
        #expect(reopened.refinedAt == nil)
        #expect(reopened.continuations?.count == 1)
        #expect(abs((reopened.continuations?.first?.at ?? 0) - 300) < 0.001)
        #expect(abs((reopened.continuations?.first?.gap ?? 0) - 100) < 0.001)
        // Live length right after continuing is what was recorded before.
        #expect(abs(reopened.duration - 300) < 1)
        #expect(ContinuationPlan.labelPrefix(for: reopened) == "p3.")
    }

    @Test func pipelinePadsTheMomentBeforeNewAudioWithSilence() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("mic.caf")
        let pipe = ChannelPipeline(channel: .mic, policy: .firstChannel, sink: try AudioFileSink(url: caf), transcriber: nil, diarizer: nil)
        let host = mach_absolute_time()
        // The saved file ends 1.5 s before this buffer's place on the timeline.
        pipe.continueFile(endingAt: 100, zeroHost: AudioFormats.hostTimeToSeconds(host) - 101.5)
        pipe.ingest(tone(seconds: 1), hostTime: host)
        pipe.ingest(tone(seconds: 1), hostTime: host + 1) // only the first buffer is padded
        await pipe.finish()

        let file = try AVAudioFile(forReading: caf)
        #expect(file.length == 24_000 + 32_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(samples[0..<24_000].allSatisfy { $0 == 0 })
        #expect(samples[24_000..<26_000].contains { abs($0) > 0.1 })
    }

    @Test func finishingAppendsTheNewPartToSavedAudio() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // mic: 2 s saved + 1 s new. system: nothing saved before (an empty
        // file, as when call audio never arrived) + 1.5 s new.
        try writeSaved(dir.appendingPathComponent("mic.m4a"), seconds: 2)
        try writeLive(dir.appendingPathComponent("mic.caf"), seconds: 1)
        let emptyCaf = dir.appendingPathComponent("empty.caf")
        AudioFileSink.makeEmpty(at: emptyCaf)
        try AudioFileSink.compress(emptyCaf, to: dir.appendingPathComponent("system.m4a"))
        try writeLive(dir.appendingPathComponent("system.caf"), seconds: 1.5)

        RecordingStore.finalizeAudio(in: dir)

        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mic.m4a")).length == 48_000)
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("system.m4a")).length == 24_000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["mic.m4a", "system.m4a"])
    }

    @Test func continuedRecordingInterruptedByACrashKeepsItsFullLength() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        var rec = Recording(meeting: MeetingInfo(title: "Crashed"), startedAt: .now.addingTimeInterval(-1000),
                            language: "en-US", engine: "apple", micMode: .solo)
        rec.channelOffsets = ["mic": 0]
        rec.continuations = [.init(at: 2, gap: 500)]
        try FileManager.default.createDirectory(at: store.folder(for: rec.id), withIntermediateDirectories: true)
        try writeSaved(store.audioURL(for: rec.id, channel: .mic), seconds: 2)
        try writeLive(store.liveAudioURL(for: rec.id, channel: .mic), seconds: 3)
        store.save(rec) // endedAt == nil while the continued part records

        let reopened = RecordingStore(rootURL: root)
        reopened.recoverInterrupted(except: nil)
        let recovered = try #require(reopened.recording(rec.id))
        #expect(abs(recovered.duration - 5) < 0.1)
        #expect(abs(recovered.endedAt!.timeIntervalSince(recovered.startedAt) - 505) < 0.1)
        #expect(try AVAudioFile(forReading: reopened.audioURL(for: rec.id, channel: .mic)).length == 80_000)
    }

    @Test func newVoicesDontLandOnTheEarlierPartsSpeakers() {
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, language: "en-US", engine: "soniox", micMode: .solo)
        rec.speakers = [
            Speaker(id: "system:1", name: "Avery", colorIndex: 1, isConfirmed: true),
            Speaker(id: "system:2", name: "Speaker 3", colorIndex: 2),
        ]
        let transcript = LiveTranscript(recording: rec, myName: "Me")
        transcript.labelPrefix = ContinuationPlan.labelPrefix(for: rec)
        transcript.configure(.system, .init(engineDiarizes: true, fallbackLabel: "Speaker"))
        transcript.apply(EngineUpdate(finals: [EngineResult(start: 400, end: 402, text: "Back again.", speaker: "1")]), channel: .system)
        let segment = transcript.recording.segments.last
        #expect(segment?.speakerID == "system:p2.1")
        // "Speaker 3" is taken, so the new voice gets the next free number.
        #expect(transcript.recording.speaker("system:p2.1")?.name == "Speaker 4")
        #expect(transcript.recording.speaker("system:1")?.name == "Avery")
    }

    @Test func crashJournalOfAContinuedPartKeepsFileOffsetsAndNewSpeakerKeys() {
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now.addingTimeInterval(-900),
                            language: "en-US", engine: "soniox", micMode: .solo)
        rec.channelOffsets = ["mic": 0, "system": 4] // file offsets, as autosaved
        rec.continuations = [.init(at: 300, gap: 200)]
        rec.speakers = [Speaker(id: "system:1", name: "Avery", colorIndex: 1, isConfirmed: true)]
        rec.segments = [Segment(channel: .system, speakerID: "system:1", start: 280, end: 284, text: "See you after the break.", isFinal: true)]
        let entries = [
            TranscriptJournal.Entry(kind: .offset, channel: .system, start: 300.4),
            TranscriptJournal.Entry(kind: .result, channel: .system, start: 2, end: 4, text: "We're back.", speaker: "1"),
        ]
        let out = JournalRecovery.merge(entries, into: rec, myName: "Me", savedChannels: [.mic, .system]).recording
        let back = out.segments.first { $0.text.contains("back") }
        #expect(back?.speakerID == "system:p2.1")
        #expect(abs((back?.start ?? 0) - 302.4) < 0.01)
        #expect(out.channelOffsets?["system"] == 4)
        #expect(out.speaker("system:1")?.name == "Avery")
    }
}
