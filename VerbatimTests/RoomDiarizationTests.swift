import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// In-person scenario: four people, one far-field laptop mic
/// (Fixtures/make_room_fixture.py). Scores speaker attribution against the
/// ground-truth turns for both the live path and the post-meeting refine.
@MainActor
struct RoomDiarizationTests {
    struct Turn { let start: Double; let end: Double; let speaker: String; let text: String }

    static var truth: [Turn] {
        let url = PipelineIntegrationTests.fixtures.appendingPathComponent("room-truth.tsv")
        return (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
            return Turn(start: s, end: e, speaker: String(f[2]), text: String(f[3]))
        } ?? []
    }

    /// Duration-weighted accuracy after mapping each predicted speaker to the
    /// true speaker it overlaps most (many-to-one allowed, so over-splitting is
    /// penalised only through the count check).
    static func score(_ rec: Recording) -> (accuracy: Double, clusters: Int, report: String) {
        let segs = rec.visibleSegments
        var overlap: [String: [String: Double]] = [:]
        for turn in truth {
            for s in segs where s.end > turn.start && s.start < turn.end {
                overlap[s.speakerID, default: [:]][turn.speaker, default: 0] += min(s.end, turn.end) - max(s.start, turn.start)
            }
        }
        let mapping = overlap.mapValues { $0.max { $0.value < $1.value }?.key ?? "?" }
        var correct = 0.0, total = 0.0
        var lines: [String] = []
        for turn in truth {
            var bySpeaker: [String: Double] = [:]
            for s in segs where s.end > turn.start && s.start < turn.end {
                bySpeaker[s.speakerID, default: 0] += min(s.end, turn.end) - max(s.start, turn.start)
            }
            let predicted = bySpeaker.max { $0.value < $1.value }?.key
            let ok = predicted.flatMap { mapping[$0] } == turn.speaker
            let dur = turn.end - turn.start
            total += dur
            if ok { correct += dur }
            lines.append("\(ok ? "✓" : "✗") \(turn.speaker) → \(predicted.map { rec.speakerName($0) } ?? "none"): \(turn.text.prefix(50))")
        }
        return (total > 0 ? correct / total : 0, Set(segs.map(\.speakerID)).count, lines.joined(separator: "\n"))
    }

    func roomRecording() -> Recording {
        Recording(meeting: MeetingInfo(title: "Onboarding metrics", attendees: [
            Attendee(name: "Me", isSelf: true), Attendee(name: "Bea"), Attendee(name: "Carl"), Attendee(name: "Dana"),
        ]), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .room)
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(10)))
    func livePathSeparatesRoomSpeakers() async throws {
        let transcript = LiveTranscript(recording: roomRecording(), myName: "Me")
        let diarizer = LiveDiarizer(variant: .room)
        try await diarizer.prepare()
        let engine = AppleSpeechTranscriber(language: "en-US", terms: [])
        transcript.configure(.mic, .init(diarizer: diarizer, fallbackLabel: "In room"))
        let (stream, c) = AsyncStream<EngineUpdate>.makeStream()
        let consumer = Task { @MainActor in for await u in stream { transcript.apply(u, channel: .mic) } }
        try await engine.start { c.yield($0) }
        let pipe = ChannelPipeline(channel: .mic, policy: .firstChannel, sink: nil, transcriber: engine, diarizer: diarizer)
        let file = try AVAudioFile(forReading: PipelineIntegrationTests.fixtures.appendingPathComponent("meeting-room-mic.m4a"))
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800) else { break }
            try? file.read(into: buf, frameCount: 4800)
            guard buf.frameLength > 0 else { break }
            pipe.ingest(buf, hostTime: 0)
            try await Task.sleep(for: .milliseconds(30))
            transcript.resolvePending()
        }
        await pipe.finish()
        c.finish()
        await consumer.value
        transcript.finalizeLive()
        let result = Self.score(transcript.recording)
        print("LIVE room accuracy \(Int(result.accuracy * 100))%, \(result.clusters) speakers\n\(result.report)")
        #expect(result.accuracy >= 0.6)
    }

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(10)))
    func refineSeparatesRoomSpeakers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-room-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let rec = roomRecording()
        try FileManager.default.createDirectory(at: store.folder(for: rec.id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: PipelineIntegrationTests.fixtures.appendingPathComponent("meeting-room-mic.m4a"),
                                         to: store.audioURL(for: rec.id, channel: .mic))
        store.save(rec)
        let refined = try await TranscriptRefiner.refine(rec, store: store, myName: "Me", terms: [], retranscribe: true) { _ in }
        let result = Self.score(refined)
        print("REFINE room accuracy \(Int(result.accuracy * 100))%, \(result.clusters) speakers\n\(result.report)")
        for s in refined.visibleSegments { print("[\(s.start.clockString)] \(refined.speakerName(s.speakerID)): \(s.text)") }
        // Synthetic voices are harder to tell apart than real people (two TTS
        // male voices merge); the real-speech proof is AMIInPersonTests.
        #expect(result.accuracy >= 0.7)
    }
}
