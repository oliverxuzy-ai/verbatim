import Foundation
import Observation

/// Builds the transcript while recording: turns engine results into speaker
/// segments, keeps one volatile line per channel, resolves speakers from the
/// diarizer when its decisions catch up, and flags speaker echo on the mic.
@Observable
final class LiveTranscript {
    var recording: Recording
    private(set) var volatile: [AudioChannel: Segment] = [:]

    /// Per-channel speaker strategy, set up by the session.
    struct ChannelConfig {
        var offset: Double = 0
        var fixedSpeaker: String?
        var engineDiarizes = false
        var diarizer: LiveDiarizer?
        var fallbackLabel: String
    }

    private var configs: [AudioChannel: ChannelConfig] = [:]
    private var pending: [(channel: AudioChannel, result: EngineResult, receivedAt: Date)] = []
    private let myName: String

    init(recording: Recording, myName: String) {
        self.recording = recording
        self.myName = myName
    }

    func configure(_ channel: AudioChannel, _ config: ChannelConfig) {
        configs[channel] = config
    }

    func setOffset(_ channel: AudioChannel, _ offset: Double) {
        configs[channel]?.offset = offset
    }

    var offsets: [String: Double] {
        Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value.offset) })
    }

    // MARK: Applying engine output

    func apply(_ update: EngineUpdate, channel: AudioChannel) {
        guard let config = configs[channel] else { return }
        for result in update.finals {
            if let d = config.diarizer, config.fixedSpeaker == nil, !config.engineDiarizes,
               d.coveredUntil < result.end - 0.05 {
                pending.append((channel, result, .now))
            } else {
                commit(result, channel: channel)
            }
        }
        if let v = update.volatile, !v.text.trimmed.isEmpty {
            let key = config.fixedSpeaker ?? lastSpeaker(on: channel) ?? speakerKey(channel, label: config.engineDiarizes ? v.speaker : nil)
            ensureSpeaker(key, channel: channel)
            volatile[channel] = Segment(
                channel: channel, speakerID: key,
                start: v.start + config.offset, end: v.end + config.offset,
                text: v.text.trimmed, isFinal: false
            )
        } else {
            volatile[channel] = nil
        }
        // Pending text is still shown as volatile so nothing seems lost.
        if volatile[channel] == nil, let p = pending.last(where: { $0.channel == channel }) {
            volatile[channel] = Segment(channel: channel, speakerID: lastSpeaker(on: channel) ?? speakerKey(channel, label: nil),
                                        start: p.result.start + config.offset, end: p.result.end + config.offset,
                                        text: p.result.text.trimmed, isFinal: false)
        }
    }

    /// Commit results whose speaker decisions are now available (or that
    /// waited long enough).
    func resolvePending(force: Bool = false) {
        guard !pending.isEmpty else { return }
        var remaining: [(channel: AudioChannel, result: EngineResult, receivedAt: Date)] = []
        for item in pending {
            let covered = configs[item.channel]?.diarizer?.coveredUntil ?? .infinity
            if force || covered >= item.result.end - 0.05 || Date.now.timeIntervalSince(item.receivedAt) > 6 {
                commit(item.result, channel: item.channel)
            } else {
                remaining.append(item)
            }
        }
        pending = remaining
    }

    func finalizeLive() {
        resolvePending(force: true)
        volatile = [:]
    }

    private func commit(_ incoming: EngineResult, channel: AudioChannel) {
        guard let config = configs[channel] else { return }
        var result = incoming
        if channel == .mic, !result.words.isEmpty {
            let systemWords = recording.segments.filter { $0.channel == .system }.flatMap { $0.words ?? [] }
            let shifted = result.words.map { w -> TimedWord in var x = w; x.start += config.offset; x.end += config.offset; return x }
            let kept = EchoFilter.removeLeakedWords(shifted, system: systemWords)
            guard !kept.isEmpty else { return }
            if kept.count < shifted.count {
                result.words = kept.map { w -> TimedWord in var x = w; x.start -= config.offset; x.end -= config.offset; return x }
                result.text = TextJoin.join(result.words.map(\.text))
            }
        }
        let spans = SpanBuilder.spans(for: result, offset: config.offset) { word in
            if let fixed = config.fixedSpeaker { return fixed }
            if config.engineDiarizes { return speakerKey(channel, label: word.speaker ?? result.speaker) }
            if let d = config.diarizer, let idx = d.speaker(from: word.start, to: word.end) {
                return speakerKey(channel, label: String(idx))
            }
            return lastSpeaker(on: channel) ?? speakerKey(channel, label: nil)
        }
        for span in spans { add(span, channel: channel) }
        if channel == .system { recheckEcho(around: spans) }
    }

    private func add(_ span: SpeakerSpan, channel: AudioChannel) {
        ensureSpeaker(span.speakerKey, channel: channel)
        var isEcho = false
        if channel == .mic {
            let system = recording.segments.filter { $0.channel == .system && !$0.isEcho }
            isEcho = EchoFilter.isEcho(micText: span.text, micStart: span.start, micEnd: span.end, system: system)
        }
        // Merge into the previous turn of the same speaker when nobody else
        // spoke in between and the pause was short.
        if !isEcho, let i = recording.segments.lastIndex(where: { $0.channel == channel && !$0.isEcho }) {
            let last = recording.segments[i]
            let interrupted = recording.segments.contains {
                !$0.isEcho && $0.speakerID != last.speakerID && $0.start > last.start && $0.start < span.start
            }
            if last.speakerID == span.speakerKey, !interrupted, span.start - last.end < 1.8, last.end - last.start < 60 {
                recording.segments[i].text = TextJoin.append(last.text, span.text)
                recording.segments[i].end = max(last.end, span.end)
                if !span.words.isEmpty { recording.segments[i].words = (last.words ?? []) + span.words }
                return
            }
        }
        recording.segments.append(Segment(
            channel: channel, speakerID: span.speakerKey,
            start: span.start, end: span.end, text: span.text,
            isFinal: true, confidence: span.confidence, isEcho: isEcho,
            words: span.words.isEmpty ? nil : span.words
        ))
    }

    private func recheckEcho(around spans: [SpeakerSpan]) {
        guard let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max() else { return }
        let system = recording.segments.filter { $0.channel == .system && !$0.isEcho }
        for i in recording.segments.indices where recording.segments[i].channel == .mic && !recording.segments[i].isEcho {
            let s = recording.segments[i]
            guard s.end >= lo - 3, s.start <= hi + 3 else { continue }
            if EchoFilter.isEcho(micText: s.text, micStart: s.start, micEnd: s.end, system: system) {
                recording.segments[i].isEcho = true
            }
        }
    }

    // MARK: Speakers

    func speakerKey(_ channel: AudioChannel, label: String?) -> String {
        if channel == .mic, configs[.mic]?.fixedSpeaker != nil { return Speaker.meID }
        return "\(channel.rawValue):\(label ?? "0")"
    }

    private func lastSpeaker(on channel: AudioChannel) -> String? {
        recording.segments.last { $0.channel == channel && !$0.isEcho }?.speakerID
    }

    func ensureSpeaker(_ key: String, channel: AudioChannel) {
        guard recording.speaker(key) == nil else { return }
        let index = 1 + recording.speakers.filter { !$0.isMe }.count
        if key == Speaker.meID {
            recording.speakers.append(Speaker(id: key, name: myName, colorIndex: 0, isMe: true, isConfirmed: true))
            return
        }
        let sameChannel = recording.speakers.filter { $0.id.hasPrefix(channel.rawValue + ":") }.count
        let base = configs[channel]?.fallbackLabel ?? "Speaker"
        var speaker = Speaker(id: key, name: "\(base) \(sameChannel + 1)", colorIndex: index)

        // 1:1 meeting: the only remote voice is almost certainly the one
        // other attendee. Suggest it; the user confirms later.
        if channel == .system, sameChannel == 0 {
            let others = recording.meeting.attendees.filter { !$0.isSelf }
            if others.count == 1 {
                speaker.name = others[0].displayName
                speaker.email = others[0].email
            }
        }
        recording.speakers.append(speaker)
    }

    /// Lines for the live panel: committed segments plus volatile tails.
    func tail(_ count: Int) -> [Segment] {
        let committed = recording.segments.filter { !$0.isEcho }.suffix(count + 2)
        let all = (Array(committed) + volatile.values).sorted { $0.start < $1.start }
        return Array(all.suffix(count))
    }
}
