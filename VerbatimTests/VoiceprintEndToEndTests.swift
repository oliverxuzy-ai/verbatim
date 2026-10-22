import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// "Confirm once, recognized next time" on real people: the first half of an
/// AMI meeting is processed and its four speakers are named (as a user
/// would), then the second half is processed as a new meeting and the
/// voiceprint library must name them on its own, without any wrong name.
@MainActor
struct VoiceprintEndToEndTests {
    static func writeSlice(from source: URL, start: Double, end: Double, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let sr = input.processingFormat.sampleRate
        input.framePosition = AVAudioFramePosition(start * sr)
        let total = AVAudioFrameCount((min(end, Double(input.length) / sr) - start) * sr)
        let output = try AVAudioFile(forWriting: target, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var remaining = total
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 64_000)!
        while remaining > 0 {
            try input.read(into: buffer, frameCount: min(64_000, remaining))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }

    /// True speaker per refined speaker ID, by shared speaking time.
    static func truthMap(_ rec: Recording, ref: [DiarizationBenchmarkTests.Ref], offset: Double) -> [String: String] {
        var overlap: [String: [String: Double]] = [:]
        for seg in rec.visibleSegments {
            for r in ref where r.end > seg.start + offset && r.start < seg.end + offset {
                overlap[seg.speakerID, default: [:]][r.speaker, default: 0] += min(r.end, seg.end + offset) - max(r.start, seg.start + offset)
            }
        }
        return overlap.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    @Test(.enabled(if: DiarizationBenchmarkTests.available), .timeLimit(.minutes(20)))
    func peopleConfirmedOnceAreRecognizedInTheNextMeeting() async throws {
        let meeting = "ES2004a"
        let source = DiarizationBenchmarkTests.dir.appendingPathComponent("\(meeting).Array1-01.wav")
        let ref = DiarizationBenchmarkTests.reference(meeting)
        let people = Set(ref.map(\.speaker)).sorted()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-vp-\(UUID().uuidString)/Recordings")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let model = AppModel(storeRoot: root)
        let attendees = [Attendee(name: "Me", isSelf: true)] + people.map { Attendee(name: $0, email: "\($0.lowercased())@example.com") }
        let split = 525.0

        func makeRecording(_ start: Double, _ end: Double) throws -> Recording {
            let rec = Recording(meeting: MeetingInfo(title: "AMI part", attendees: attendees), startedAt: .now.addingTimeInterval(-600),
                                endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
            try FileManager.default.createDirectory(at: model.store.folder(for: rec.id), withIntermediateDirectories: true)
            try Self.writeSlice(from: source, start: start, end: end, to: model.store.audioURL(for: rec.id, channel: .mic))
            let caf = model.store.liveAudioURL(for: rec.id, channel: .system)
            AudioFileSink.makeEmpty(at: caf)
            try AudioFileSink.compress(caf, to: model.store.audioURL(for: rec.id, channel: .system))
            model.store.save(rec)
            return rec
        }

        // Meeting 1: process, then confirm each speaker's true name.
        let first = try makeRecording(0, split)
        await model.postProcess(first)
        let processed = try #require(model.store.recording(first.id))
        let truth1 = Self.truthMap(processed, ref: ref, offset: 0)
        for speaker in processed.speakers where !speaker.isMe {
            guard let name = truth1[speaker.id] else { continue }
            model.updateSpeaker(recordingID: first.id, speakerID: speaker.id, name: name, email: "\(name.lowercased())@example.com")
        }
        let confirmed = try #require(model.store.recording(first.id))
        for speaker in confirmed.speakers where speaker.isConfirmed && !speaker.isMe {
            await model.voiceprints.learn(speaker: speaker, in: confirmed, store: model.store)
        }
        print("VOICEPRINT learned:", model.voiceprints.voiceprints.map(\.name).sorted())

        // Meeting 2: the same people, recognized automatically.
        let second = try makeRecording(split, 2000)
        await model.postProcess(second)
        let named = try #require(model.store.recording(second.id))
        let truth2 = Self.truthMap(named, ref: ref, offset: split)
        var correct = 0, wrong = 0
        for speaker in named.speakers where !speaker.isMe && named.speakerSources?[speaker.id] == "voiceprint" {
            if truth2[speaker.id] == speaker.name { correct += 1 } else { wrong += 1 }
            print("  \(speaker.id) named \(speaker.name) (confirmed \(speaker.isConfirmed)), truth \(truth2[speaker.id] ?? "?")")
        }
        print("VOICEPRINT second meeting: \(correct) correct, \(wrong) wrong of \(named.speakers.filter { !$0.isMe }.count) speakers")
        #expect(wrong == 0)
        #expect(correct >= 2)
    }
}
