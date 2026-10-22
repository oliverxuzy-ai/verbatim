import AVFAudio
import Foundation
import Speech
import Testing
@testable import Verbatim

/// End-to-end: synthesized two-channel meeting audio (see Fixtures/make_fixture.py)
/// through the real pipelines, Apple on-device ASR and the live diarizer.
/// Needs network on first run to download the speech and speaker models.
nonisolated final class FixtureBundleToken {}

/// These end-to-end tests transcribe with Apple's on-device recognizer, which
/// isn't on every Mac (GitHub's virtual Macs don't have it). Without it they
/// are skipped instead of failing for a reason that has nothing to do with
/// the code; on a Mac that has it they run as before.
nonisolated enum OnDeviceSpeech {
    static func isAvailable() async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return false }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        return await AssetInventory.status(forModules: [module]) != .unsupported
    }
}

@MainActor
struct PipelineIntegrationTests {
    /// Fixtures ship inside the test bundle. Reading them from the source
    /// tree would touch ~/Desktop, which macOS guards with a consent prompt.
    static let fixtures: URL = Bundle(for: FixtureBundleToken.self).resourceURL!

    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(10)))
    func transcribesBothChannelsWithSpeakersAndTimestamps() async throws {
        let meeting = MeetingInfo(title: "Semantic layer sync", attendees: [
            Attendee(name: "Oliver", email: "o@example.com", isSelf: true),
            Attendee(name: "Kathy", email: "k@example.com"),
            Attendee(name: "Daniel", email: "d@example.com"),
        ])
        let recording = Recording(meeting: meeting, startedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        let transcript = LiveTranscript(recording: recording, myName: "Oliver")

        let diarizer = LiveDiarizer(variant: .call)
        try await diarizer.prepare()
        let terms = VocabularyBuilder.terms(meeting: meeting, userTerms: ["dbt", "Snowflake", "semantic layer"], myName: "Oliver")
        let micEngine = AppleSpeechTranscriber(language: "en-US", terms: terms)
        let systemEngine = AppleSpeechTranscriber(language: "en-US", terms: terms)

        transcript.configure(.mic, .init(fixedSpeaker: Speaker.meID, fallbackLabel: "In room"))
        transcript.configure(.system, .init(diarizer: diarizer, fallbackLabel: "Speaker"))

        var tasks: [Task<Void, Never>] = []
        var continuations: [AsyncStream<EngineUpdate>.Continuation] = []
        func sink(_ channel: AudioChannel) -> @Sendable (EngineUpdate) -> Void {
            let (stream, c) = AsyncStream<EngineUpdate>.makeStream()
            continuations.append(c)
            tasks.append(Task { @MainActor in for await u in stream { transcript.apply(u, channel: channel) } })
            return { c.yield($0) }
        }
        try await micEngine.start(updates: sink(.mic))
        try await systemEngine.start(updates: sink(.system))

        let micPipe = ChannelPipeline(channel: .mic, policy: .firstChannel, sink: nil, transcriber: micEngine, diarizer: nil)
        let sysPipe = ChannelPipeline(channel: .system, policy: .average, sink: nil, transcriber: systemEngine, diarizer: diarizer)

        let micFile = try AVAudioFile(forReading: Self.fixtures.appendingPathComponent("meeting-mic.m4a"))
        let sysFile = try AVAudioFile(forReading: Self.fixtures.appendingPathComponent("meeting-system.m4a"))
        let chunk: AVAudioFrameCount = 4800
        while true {
            var any = false
            for (file, pipe) in [(micFile, micPipe), (sysFile, sysPipe)] {
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { continue }
                try? file.read(into: buf, frameCount: chunk)
                if buf.frameLength > 0 { pipe.ingest(buf, hostTime: 0); any = true }
            }
            if !any { break }
            // Feed at ~8x real time so the diarizer and analyzer keep pace.
            try await Task.sleep(for: .milliseconds(30))
            transcript.resolvePending()
        }
        await micPipe.finish()
        await sysPipe.finish()
        continuations.forEach { $0.finish() }
        for t in tasks { await t.value }
        transcript.finalizeLive()

        let rec = transcript.recording
        for s in rec.visibleSegments {
            print("[\(s.start.clockString)–\(s.end.clockString)] \(rec.speakerName(s.speakerID)) (\(s.speakerID)): \(s.text)")
        }

        let mic = rec.visibleSegments.filter { $0.channel == .mic }
        let sys = rec.visibleSegments.filter { $0.channel == .system }
        #expect(mic.allSatisfy { $0.speakerID == Speaker.meID })
        let micText = mic.map(\.text).joined(separator: " ").lowercased()
        #expect(micText.contains("twenty thousand") || micText.contains("20,000"))
        #expect(micText.contains("dbt"))
        let sysText = sys.map(\.text).joined(separator: " ").lowercased()
        #expect(sysText.contains("semantic layer"))
        #expect(sysText.contains("wednesday"))

        // Timestamps follow the script (Fixtures/make_fixture.py timeline).
        let expectedStarts: [(String, Double)] = [
            ("thanks for joining", 0.6), ("sounds good", 8.66), ("remind us", 16.0),
            ("calls per month", 23.77), ("rule-based", 29.08), ("40 to 50", 35.07),
            ("matches my numbers", 40.05), ("wednesday", 46.49),
        ]
        for (phrase, start) in expectedStarts {
            let line = rec.visibleSegments.first { $0.text.lowercased().contains(phrase) }
            #expect(line != nil, "missing line: \(phrase)")
            if let line { #expect(abs(line.start - start) < 0.8, "\(phrase): \(line.start) vs \(start)") }
        }

        // Two remote voices should come out as two speakers, and Samantha's first
        // and last lines should share a speaker distinct from Daniel's.
        let sysSpeakers = Set(sys.map(\.speakerID))
        #expect(sysSpeakers.count >= 2)
        let first = sys.first { $0.text.lowercased().contains("thanks for joining") }?.speakerID
        let daniel = sys.first { $0.text.lowercased().contains("remind us") }?.speakerID
        let last = sys.first { $0.text.lowercased().contains("wednesday") }?.speakerID
        #expect(first != nil && first == last)
        #expect(first != daniel)
    }
}

@MainActor
struct RefineIntegrationTests {
    @Test(.enabled("Needs Apple on-device speech recognition", { await OnDeviceSpeech.isAvailable() }), .timeLimit(.minutes(10)))
    func refineReclustersSpeakersAndKeepsConfirmedNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-refine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)

        var original = Recording(
            meeting: MeetingInfo(title: "Semantic layer sync", attendees: [
                Attendee(name: "Oliver", isSelf: true), Attendee(name: "Samantha"), Attendee(name: "Daniel"),
            ]),
            startedAt: .now.addingTimeInterval(-60), endedAt: .now, language: "en-US", engine: "apple", micMode: .solo
        )
        original.channelOffsets = ["mic": 0, "system": 0]
        // A deliberately rough live transcript: right names, one wrong split.
        original.speakers = [
            Speaker(id: "me", name: "Oliver", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Samantha", colorIndex: 1, isConfirmed: true),
            Speaker(id: "system:1", name: "Daniel", colorIndex: 2, isConfirmed: true),
        ]
        original.segments = [
            Segment(channel: .system, speakerID: "system:0", start: 0.6, end: 7.9, text: "hi everyone thanks for joining", isFinal: true),
            Segment(channel: .system, speakerID: "system:1", start: 16.0, end: 23.0, text: "remind us", isFinal: true),
            Segment(channel: .system, speakerID: "system:0", start: 29.1, end: 34.3, text: "rule based", isFinal: true),
            Segment(channel: .system, speakerID: "system:1", start: 35.1, end: 39.3, text: "forty to fifty", isFinal: true),
            Segment(channel: .system, speakerID: "system:0", start: 46.5, end: 50.9, text: "wednesday", isFinal: true),
        ]
        let folder = store.folder(for: original.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for ch in ["mic", "system"] {
            try FileManager.default.copyItem(
                at: PipelineIntegrationTests.fixtures.appendingPathComponent("meeting-\(ch).m4a"),
                to: store.audioURL(for: original.id, channel: AudioChannel(rawValue: ch)!)
            )
        }
        store.save(original)

        let refined = try await TranscriptRefiner.refine(original, store: store, myName: "Oliver", terms: ["dbt"], retranscribe: true) { print("progress:", $0) }
        for s in refined.visibleSegments {
            print("[\(s.start.clockString)] \(refined.speakerName(s.speakerID)) (\(s.speakerID)): \(s.text)")
        }
        func speaker(_ phrase: String) -> String? {
            refined.visibleSegments.first { $0.text.lowercased().contains(phrase) }.map { refined.speakerName($0.speakerID) }
        }
        #expect(speaker("thanks for joining") == "Samantha")
        #expect(speaker("wednesday") == "Samantha")
        #expect(speaker("remind us") == "Daniel")
        #expect(speaker("40 to 50") == "Daniel")
        #expect(speaker("calls per month") == "Oliver")
        #expect(refined.refinedAt != nil)
        let text = refined.visibleSegments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("semantic layer proof of concept"))
    }
}
