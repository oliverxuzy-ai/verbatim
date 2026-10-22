import AVFAudio
import FluidAudio
import Foundation
import Speech

nonisolated enum RefineError: LocalizedError {
    case noAudio
    case worseResult
    case droppedSpeech

    var errorDescription: String? {
        switch self {
        case .noAudio: "No saved audio for this recording."
        case .worseResult: "The refined transcript came out much shorter than the live one, so the live version was kept."
        case .droppedSpeech: "The refined transcript missed speech that the live one caught, so the live version was kept."
        }
    }
}

/// Post-meeting pass over the saved lossless audio, in two stages:
/// 1. Text (Apple recordings only): full-context re-transcription per channel.
/// 2. Speakers (every engine): whole-meeting clustering with pyannote
///    community-1, which scored 90 to 92% attribution on real AMI meetings
///    versus 63 to 75% for the live diarizer (DiarizationBenchmarkTests).
/// Names the user already confirmed carry over by shared speaking time.
enum TranscriptRefiner {
    static func refine(
        _ original: Recording,
        store: RecordingStore,
        myName: String,
        terms: [String],
        retranscribe: Bool,
        progress: @escaping (String) -> Void
    ) async throws -> Recording {
        let offsets = original.channelOffsets ?? [:]
        let attendees = original.meeting.attendees
        let others = attendees.filter { !$0.isSelf }.count

        func liveResults(_ channel: AudioChannel) -> [(AudioChannel, EngineResult)] {
            original.segments.filter { $0.channel == channel && !$0.isEcho }.map { (channel, result(from: $0)) }
        }

        // Stage 1: words per channel, in recording time. A channel that
        // captured (almost) nothing is skipped: the speech APIs can stall on
        // empty input, and there is nothing to transcribe anyway.
        var results: [(AudioChannel, EngineResult)] = []
        for channel in AudioChannel.allCases {
            let url = store.audioURL(for: original.id, channel: channel)
            let seconds = audioSeconds(url)
            guard retranscribe, seconds >= 1 else {
                results += liveResults(channel)
                continue
            }
            progress(channel == .mic ? "Re-transcribing your microphone…" : "Re-transcribing call audio…")
            let offset = offsets[channel.rawValue] ?? 0
            do {
                let channelResults = try await withTimeout(max(120, min(seconds * 0.3, 600))) {
                    try await FileTranscription.transcribe(url: url, language: original.language, terms: terms)
                }
                results += channelResults.map { (channel, shift($0, by: offset)) }
            } catch {
                Log.asr.error("Re-transcribing \(channel.rawValue) failed, keeping live text: \(error.localizedDescription)")
                results += liveResults(channel)
            }
        }
        guard !results.isEmpty else { throw RefineError.noAudio }

        // Stage 2: who spoke when. The call audio may hold several remote
        // voices; the mic is diarized too, so the app can tell on its own
        // whether it heard just you (online) or a room (in person / hybrid).
        let systemSpeech = results.filter { $0.0 == .system }.reduce(0) { $0 + max(0, $1.1.end - $1.1.start) }
        var diarization: [AudioChannel: [DiarizedSpan]] = [:]
        for channel in AudioChannel.allCases {
            let url = store.audioURL(for: original.id, channel: channel)
            let seconds = audioSeconds(url)
            guard seconds >= 3, results.contains(where: { $0.0 == channel }) else { continue }
            progress("Separating speakers…")
            // The invite bounds how many voices to expect. No +1 slack: on 1:1
            // calls it split the one remote voice into two (Parfait's finding).
            let expected = channel == .system ? others : (systemSpeech < 3 ? attendees.count : 0)
            let maxSpeakers = expected > 0 ? expected : nil
            let offset = offsets[channel.rawValue] ?? 0
            do {
                let spans = try await withTimeout(max(120, min(seconds * 0.3, 600))) {
                    try await OfflineDiarization.run(url: url, maxSpeakers: maxSpeakers)
                }
                diarization[channel] = spans.map { DiarizedSpan(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset) }
            } catch {
                Log.asr.error("Speaker separation on \(channel.rawValue) failed: \(error.localizedDescription)")
            }
        }
        let systemIntervals = results.filter { $0.0 == .system }.map { ($0.1.start, $0.1.end) }
        let micIsRoom = micHoldsSeveralVoices(diarization[.mic] ?? [], systemSpeech: systemSpeech, systemIntervals: systemIntervals)

        // Rebuild with the same turn-merging and echo rules as live.
        func build(_ input: [(AudioChannel, EngineResult)]) -> Recording {
            var results = input
            var blank = original
            blank.segments = []
            blank.speakers = []
            blank.micMode = micIsRoom ? .room : .solo
            let builder = LiveTranscript(recording: blank, myName: myName)
            builder.configure(.mic, .init(fixedSpeaker: micIsRoom ? nil : Speaker.meID, engineDiarizes: true, fallbackLabel: "In room"))
            builder.configure(.system, .init(engineDiarizes: true, fallbackLabel: "Speaker"))
            // Drop loudspeaker leak from the mic word by word (laptop speakers,
            // no headphones), so the user's own words in a mixed result survive.
            let systemWords = results.filter { $0.0 == .system }.flatMap(\.1.words)
            if !systemWords.isEmpty {
                results = results.compactMap { channel, result in
                    guard channel == .mic, !result.words.isEmpty else { return (channel, result) }
                    let kept = EchoFilter.removeLeakedWords(result.words, system: systemWords)
                    guard !kept.isEmpty else { return nil }
                    var r = result
                    r.words = kept
                    r.text = TextJoin.join(kept.map(\.text))
                    r.start = kept.first!.start
                    r.end = kept.last!.end
                    return (channel, r)
                }
            }
            for (channel, result) in results.sorted(by: { $0.1.start < $1.1.start }) {
                var labeled = result
                let spans = diarization[channel] ?? []
                labeled.words = result.words.map { word in
                    var w = word
                    w.speaker = OfflineDiarization.speaker(for: word, in: spans) ?? "0"
                    return w
                }
                if labeled.words.isEmpty {
                    labeled.speaker = OfflineDiarization.speaker(for: TimedWord(text: "", start: result.start, end: result.end), in: spans) ?? "0"
                }
                builder.apply(EngineUpdate(finals: [labeled]), channel: channel)
            }
            return builder.recording
        }
        var refined = build(results)

        if retranscribe {
            let oldLength = original.visibleSegments.reduce(0) { $0 + $1.text.count }
            let newLength = refined.visibleSegments.reduce(0) { $0 + $1.text.count }
            if oldLength > 200, newLength < oldLength / 2 { throw RefineError.worseResult }
            // A few live lines the re-transcription missed are put back
            // rather than throwing away the whole refine: on long meetings
            // one missed line used to cost every speaker and text fix.
            // Missing a large share still means the pass went wrong.
            let missing = droppedSegments(original: original, refined: refined)
            if !missing.isEmpty {
                let liveWords = original.visibleSegments.filter(\.isFinal).reduce(0) { $0 + words($1.text).count }
                let missingWords = missing.reduce(0) { $0 + words($1.text).count }
                Log.asr.notice("Refine missed \(missing.count) live line(s), \(missingWords) of \(liveWords) words")
                if Double(missingWords) > Double(liveWords) * 0.15 { throw RefineError.droppedSpeech }
                refined = build(results + missing.map { ($0.channel, result(from: $0)) })
            }
        }

        refined = SpeakerCarryOver.apply(from: original, to: refined)
        refined.refinedAt = .now
        return refined
    }

