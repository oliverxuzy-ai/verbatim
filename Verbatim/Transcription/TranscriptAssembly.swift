import Foundation

/// Detects mic segments that are really the loudspeaker leaking into the
/// microphone: same words, at the same time, as the system channel.
nonisolated enum EchoFilter {
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text.lowercased() {
            if ch.isCJKIdeograph {
                if !word.isEmpty { out.append(word); word = "" }
                out.append(String(ch))
            } else if ch.isLetter || ch.isNumber || ch == "'" {
                word.append(ch)
            } else if !word.isEmpty {
                out.append(word)
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// Fraction of the mic tokens found in overlapping system text.
    static func overlapRatio(mic: String, system: [String]) -> Double {
        let micTokens = tokens(mic)
        guard !micTokens.isEmpty else { return 0 }
        var pool: [String: Int] = [:]
        for s in system { for t in tokens(s) { pool[t, default: 0] += 1 } }
        var hits = 0
        for t in micTokens where (pool[t] ?? 0) > 0 {
            hits += 1
            pool[t]! -= 1
        }
        return Double(hits) / Double(micTokens.count)
    }

    static func isEcho(micText: String, micStart: Double, micEnd: Double, system: [Segment]) -> Bool {
        let count = tokens(micText).count
        guard count >= 2 else { return false }
        let window = 2.0
        let overlapping = system.filter { $0.start <= micEnd + window && $0.end >= micStart - window }
        guard !overlapping.isEmpty else { return false }
        let ratio = overlapRatio(mic: micText, system: overlapping.map(\.text))
        return count >= 3 ? ratio >= 0.6 : ratio >= 0.99
    }
}

extension EchoFilter {
    /// Word-level leak removal for mic words, given the call audio's words in
    /// the same timeline. Runs of two or more mic words that the call audio
    /// said within 1.5 s are dropped, as are single words heard within 0.6 s
    /// (loudspeaker latency plus room delay). The user's own words in the
    /// same sentence survive, unlike whole-segment echo flags.
    static func removeLeakedWords(_ words: [TimedWord], system: [TimedWord]) -> [TimedWord] {
        guard !words.isEmpty, !system.isEmpty else { return words }
        let systemTokens = system.flatMap { w in tokens(w.text).map { ($0, (w.start + w.end) / 2) } }
        func matchDelta(_ w: TimedWord) -> Double? {
            let mid = (w.start + w.end) / 2
            let toks = tokens(w.text)
            guard !toks.isEmpty else { return nil }
            var best: Double?
            for t in toks {
                for (s, time) in systemTokens where s == t {
                    let d = abs(time - mid)
                    if d <= 1.5, d < (best ?? .infinity) { best = d }
                }
            }
            return best
        }
        let deltas = words.map(matchDelta)
        var drop = [Bool](repeating: false, count: words.count)
        var i = 0
        while i < words.count {
            guard deltas[i] != nil else { i += 1; continue }
            var j = i
            while j + 1 < words.count, deltas[j + 1] != nil { j += 1 }
            let run = i...j
            if run.count >= 2 || (deltas[i] ?? .infinity) <= 0.6 {
                for k in run { drop[k] = true }
            }
            i = j + 1
        }
        return zip(words, drop).filter { !$0.1 }.map(\.0)
    }
}

extension Character {
    nonisolated var isCJKIdeograph: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}

/// Splits engine results into speaker turns and joins text pieces.
nonisolated enum TextJoin {
    /// Joins word pieces. Engines emit pieces with their own leading spaces
    /// (Soniox, Apple runs); CJK pieces join without spaces.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for p in pieces {
            if out.isEmpty { out = p.trimmed.isEmpty ? "" : String(p.drop(while: { $0 == " " })); continue }
            out += p
        }
        return out.trimmed
    }

    /// Append `next` to `text` with a space unless either side is CJK or
    /// `next` starts with punctuation.
    static func append(_ text: String, _ next: String) -> String {
        let n = next.trimmed
        guard !n.isEmpty else { return text }
        guard let last = text.last else { return n }
        let first = n.first!
        let noSpace = last.isCJKIdeograph || first.isCJKIdeograph || ",.!?;:)，。！？；：、）".contains(first)
            || last.isCJKPunctuation
        return text + (noSpace ? "" : " ") + n
    }
}

extension Character {
    nonisolated var isCJKPunctuation: Bool { "，。！？；：、（）「」《》".contains(self) }
}

/// A word-timed span with a resolved speaker, ready to become a segment.
nonisolated struct SpeakerSpan: Sendable, Hashable {
    var speakerKey: String
    var start: Double
    var end: Double
    var text: String
    var confidence: Double?
    /// Words with recording-time offsets applied.
    var words: [TimedWord] = []
}

nonisolated enum SpanBuilder {
    /// Group a result's words by speaker into contiguous spans.
    /// `speakerFor` maps a word's time range to a speaker key.
    static func spans(for result: EngineResult, offset: Double, speakerFor: (TimedWord) -> String) -> [SpeakerSpan] {
        guard !result.words.isEmpty else {
            return [SpeakerSpan(
                speakerKey: speakerFor(TimedWord(text: result.text, start: result.start, end: result.end, speaker: result.speaker)),
                start: result.start + offset, end: result.end + offset,
                text: result.text.trimmed, confidence: result.confidence
            )]
        }
        var spans: [SpeakerSpan] = []
        var pieces: [String] = []
        var current: SpeakerSpan?
        for word in result.words {
            let key = speakerFor(word)
            var shifted = word
            shifted.start += offset
            shifted.end += offset
            shifted.speaker = nil
            if var c = current, c.speakerKey == key {
                pieces.append(word.text)
                c.end = word.end + offset
                c.words.append(shifted)
                current = c
            } else {
                if var c = current {
                    c.text = TextJoin.join(pieces)
                    spans.append(c)
                }
                pieces = [word.text]
                current = SpeakerSpan(speakerKey: key, start: word.start + offset, end: word.end + offset, text: "",
                                      confidence: result.confidence, words: [shifted])
            }
        }
        if var c = current {
            c.text = TextJoin.join(pieces)
            spans.append(c)
        }
        // Apple's runs can omit punctuation-only pieces from timing; if the
        // whole result is a single speaker prefer the engine's full text.
        if spans.count == 1 { spans[0].text = result.text.trimmed }
        return spans.filter { !$0.text.isEmpty }
    }
}
