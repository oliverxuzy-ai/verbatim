import AVFAudio
import Foundation
import Testing
@testable import Verbatim

struct EchoFilterTests {
    @Test func tokenizesEnglishAndChinese() {
        #expect(EchoFilter.tokens("Hello, World! It's") == ["hello", "world", "it's"])
        #expect(EchoFilter.tokens("语义层 dbt") == ["语", "义", "层", "dbt"])
    }

    @Test func flagsMicLeakOfSystemSpeech() {
        let sys = Segment(channel: .system, speakerID: "system:0", start: 10, end: 14,
                          text: "We should move the semantic layer into dbt", isFinal: true)
        #expect(EchoFilter.isEcho(micText: "move the semantic layer into dbt", micStart: 10.5, micEnd: 13.8, system: [sys]))
    }

    @Test func keepsGenuineReplies() {
        let sys = Segment(channel: .system, speakerID: "system:0", start: 10, end: 14,
                          text: "We should move the semantic layer into dbt", isFinal: true)
        #expect(!EchoFilter.isEcho(micText: "I agree, but the cost needs a POC first", micStart: 14.5, micEnd: 17, system: [sys]))
        // Same words far apart in time are not echo.
        #expect(!EchoFilter.isEcho(micText: "move the semantic layer into dbt", micStart: 60, micEnd: 63, system: [sys]))
    }
}

struct TextJoinTests {
    @Test func joinsPiecesAndCJK() {
        #expect(TextJoin.join([" Hello", " world", "."]) == "Hello world.")
        #expect(TextJoin.append("Hello", "world") == "Hello world")
        #expect(TextJoin.append("Hello", ", world") == "Hello, world")
        #expect(TextJoin.append("我们", "开始吧") == "我们开始吧")
        #expect(TextJoin.append("我们开始吧。", "OK") == "我们开始吧。OK")
    }
}

struct SpanBuilderTests {
    @Test func splitsWordsBySpeaker() {
        let result = EngineResult(start: 0, end: 4, text: "Hi there. Hello back.", words: [
            TimedWord(text: "Hi", start: 0, end: 0.4),
            TimedWord(text: " there.", start: 0.4, end: 0.9),
            TimedWord(text: " Hello", start: 2.0, end: 2.5),
            TimedWord(text: " back.", start: 2.5, end: 3.0),
        ])
        let spans = SpanBuilder.spans(for: result, offset: 10) { $0.start < 1.5 ? "system:0" : "system:1" }
        #expect(spans.count == 2)
        #expect(spans[0].text == "Hi there.")
        #expect(spans[0].speakerKey == "system:0")
        #expect(spans[0].start == 10)
        #expect(spans[1].text == "Hello back.")
        #expect(spans[1].speakerKey == "system:1")
        #expect(spans[1].end == 13)
    }
}

struct VocabularyTests {
    @Test func buildsTermsFromMeeting() {
        let meeting = MeetingInfo(title: "BI WKLY 1:1 Oliver & Hsiao", attendees: [
            Attendee(name: "Hsiao-Wen Lin", email: "hsiao@example.com"),
            Attendee(name: "", email: "ananya.rao@example.com"),
        ])
        let terms = VocabularyBuilder.terms(meeting: meeting, userTerms: ["dbt", "Snowflake"], myName: "Oliver Xu")
        #expect(terms.contains("dbt"))
        #expect(terms.contains("Hsiao-Wen Lin"))
        #expect(terms.contains("Ananya Rao"))
        #expect(terms.contains("WKLY"))
        #expect(terms.contains("Oliver"))
    }
}