    /// Re-transcribing the whole file once lost a sentence that the live
    /// transcript had (one line of four, too little for the length check).
    /// A live line of 6+ words whose words mostly don't appear in the
    /// refined text around the same time means speech was dropped. Mic words
    /// that moved to the call audio as loudspeaker leak still count as found.
    static func dropsSpeech(original: Recording, refined: Recording) -> Bool {
        !droppedSegments(original: original, refined: refined).isEmpty
    }

    /// The live lines `dropsSpeech` counts as missing from the refined text.
    static func droppedSegments(original: Recording, refined: Recording) -> [Segment] {
        let refinedSegments = refined.visibleSegments
        return original.visibleSegments.filter { seg in
            guard seg.isFinal else { return false }
            let live = words(seg.text)
            guard live.count >= 6 else { return false }
            let nearby = Set(refinedSegments.filter { other in
                (other.channel == seg.channel || seg.channel == .mic) && other.end >= seg.start - 3 && other.start <= seg.end + 3
            }.flatMap { words($0.text) })
            return Double(live.filter(nearby.contains).count) / Double(live.count) < 0.4
        }
    }

    /// Words to compare live and refined text by. Chinese and Japanese are
    /// written without spaces, so splitting on spaces would turn a whole
    /// clause into one "word" that never matches a re-transcription exactly,
    /// and every Chinese meeting would fail the check. Each CJK character
    /// counts as its own word instead.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if isCJK(ch) {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(ch))
            } else if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }

    /// Decide from the audio itself whether the mic heard one person or a
    /// room. With no call audio, a second voice holding at least 12% of the
    /// speech (and 6 s) means people were talking around the laptop. With call
    /// audio, the mic must be clearly shared (top voice under 75%, a second
    /// over 15%) before it counts as hybrid; otherwise it is you on a call.
    /// Mic stretches that coincide with call audio are ignored: on laptop
    /// speakers the remote voices leak into the mic and would otherwise look
    /// like extra people in the room.
    static func micHoldsSeveralVoices(_ spans: [DiarizedSpan], systemSpeech: Double, systemIntervals: [(Double, Double)] = []) -> Bool {
        var bySpeaker: [String: Double] = [:]
        for s in spans {
            let length = max(0, s.end - s.start)
            guard length > 0 else { continue }
            let overlap = systemIntervals.reduce(0.0) { $0 + max(0, min($1.1, s.end) - max($1.0, s.start)) }
            if overlap / length > 0.5 { continue }
            bySpeaker[s.speaker, default: 0] += length
        }
        let total = bySpeaker.values.reduce(0, +)
        guard total > 0 else { return false }
        let shares = bySpeaker.values.map { $0 / total }.sorted(by: >)
        guard shares.count >= 2 else { return false }
        let second = bySpeaker.values.sorted(by: >)[1]
        if systemSpeech < 3 { return shares[1] >= 0.12 && second >= 6 }
        return shares[0] < 0.75 && shares[1] >= 0.15
    }

    /// True when the recording was (detected as) several people on the mic.
    static func isInPerson(_ recording: Recording) -> Bool {
        recording.micMode == .room
    }

    static func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func shift(_ result: EngineResult, by offset: Double) -> EngineResult {
        var r = result
        r.start += offset
        r.end += offset
        r.words = r.words.map { var w = $0; w.start += offset; w.end += offset; return w }
        return r
    }

    /// Existing segment back into an engine result (keeps word timings).
    static func result(from segment: Segment) -> EngineResult {
        EngineResult(start: segment.start, end: segment.end, text: segment.text,
                     words: segment.words ?? [], confidence: segment.confidence)
    }
}

nonisolated struct DiarizedSpan: Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

nonisolated enum FileTranscription {
    static func transcribe(url: URL, language: String, terms: [String]) async throws -> [EngineResult] {
        let locale = try await AppleSpeechTranscriber.resolveLocale(language == "mixed" ? "zh-CN" : language)
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        try await AppleSpeechTranscriber.ensureAssets(for: module, progress: nil)
        let analyzer = SpeechAnalyzer(modules: [module])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length >= AVAudioFramePosition(file.processingFormat.sampleRate) else { return [] }
        let collector = Task {
            var out: [EngineResult] = []
            for try await result in module.results where result.isFinal {
                let mapped = AppleSpeechTranscriber.map(result)
                if !mapped.text.trimmed.isEmpty { out.append(mapped) }
            }
            return out
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        return try await collector.value
    }
}

nonisolated enum OfflineDiarization {
    static func run(url: URL, maxSpeakers: Int?) async throws -> [DiarizedSpan] {
        var config = OfflineDiarizerConfig()
        if let maxSpeakers { config.clustering.maxSpeakers = maxSpeakers }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(url)
        return result.segments.map {
            DiarizedSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// Speaker with the largest overlap, else the nearest span. Words the
    /// diarizer left uncovered belong to whoever spoke closest in time; a
    /// separate fallback label would invent an extra speaker.
    static func speaker(for word: TimedWord, in spans: [DiarizedSpan]) -> String? {
        guard !spans.isEmpty else { return nil }
        var best: (String, Double)?
        for s in spans where s.end > word.start && s.start < word.end {
            let overlap = min(s.end, word.end) - max(s.start, word.start)
            if overlap > (best?.1 ?? 0) { best = (s.speaker, overlap) }
        }
        if let best { return best.0 }
        let mid = (word.start + word.end) / 2
        return spans.min { distance($0, mid) < distance($1, mid) }?.speaker
    }

    private static func distance(_ s: DiarizedSpan, _ t: Double) -> Double {
        t < s.start ? s.start - t : (t > s.end ? t - s.end : 0)
    }
}

/// Maps re-diarized speakers onto the speakers of the previous transcript by
/// shared speaking time, so confirmed names (and colors) survive a refine.
/// One to one: when the live diarizer heard several people as one voice,
/// only the one who did most of that talking takes over its name; the
/// others stay separate speakers instead of collapsing back into it (two
/// real team meetings went from five remote voices back to two this way).
nonisolated enum SpeakerCarryOver {
    static func apply(from old: Recording, to new: Recording) -> Recording {
        var result = new
        let oldSegments = old.visibleSegments
        var candidates: [(new: String, old: String, overlap: Double)] = []

        for speaker in new.speakers where !speaker.isMe {
            let mine = new.segments.filter { $0.speakerID == speaker.id && !$0.isEcho }
            let total = mine.reduce(0) { $0 + max(0, $1.end - $1.start) }
            guard total > 0 else { continue }
            var overlapByOld: [String: Double] = [:]
            for seg in mine {
                for o in oldSegments where o.channel == seg.channel && o.end > seg.start && o.start < seg.end {
                    overlapByOld[o.speakerID, default: 0] += min(o.end, seg.end) - max(o.start, seg.start)
                }
            }
            if let (oldID, overlap) = overlapByOld.max(by: { $0.value < $1.value }), overlap / total >= 0.5,
               old.speaker(oldID)?.isMe != true {
                candidates.append((speaker.id, oldID, overlap))
            }
        }
        var mapping: [String: String] = [:]
        for c in candidates.sorted(by: { $0.overlap > $1.overlap }) where !mapping.values.contains(c.old) {
            mapping[c.new] = c.old
        }

        // Rewrite segment speaker IDs; unmapped speakers get IDs that can't
        // collide with the old ones.
        var finalIDs: [String: String] = [:]
        for speaker in new.speakers where !speaker.isMe {
            finalIDs[speaker.id] = mapping[speaker.id] ?? speaker.id.replacingOccurrences(of: ":", with: ":r")
        }
        for i in result.segments.indices {
            if let id = finalIDs[result.segments[i].speakerID] { result.segments[i].speakerID = id }
        }

        var speakers: [Speaker] = new.speakers.filter(\.isMe).map { me in
            old.speaker(Speaker.meID).map { var s = me; s.name = $0.name; return s } ?? me
        }
        var nextColor = (old.speakers.map(\.colorIndex).max() ?? 0) + 1
        for speaker in new.speakers where !speaker.isMe {
            guard let id = finalIDs[speaker.id], !speakers.contains(where: { $0.id == id }) else { continue }
            if let previous = old.speaker(id) {
                speakers.append(previous)
            } else {
                var s = speaker
                s.id = id
                s.colorIndex = nextColor
                nextColor += 1
                let taken = Set(speakers.map(\.name) + old.speakers.map(\.name))
                if taken.contains(s.name) {
                    var n = speakers.filter { !$0.isMe }.count + 1
                    while taken.contains("Speaker \(n)") { n += 1 }
                    s.name = "Speaker \(n)"
                }
                speakers.append(s)
            }
        }
        result.speakers = speakers
        result.segments = mergeAdjacent(result.segments)
        return result
    }

    /// After remapping, neighbouring turns may now share a speaker.
    static func mergeAdjacent(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if !seg.isEcho, let i = out.lastIndex(where: { !$0.isEcho }),
               out[i].speakerID == seg.speakerID, out[i].channel == seg.channel,
               seg.start - out[i].end < 1.8, out[i].end - out[i].start < 60 {
                out[i].text = TextJoin.append(out[i].text, seg.text)
                out[i].end = max(out[i].end, seg.end)
                if let w = seg.words { out[i].words = (out[i].words ?? []) + w }
            } else {
                out.append(seg)
            }
        }
        return out
    }
}

/// Cheap naming rules from the calendar, applied after voiceprints and
/// before any LLM: one-on-one titles and elimination.
nonisolated enum CalendarRules {
    static func apply(_ recording: Recording, myName: String) -> Recording {
        var rec = fromMentions(recording)
        let used = Set(rec.speakers.filter { $0.isConfirmed || rec.speakerSources?[$0.id] != nil }.map { $0.name.lowercased() })
        let remote = rec.speakers.filter { s in !s.isMe && rec.visibleSegments.contains { $0.speakerID == s.id && $0.channel == .system } }
        let generic = remote.filter { !$0.isConfirmed && rec.speakerSources?[$0.id] == nil && isGeneric($0.name) }
        var invitees = rec.meeting.attendees.filter { !$0.isSelf }.map(\.displayName)
        if invitees.isEmpty { invitees = namesFromTitle(rec.meeting.title, excluding: myName, selfNames: rec.meeting.attendees.filter(\.isSelf).map(\.displayName)) }
        let unmatched = invitees.filter { invitee in
            !used.contains(invitee.lowercased()) && !remote.contains { $0.name.caseInsensitiveCompare(invitee) == .orderedSame }
        }

        // Elimination: as many remote voices as remote invitees and exactly
        // one of each left over, so the last voice is the last person.
        if generic.count == 1, unmatched.count == 1, remote.count == invitees.count || (remote.count == 1 && invitees.count == 1),
           let i = rec.speakers.firstIndex(where: { $0.id == generic[0].id }) {
            rec.speakers[i].name = unmatched[0]
            rec.speakers[i].email = rec.meeting.attendees.first { $0.displayName == unmatched[0] }?.email
            rec.speakers[i].isConfirmed = false
            rec.speakerSources = (rec.speakerSources ?? [:]).merging([generic[0].id: "calendar"]) { $1 }
        }
        return rec
    }

    /// Names from how people talk to each other. "I'm Grant" / "this is
    /// Grant" names the speaker; "Grant, can you…" or "…by Friday, Grant?"
    /// points at whoever answers next (and away from the one asking). Only
    /// invitees with a unique first name count; a speaker needs two such
    /// cues (or one introduction) and a clear lead over any other name.
    /// Works for remote voices and in-room voices alike; stays unconfirmed.
    static func fromMentions(_ recording: Recording) -> Recording {
        var rec = recording
        let taken = Set(rec.speakers.filter { !isGeneric($0.name) }.map { $0.name.lowercased() })
        let open = rec.meeting.attendees.filter { !$0.isSelf && !taken.contains($0.displayName.lowercased()) }
        let generic = Set(rec.speakers.filter { !$0.isMe && !$0.isConfirmed && isGeneric($0.name) }.map(\.id))
        guard !open.isEmpty, !generic.isEmpty else { return rec }
        var byFirst: [String: Attendee] = [:]
        var repeated = Set<String>()
        for person in open {
            guard let first = firstName(person.displayName) else { continue }
            if byFirst[first] != nil { repeated.insert(first) } else { byFirst[first] = person }
        }
        for first in repeated { byFirst[first] = nil }
        guard !byFirst.isEmpty else { return rec }

        let segments = rec.visibleSegments.sorted { $0.start < $1.start }
        let firsts = Array(byFirst.keys)
        var score: [String: [String: Int]] = [:]
        for (i, seg) in segments.enumerated() {
            let text = normalizingNames(seg.text, firsts)
            for (first, person) in byFirst {
                if introduces(text, first) {
                    score[seg.speakerID, default: [:]][person.displayName, default: 0] += 3
                } else if let cue = addressCue(text, first) {
                    score[seg.speakerID, default: [:]][person.displayName, default: 0] -= 2
                    let other: Segment? = cue == .next
                        ? segments[(i + 1)...].first(where: { $0.speakerID != seg.speakerID }).flatMap { $0.start - seg.end < 15 ? $0 : nil }
                        : segments[..<i].last(where: { $0.speakerID != seg.speakerID }).flatMap { seg.start - $0.end < 15 ? $0 : nil }
                    if let other { score[other.speakerID, default: [:]][person.displayName, default: 0] += 1 }
                }
            }
        }
        let ranked = score.flatMap { speaker, names in names.map { (speaker: speaker, name: $0.key, value: $0.value) } }
            .filter { generic.contains($0.speaker) && $0.value >= 2 }
            .sorted { $0.value > $1.value }
        var usedNames = Set<String>(), usedSpeakers = Set<String>()
        for c in ranked where !usedNames.contains(c.name) && !usedSpeakers.contains(c.speaker) {
            let runnerUp = score[c.speaker]?.filter { $0.key != c.name }.map(\.value).max() ?? 0
            guard c.value - runnerUp >= 1, let i = rec.speakers.firstIndex(where: { $0.id == c.speaker }) else { continue }
            rec.speakers[i].name = c.name
            rec.speakers[i].email = rec.meeting.attendees.first { $0.displayName == c.name }?.email
            rec.speakers[i].isConfirmed = false
            rec.speakerSources = (rec.speakerSources ?? [:]).merging([c.speaker: "mention"]) { $1 }
            usedNames.insert(c.name)
            usedSpeakers.insert(c.speaker)
        }
        return rec
    }

    /// Speech recognition often gets a name nearly right ("Grand" for
    /// "Grant"): a capitalized word one letter away from exactly one
    /// invitee's first name (5+ letters) is read as that name.
    static func normalizingNames(_ text: String, _ firsts: [String]) -> String {
        var out = text
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for word in words where word.first?.isUppercase == true && !firsts.contains(word) {
            let close = firsts.filter { $0.count >= 5 && $0.first == word.first && abs($0.count - word.count) <= 1 && editDistance($0, word) <= 1 }
            guard close.count == 1 else { continue }
            out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", with: close[0], options: .regularExpression)
        }
        return out
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// "Grant Ellis" -> "Grant"; handles and emails ("oliverxzy179") give nil.
    static func firstName(_ displayName: String) -> String? {
        guard let first = displayName.split(separator: " ").first.map(String.init), first.count >= 2,
              first.allSatisfy(\.isLetter), first.first?.isUppercase == true else { return nil }
        return first
    }

    static func introduces(_ text: String, _ first: String) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: first)
        return matches(text, "(?i:\\b(?:i['’]m|i am|this is|my name is)\\s+)\(name)\\b(?!['’]s)")
            || matches(text, "^\\s*(?i:(?:hi|hey|hello)[,!.]?\\s+)?\(name)\\s+(?i:here)\\b")
    }

    enum AddressCue { case next, previous }

    /// Who a name in this line is spoken to: "Grant, can you…" and "…by
    /// Friday, Grant?" go to the next speaker; "Thanks, Grant" follows
    /// Grant's turn, so it points at the previous one.
    static func addressCue(_ text: String, _ first: String) -> AddressCue? {
        let name = NSRegularExpression.escapedPattern(for: first)
        if matches(text, "(?i:\\b(?:thanks|thank you)[,!.]?\\s+)\(name)\\b(?!['’]s)") { return .previous }
        let lead = "(?i:(?:hi|hey|hello|ok|okay|so|and|great|sure|yes|yeah|right|well)[,!.]?\\s+)?"
        if matches(text, "(?:^|[.!?;]\\s+)\\s*\(lead)\(name)\\s*[,?!]") || matches(text, "[,.!?;]\\s*\(name)\\s*\\?+\\s*$") { return .next }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isGeneric(_ name: String) -> Bool {
        name.hasPrefix("Speaker ") || name.hasPrefix("In room ") || name == "Unknown"
    }

    /// "1:1 Oliver & Hsiao", "Oliver x Hsiao", "Oliver / Hsiao", "1on1 with Hsiao".
    static func namesFromTitle(_ title: String, excluding myName: String, selfNames: [String]) -> [String] {
        var t = title
        for noise in ["1:1", "1-1", "1on1", "1 on 1", "one on one", "sync", "weekly", "wkly", "bi", "catch up", "catchup", "|", "｜", ":"] {
            t = t.replacingOccurrences(of: noise, with: " ", options: .caseInsensitive)
        }
        let mine = Set(([myName] + selfNames).flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        if let range = t.range(of: "with ", options: .caseInsensitive) {
            let name = String(t[range.upperBound...]).trimmed
            return name.isEmpty || mine.contains(name.lowercased()) ? [] : [name]
        }
        let parts = t.components(separatedBy: CharacterSet(charactersIn: "&/<>+,")).flatMap { $0.components(separatedBy: " x ") }
            .map { $0.trimmed }.filter { !$0.isEmpty }
        guard parts.count >= 2, parts.count <= 3 else { return [] }
        let others = parts.filter { p in !mine.contains(p.lowercased()) && !p.lowercased().split(separator: " ").contains { mine.contains(String($0)) } }
        return others.count == 1 ? others : []
    }
}