struct NotionExporterTests {
    func sampleRecording() -> Recording {
        var rec = Recording(
            meeting: MeetingInfo(title: "1on1 with Hsiao", scheduledStart: nil, scheduledEnd: nil, attendees: [
                Attendee(name: "Oliver", email: "oliver@example.com", isSelf: true),
                Attendee(name: "Hsiao-Wen Lin", email: "hsiao@example.com"),
            ], conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            endedAt: Date(timeIntervalSince1970: 1_760_001_800),
            language: "en-US", engine: "apple", micMode: .solo
        )
        rec.speakers = [
            Speaker(id: "me", name: "Oliver", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Hsiao-Wen Lin", email: "hsiao@example.com", colorIndex: 1, isConfirmed: true),
        ]
        rec.segments = [
            Segment(channel: .system, speakerID: "system:0", start: 3, end: 6, text: "Let's go through your project.", isFinal: true),
            Segment(channel: .mic, speakerID: "me", start: 7, end: 12, text: "The first thing is the semantic layer.", isFinal: true),
            Segment(channel: .mic, speakerID: "me", start: 8, end: 9, text: "echo line", isFinal: true, isEcho: true),
        ]
        return rec
    }

    @Test func mapsPropertiesToSchema() throws {
        let schema = [
            "会议标题": "title", "会议日期": "date", "时长（分钟）": "number", "外部参会人": "rich_text",
            "参会人（工作区成员）": "people", "来源": "select", "整理状态": "status", "录音 / 会议链接": "url",
        ]
        let members = [(id: "user-1", email: "oliver@example.com", name: "Oliver")]
        let props = NotionExporter.properties(for: sampleRecording(), schema: schema, members: members, sourceOption: "Verbatim")
        #expect(props["时长（分钟）"] as? [String: Int] == ["number": 30])
        #expect((props["整理状态"] as? [String: [String: String]])?["status"]?["name"] == "待整理")
        #expect((props["来源"] as? [String: [String: String]])?["select"]?["name"] == "Verbatim")
        #expect((props["录音 / 会议链接"] as? [String: String])?["url"] == "https://meet.google.com/abc-defg-hij")
        let people = (props["参会人（工作区成员）"] as? [String: [[String: String]]])?["people"]
        #expect(people?.first?["id"] == "user-1")
        let external = (props["外部参会人"] as? [String: [[String: Any]]])?["rich_text"]?.first?["text"] as? [String: String]
        #expect(external?["content"] == "Hsiao-Wen Lin")
        let date = (props["会议日期"] as? [String: [String: String]])?["date"]
        #expect(date?["start"] != nil && date?["end"] != nil)
    }

    @Test func skipsPropertiesMissingFromSchema() {
        let props = NotionExporter.properties(for: sampleRecording(), schema: ["Name": "title"], members: [], sourceOption: "Verbatim")
        #expect(props.keys.sorted() == ["Name"])
    }

    @Test func transcriptBlocksSkipEchoAndCarryTimestamps() throws {
        let blocks = NotionExporter.transcriptBlocks(for: sampleRecording())
        #expect(blocks.count == 2)
        let rich = (blocks[1]["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]
        let texts = rich?.compactMap { ($0["text"] as? [String: String])?["content"] }
        #expect(texts == ["[00:00:07] ", "Oliver: ", "The first thing is the semantic layer."])
    }

    @Test func skeletonHasOnlySummaryAndDiscussion() {
        let blocks = NotionExporter.skeleton(for: sampleRecording())
        let headings = blocks.compactMap { b -> String? in
            guard b["type"] as? String == "heading_2",
                  let rich = (b["heading_2"] as? [String: Any])?["rich_text"] as? [[String: Any]] else { return nil }
            return (rich.first?["text"] as? [String: String])?["content"]
        }
        #expect(headings == ["摘要", "讨论要点"])
    }

    @Test func chunksLongTextUnderNotionLimit() {
        let long = String(repeating: "word ", count: 1000)
        let chunks = NotionExporter.chunks(long, size: 1900)
        #expect(chunks.allSatisfy { $0.count <= 1900 })
        #expect(chunks.joined() == long)
    }
}

@MainActor
struct LiveTranscriptTests {
    func makeTranscript(attendees: [Attendee] = []) -> LiveTranscript {
        let rec = Recording(meeting: MeetingInfo(title: "Test", attendees: attendees), startedAt: .now,
                            language: "en-US", engine: "apple", micMode: .solo)
        let t = LiveTranscript(recording: rec, myName: "Oliver")
        t.configure(.mic, .init(fixedSpeaker: Speaker.meID, fallbackLabel: "In room"))
        t.configure(.system, .init(engineDiarizes: true, fallbackLabel: "Speaker"))
        return t
    }

    @Test func mergesShortPausesAndSplitsSpeakers() {
        let t = makeTranscript()
        t.apply(EngineUpdate(finals: [EngineResult(start: 0, end: 2, text: "Hello there.", speaker: "1")]), channel: .system)
        t.apply(EngineUpdate(finals: [EngineResult(start: 2.5, end: 4, text: "How are you?", speaker: "1")]), channel: .system)
        t.apply(EngineUpdate(finals: [EngineResult(start: 4.5, end: 6, text: "Fine, thanks.", speaker: "2")]), channel: .system)
        let segs = t.recording.visibleSegments
        #expect(segs.count == 2)
        #expect(segs[0].text == "Hello there. How are you?")
        #expect(segs[1].speakerID == "system:2")
        #expect(t.recording.speakers.count == 2)
    }

    @Test func micIsMeAndEchoIsHidden() {
        let t = makeTranscript()
        t.apply(EngineUpdate(finals: [EngineResult(start: 0, end: 3, text: "the budget is twenty thousand dollars", speaker: "1")]), channel: .system)
        t.apply(EngineUpdate(finals: [EngineResult(start: 0.2, end: 3.1, text: "the budget is twenty thousand dollars")]), channel: .mic)
        t.apply(EngineUpdate(finals: [EngineResult(start: 4, end: 5, text: "Okay, sounds good.")]), channel: .mic)
        let segs = t.recording.visibleSegments
        #expect(segs.count == 2)
        #expect(segs.last?.speakerID == Speaker.meID)
        #expect(t.recording.speaker(Speaker.meID)?.name == "Oliver")
    }

    @Test func suggestsOtherAttendeeInOneOnOne() {
        let t = makeTranscript(attendees: [
            Attendee(name: "Oliver", email: "o@x.com", isSelf: true),
            Attendee(name: "Hsiao-Wen Lin", email: "c@x.com"),
        ])
        t.apply(EngineUpdate(finals: [EngineResult(start: 0, end: 2, text: "Hi Oliver.", speaker: "1")]), channel: .system)
        let speaker = t.recording.speaker("system:1")
        #expect(speaker?.name == "Hsiao-Wen Lin")
        #expect(speaker?.isConfirmed == false)
    }

    @Test func volatileReplacesAndClears() {
        let t = makeTranscript()
        t.apply(EngineUpdate(finals: [], volatile: EngineResult(start: 0, end: 1, text: "Hel")), channel: .mic)
        #expect(t.volatile[.mic]?.text == "Hel")
        t.apply(EngineUpdate(finals: [EngineResult(start: 0, end: 1.5, text: "Hello.")], volatile: nil), channel: .mic)
        #expect(t.volatile[.mic] == nil)
        #expect(t.recording.visibleSegments.map(\.text) == ["Hello."])
    }
}

struct SonioxParsingTests {
    @Test func assemblesSubwordTokensIntoWordsWithSpeakers() {
        let engine = SonioxTranscriber(apiKey: "test", context: TranscriptionContext(language: "mixed", terms: [], meetingTitle: "", attendeeNames: []), diarize: true)
        let collected = Locked<[EngineUpdate]>([])
        engine.updates = { u in collected.withLock { $0.append(u) } }

        engine.handle(Data(#"{"tokens":[{"text":"Hel","start_ms":100,"end_ms":200,"is_final":true,"speaker":"1"},{"text":"lo","start_ms":200,"end_ms":300,"is_final":true,"speaker":"1"},{"text":" every","start_ms":400,"end_ms":600,"is_final":false,"speaker":"1"}]}"#.utf8))
        engine.handle(Data(#"{"tokens":[{"text":" everyone","start_ms":400,"end_ms":800,"is_final":true,"speaker":"1"},{"text":"我","start_ms":1500,"end_ms":1700,"is_final":true,"speaker":"2"},{"text":"们","start_ms":1700,"end_ms":1900,"is_final":true,"speaker":"2"}]}"#.utf8))
        engine.handle(Data(#"{"tokens":[],"finished":true}"#.utf8))

        let updates = collected.current
        let finals = updates.flatMap(\.finals)
        #expect(finals.map(\.text) == ["Hello", " everyone", "我", "们"])
        #expect(finals.map(\.speaker) == ["1", "1", "2", "2"])
        #expect(abs((finals.first?.start ?? 0) - 0.1) < 0.001)
        #expect(abs((finals[1].end) - 0.8) < 0.001)
        // First response shows the non-final tail as volatile text.
        #expect(updates.first?.volatile?.text.contains("every") == true)
    }

    @Test func languageHints() {
        #expect(SonioxTranscriber.languageHints("mixed") == ["en", "zh"])
        #expect(SonioxTranscriber.languageHints("en-US") == ["en"])
        #expect(SonioxTranscriber.languageHints("ja-JP") == ["ja", "en"])
    }

    @MainActor @Test func sonioxWordsBecomeSpeakerTurns() {
        let rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, language: "mixed", engine: "soniox", micMode: .solo)
        let t = LiveTranscript(recording: rec, myName: "Oliver")
        t.configure(.system, .init(engineDiarizes: true, fallbackLabel: "Speaker"))
        let words: [(String, Double, Double, String)] = [("Hello", 0.1, 0.3, "1"), (" everyone", 0.4, 0.8, "1"), ("我", 1.5, 1.7, "2"), ("们", 1.7, 1.9, "2"), ("开始", 1.9, 2.3, "2")]
        for w in words {
            t.apply(EngineUpdate(finals: [SonioxTranscriber.result(from: [TimedWord(text: w.0, start: w.1, end: w.2, speaker: w.3)])]), channel: .system)
        }
        let segs = t.recording.visibleSegments
        #expect(segs.map(\.text) == ["Hello everyone", "我们开始"])
        #expect(segs.map(\.speakerID) == ["system:1", "system:2"])
    }
}

struct CalendarRulesTests {
    @Test func parsesOneOnOneTitles() {
        #expect(CalendarRules.namesFromTitle("BI WKLY 1:1 Oliver & Hsiao", excluding: "Oliver", selfNames: []) == ["Hsiao"])
        #expect(CalendarRules.namesFromTitle("1on1 with Hsiao", excluding: "Me", selfNames: []) == ["Hsiao"])
        #expect(CalendarRules.namesFromTitle("Oliver x Ananya", excluding: "Oliver Xu", selfNames: []) == ["Ananya"])
        #expect(CalendarRules.namesFromTitle("WKLY Data Team Meeting", excluding: "Oliver", selfNames: []).isEmpty)
    }

    @Test func eliminationNamesTheLastRemoteVoice() {
        var rec = Recording(meeting: MeetingInfo(title: "Sync", attendees: [
            Attendee(name: "Me", isSelf: true), Attendee(name: "Hsiao"), Attendee(name: "Ananya"),
        ]), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.speakers = [
            Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Hsiao", colorIndex: 1, isConfirmed: true),
            Speaker(id: "system:1", name: "Speaker 2", colorIndex: 2),
        ]
        rec.segments = [
            Segment(channel: .system, speakerID: "system:0", start: 0, end: 3, text: "hi", isFinal: true),
            Segment(channel: .system, speakerID: "system:1", start: 4, end: 7, text: "hello", isFinal: true),
        ]
        let named = CalendarRules.apply(rec, myName: "Me")
        #expect(named.speaker("system:1")?.name == "Ananya")
        #expect(named.speaker("system:1")?.isConfirmed == false)
        #expect(named.speakerSources?["system:1"] == "calendar")
    }
}

struct SpeakerCarryOverTests {
    /// The live diarizer heard three people as one remote voice; the refine
    /// tells them apart. They stay three, and the confirmed name goes to the
    /// one who did most of the talking, wherever they come in the list.
    @Test func keepsVoicesTheLiveDiarizerMerged() {
        var old = Recording(meeting: MeetingInfo(title: "Sprint planning"), startedAt: .now, endedAt: .now,
                            language: "en-US", engine: "apple", micMode: .solo)
        old.speakers = [
            Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Alex", colorIndex: 1, isConfirmed: true),
        ]
        old.segments = [
            Segment(channel: .system, speakerID: "system:0", start: 0, end: 5, text: "Short one.", isFinal: true),
            Segment(channel: .system, speakerID: "system:0", start: 6, end: 36, text: "Long one.", isFinal: true),
            Segment(channel: .system, speakerID: "system:0", start: 37, end: 47, text: "Middle one.", isFinal: true),
        ]
        var new = old
        new.speakers = [
            Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:S1", name: "Speaker 1", colorIndex: 1),
            Speaker(id: "system:S2", name: "Speaker 2", colorIndex: 2),
            Speaker(id: "system:S3", name: "Speaker 3", colorIndex: 3),
        ]
        for (i, id) in ["system:S1", "system:S2", "system:S3"].enumerated() { new.segments[i].speakerID = id }

        let carried = SpeakerCarryOver.apply(from: old, to: new)
        #expect(carried.speakers.filter { !$0.isMe }.count == 3)
        #expect(carried.segments.map(\.speakerID) == ["system:rS1", "system:0", "system:rS3"])
        #expect(carried.speaker("system:0")?.name == "Alex")
        #expect(carried.speakers.filter { $0.name == "Alex" }.count == 1)
    }

    /// Refining twice: the first refine left "system:rS1" (you) and
    /// "system:rS2" (Bob). New clusters that share no time with them must
    /// not pick up those names just because pyannote reused the labels.
    @Test func secondRefineDoesNotInheritNamesByLabel() {
        var old = Recording(meeting: MeetingInfo(title: "Sync"), startedAt: .now, endedAt: .now,
                            language: "en-US", engine: "apple", micMode: .solo)
        old.speakers = [
            Speaker(id: "system:rS1", name: "Me", colorIndex: 1, isMe: true, isConfirmed: true),
            Speaker(id: "system:rS2", name: "Bob", colorIndex: 2, isConfirmed: true),
        ]
        old.segments = [
            Segment(channel: .system, speakerID: "system:rS1", start: 0, end: 10, text: "Mine.", isFinal: true),
            Segment(channel: .system, speakerID: "system:rS2", start: 11, end: 20, text: "Bob's.", isFinal: true),
        ]
        var new = old
        new.speakers = [
            Speaker(id: "system:S1", name: "Speaker 1", colorIndex: 1),
            Speaker(id: "system:S2", name: "Speaker 2", colorIndex: 2),
        ]
        new.segments = [
            Segment(channel: .system, speakerID: "system:S1", start: 30, end: 40, text: "Later.", isFinal: true),
            Segment(channel: .system, speakerID: "system:S2", start: 41, end: 50, text: "Later still.", isFinal: true),
        ]

        let carried = SpeakerCarryOver.apply(from: old, to: new)
        #expect(carried.segments.map(\.speakerID) == ["system:rS1-2", "system:rS2-2"])
        #expect(!carried.speakers.contains { $0.name == "Bob" || $0.isMe })
    }

    @Test func mergingMovesLinesAndJoinsTurns() {
        var rec = Recording(meeting: MeetingInfo(title: "Room"), startedAt: .now, endedAt: .now,
                            language: "en-US", engine: "apple", micMode: .solo)
        rec.speakers = [
            Speaker(id: "me", name: "Me", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:S1", name: "Speaker 1", colorIndex: 1),
        ]
        rec.speakerSources = ["system:S1": "voiceprint"]
        rec.segments = [
            Segment(channel: .system, speakerID: "me", start: 0, end: 4, text: "So this is", isFinal: true),
            Segment(channel: .system, speakerID: "system:S1", start: 4.5, end: 8, text: "the semantic layer.", isFinal: true),
        ]
        let merged = rec.merging("system:S1", into: "me")
        #expect(merged.speakers.map(\.id) == ["me"])
        #expect(merged.speakerSources?["system:S1"] == nil)
        #expect(merged.segments.map(\.text) == ["So this is the semantic layer."])
    }
}

struct SharedVoiceTests {
    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / n }
    }

    /// The same voice on the mic and on the call audio is one person; a
    /// voice only on the mic is not.
    @Test func matchesVoicesAcrossChannels() {
        let mic = ["S1": Self.unit([1, 0.2, 0]), "S2": Self.unit([0, 0, 1])]
        let call = ["S1": Self.unit([1, 0.3, 0.1]), "S2": Self.unit([0, 1, 0])]
        #expect(OfflineDiarization.sharedVoices(mic, call) == ["S1"])
        #expect(OfflineDiarization.sharedVoices(call, mic) == ["S1"])
        #expect(OfflineDiarization.sharedVoices(mic, [:]).isEmpty)
    }
}

struct LLMNamerGuardTests {
    func recording() -> Recording {
        var rec = Recording(meeting: MeetingInfo(title: "Kickoff", attendees: [
            Attendee(name: "Me", isSelf: true), Attendee(name: "Hsiao-Wen Lin", email: "c@x.com"), Attendee(name: "Ananya Iyer"),
        ]), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .room)
        rec.speakers = [
            Speaker(id: "mic:0", name: "In room 1", colorIndex: 1),
            Speaker(id: "mic:1", name: "In room 2", colorIndex: 2),
            Speaker(id: "mic:2", name: "In room 3", colorIndex: 3),
        ]
        rec.segments = [
            Segment(channel: .mic, speakerID: "mic:0", start: 0, end: 4, text: "Hi all, I'm Nadia, the project manager.", isFinal: true),
            Segment(channel: .mic, speakerID: "mic:1", start: 5, end: 8, text: "Thanks Nadia. Ananya, want to start?", isFinal: true),
            Segment(channel: .mic, speakerID: "mic:2", start: 9, end: 12, text: "Sure, happy to.", isFinal: true),
        ]
        return rec
    }

    @Test func acceptsGroundedNamesAndRejectsTheRest() {
        let rec = recording()
        let reply = #"""
        {"speakers":[
          {"label":"mic:0","name":"Nadia","confidence":0.95,"evidence":"[00:00:00] I'm Nadia"},
          {"label":"mic:2","name":"Ananya","confidence":0.8,"evidence":"answers after being addressed"},
          {"label":"mic:1","name":"Zhang Wei","confidence":0.9,"evidence":"invented"},
          {"label":"mic:9","name":"Hsiao-Wen Lin","confidence":0.9,"evidence":"unknown label"}
        ]}
        """#
        let out = LLMSpeakerNamer.parse(reply, recording: rec, anonymous: rec.speakers)
        #expect(out.map(\.speakerID) == ["mic:0", "mic:2"])
        #expect(out.first?.name == "Nadia")
        // First names resolve to the full invitee name.
        #expect(out.last?.name == "Ananya Iyer")
    }

    @Test func oneLabelPerPersonAndConfidenceFloor() {
        let rec = recording()
        let reply = #"{"speakers":[{"label":"mic:0","name":"Nadia","confidence":0.9,"evidence":""},{"label":"mic:1","name":"Nadia","confidence":0.7,"evidence":""},{"label":"mic:2","name":"Ananya Iyer","confidence":0.3,"evidence":""}]}"#
        let out = LLMSpeakerNamer.parse(reply, recording: rec, anonymous: rec.speakers)
        #expect(out.map(\.speakerID) == ["mic:0"])
    }
}

struct CrashSafeAudioTests {
    @Test func liveAudioIsReadableBeforeCloseAndCompressesLosslessly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("mic.caf")
        let sink = try AudioFileSink(url: caf)
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormats.mono16k, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.3) }
        for _ in 0..<3 { sink.write(buffer) }
        // "Crash": read while the writer is still open, never closed.
        let reader = try AVAudioFile(forReading: caf)
        #expect(reader.length >= 32_000)
        sink.close()
        let m4a = dir.appendingPathComponent("mic.m4a")
        try AudioFileSink.compress(caf, to: m4a)
        let compressed = try AVAudioFile(forReading: m4a)
        #expect(compressed.length == 48_000)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
    }
}

struct LeakedWordTests {
    func words(_ text: String, from start: Double, step: Double = 0.3) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            TimedWord(text: (i == 0 ? "" : " ") + w, start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8)
        }
    }

    @Test func dropsLeakedRunButKeepsOwnWordsInTheSameSentence() {
        let system = words("before we dive in can you remind us", from: 10.0)
        let mic = words("before we dive in", from: 10.05) + words("it is about twenty thousand calls", from: 13.0)
        let kept = EchoFilter.removeLeakedWords(mic, system: system)
        #expect(TextJoin.join(kept.map(\.text)) == "it is about twenty thousand calls")
    }

    @Test func singleWordNeedsTightTiming() {
        let system = words("perfect", from: 20.0)
        #expect(EchoFilter.removeLeakedWords(words("perfect", from: 20.1), system: system).isEmpty)
        // Same word said by the user a second later is kept.
        #expect(EchoFilter.removeLeakedWords(words("perfect", from: 21.2), system: system).count == 1)
    }
}

struct NotionIDTests {
    @Test func acceptsLinksAndIDs() {
        #expect(NotionClient.normalizedID("https://app.notion.com/p/81976ae7c79d4186a56f26ea33839597?v=5563c3906c564de5b1048418bb7e8baf&source=copy_link")
                == "81976ae7-c79d-4186-a56f-26ea33839597")
        #expect(NotionClient.normalizedID("https://www.notion.so/myws/Meeting-Transcripts-81976ae7c79d4186a56f26ea33839597") == "81976ae7-c79d-4186-a56f-26ea33839597")
        #expect(NotionClient.normalizedID("collection://b5ef1419-6051-453b-a494-e59c7d8abbab") == "b5ef1419-6051-453b-a494-e59c7d8abbab")
        #expect(NotionClient.normalizedID(" b5ef14196051453ba494e59c7d8abbab ") == "b5ef1419-6051-453b-a494-e59c7d8abbab")
    }
}

struct ChannelFileTimeTests {
    @Test func subtractsTheChannelOffset() {
        // Call audio that only started arriving 151.7 s in: a line said at
        // 414.2 s of the recording sits at 262.5 s of system.m4a.
        var rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        rec.channelOffsets = ["mic": 0.4, "system": 151.7]
        #expect(abs(rec.fileTime(414.2, channel: .system) - 262.5) < 1e-9)
        #expect(abs(rec.fileTime(413.5, channel: .mic) - 413.1) < 1e-9)
    }

    @Test func oldRecordingsWithoutOffsetsUseRecordingTime() {
        let rec = Recording(meeting: MeetingInfo(title: "T"), startedAt: .now, language: "en-US", engine: "apple", micMode: .solo)
        #expect(rec.fileTime(42, channel: .system) == 42)
    }
}
