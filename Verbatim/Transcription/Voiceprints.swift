import AVFAudio
import FluidAudio
import Foundation

/// A person's voice, learned from speakers the user confirmed in earlier
/// meetings. Matching new speakers against these turns "Speaker 2" into
/// "Hsiao-Wen Lin" automatically next time.
nonisolated struct Voiceprint: Codable, Sendable, Identifiable {
    var id: String            // email when known, otherwise the lowercased name
    var name: String
    var email: String?
    /// L2-normalized CAM++ embeddings, newest last (bounded).
    var embeddings: [[Float]]
    /// A clean 4–10 s clip for cloud APIs that accept reference audio.
    var clipFile: String?
    /// Embedding model the vectors came from; others are ignored.
    var backend: String = VoiceEmbedding.backend.rawValue
    var updatedAt: Date

    static func key(name: String, email: String?) -> String {
        if let email, !email.isEmpty { return email.lowercased() }
        return name.lowercased().trimmed
    }
}

/// Loads embedding models lazily and extracts speaker embeddings from audio.
nonisolated enum VoiceEmbedding {
    enum Backend: String, Sendable, CaseIterable {
        /// WeSpeaker ResNet (256-d), the model pyannote clusters with.
        case wespeaker
        /// CAM++ (192-d, beta conversion in FluidAudio).
        case campplus
    }

    /// Voiceprints are stored per backend; never compare across backends.
    static let backend: Backend = .wespeaker

    private static let campplus = Locked<CampPlusEmbedder?>(nil)
    private static let wespeaker = Locked<DiarizerManager?>(nil)

    static func embedder() async throws -> CampPlusEmbedder {
        if let e = campplus.current { return e }
        let e = try await CampPlusEmbedder.load()
        campplus.withLock { $0 = e }
        return e
    }

    static func wespeakerManager() async throws -> DiarizerManager {
        if let m = wespeaker.current { return m }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager()
        m.initialize(models: models)
        wespeaker.withLock { $0 = m }
        return m
    }

    /// One embedding for a single-speaker clip. WeSpeaker takes a fixed 10 s
    /// window, so longer clips are embedded in 10 s pieces and averaged.
    static func embed(_ audio: [Float], backend: Backend = backend) async throws -> [Float] {
        switch backend {
        case .campplus:
            return try await embedder().embed(audio: audio)
        case .wespeaker:
            let manager = try await wespeakerManager()
            var vectors: [[Float]] = []
            var start = 0
            while start < audio.count {
                let end = min(audio.count, start + 160_000)
                if end - start >= 32_000 || vectors.isEmpty {
                    vectors.append(try manager.extractSpeakerEmbedding(from: Array(audio[start..<end])))
                }
                start = end
            }
            return average(vectors) ?? []
        }
    }

    /// Reads [start, end) of a 16 kHz mono file as Float samples.
    static func samples(url: URL, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let from = AVAudioFramePosition(max(0, start) * sr)
        let count = AVAudioFrameCount(max(0, min(end, Double(file.length) / sr) - max(0, start)) * sr)
        guard count > 0, from < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = from
        try file.read(into: buffer, frameCount: count)
        guard let mono = buffer.monoFloat(.firstChannel) else { return [] }
        let normalized = sr == 16_000 ? mono : (StreamConverter(to: AudioFormats.mono16k).convert(mono) ?? mono)
        guard let data = normalized.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(normalized.frameLength)))
    }

    /// Mean of per-span embeddings, re-normalized.
    static func embedding(url: URL, spans: [(Double, Double)], backend: Backend = backend) async throws -> [Float]? {
        var vectors: [[Float]] = []
        for (s, e) in spans {
            let audio = try samples(url: url, start: s, end: e)
            guard audio.count >= 16_000 * 2 else { continue }
            vectors.append(try await embed(audio, backend: backend))
        }
        return average(vectors)
    }

    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in sum.indices where i < v.count { sum[i] += v[i] } }
        let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return sum.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Clean spans for one speaker: their own segments, 2.5–12 s long, not
    /// overlapping anyone else (±0.3 s), longest first. `channel` limits them
    /// to one channel.
    static func cleanSpans(for speakerID: String, in recording: Recording, channel: AudioChannel? = nil, limit: Int = 4) -> [(AudioChannel, Double, Double)] {
        let all = recording.visibleSegments
        let mine = all.filter { $0.speakerID == speakerID && $0.end - $0.start >= 2.5 && (channel == nil || $0.channel == channel) }
        let clean = mine.filter { seg in
            !all.contains { $0.speakerID != speakerID && $0.channel == seg.channel && $0.end > seg.start - 0.3 && $0.start < seg.end + 0.3 }
        }
        return (clean.isEmpty ? mine : clean)
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            .prefix(limit)
            .map { ($0.channel, $0.start, min($0.end, $0.start + 12)) }
    }
}

/// Persistent voiceprint library in Application Support.
@Observable
final class VoiceprintStore {
    private(set) var voiceprints: [Voiceprint] = []
    private let folder: URL

    /// WeSpeaker cosine thresholds calibrated on real AMI far-field speakers
    /// (VoiceprintCalibrationTests): different people peaked at 0.39, the
    /// same person had a median of 0.68. At 0.50 nothing was misnamed and
    /// every stranger was rejected; 0.40 to 0.50 is shown as a suggestion.
    nonisolated static let meID = "me"
    nonisolated static let autoThreshold: Float = 0.50
    nonisolated static let suggestThreshold: Float = 0.40
    nonisolated static let margin: Float = 0.08

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbatim/Voiceprints", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder.appendingPathComponent("clips"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.folder.appendingPathComponent("voiceprints.json")),
           let list = try? RecordingStore.decoder.decode([Voiceprint].self, from: data) {
            voiceprints = list
        }
    }

    func clipURL(_ vp: Voiceprint) -> URL? {
        vp.clipFile.map { folder.appendingPathComponent("clips").appendingPathComponent($0) }
    }

    func voiceprint(name: String, email: String?) -> Voiceprint? {
        let key = Voiceprint.key(name: name, email: email)
        return voiceprints.first { $0.id == key } ?? voiceprints.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Learn (or refine) a person's voice from a confirmed speaker.
    func learn(speaker: Speaker, in recording: Recording, store: RecordingStore, id: String? = nil, displayName: String? = nil) async {
        guard !speaker.name.trimmed.isEmpty, !speaker.name.hasPrefix("Speaker "), !speaker.name.hasPrefix("In room ") else { return }
        let key = id ?? Voiceprint.key(name: speaker.name, email: speaker.email)
        // Your own voice is learned from your mic only: refine can now give
        // you lines from the call audio (a room system sending you back),
        // and codec-degraded call audio blurred the voiceprint.
        let spans = VoiceEmbedding.cleanSpans(for: speaker.id, in: recording, channel: key == Self.meID ? .mic : nil)
        guard let channel = spans.first?.0 else { return }
        let url = store.audioURL(for: recording.id, channel: channel)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let offset = recording.channelOffsets?[channel.rawValue] ?? 0
        let fileSpans = spans.filter { $0.0 == channel }.map { ($0.1 - offset, $0.2 - offset) }
        guard let vector = try? await VoiceEmbedding.embedding(url: url, spans: fileSpans) else { return }

        let name = displayName ?? speaker.name
        var vp = voiceprints.first { $0.id == key } ?? Voiceprint(id: key, name: name, email: speaker.email, embeddings: [], updatedAt: .now)
        if vp.backend != VoiceEmbedding.backend.rawValue {
            vp.embeddings = []
            vp.backend = VoiceEmbedding.backend.rawValue
        }
        vp.name = name
        vp.email = speaker.email ?? vp.email
        vp.embeddings = Array((vp.embeddings + [vector]).suffix(8))
        vp.updatedAt = .now
        if let best = fileSpans.first, let audio = try? VoiceEmbedding.samples(url: url, start: best.0, end: min(best.1, best.0 + 10)) {
            let file = "\(abs(key.hashValue)).wav"
            if writeWAV(audio, to: folder.appendingPathComponent("clips").appendingPathComponent(file)) { vp.clipFile = file }
        }
        voiceprints.removeAll { $0.id == key }
        voiceprints.append(vp)
        save()
    }

    func forget(_ id: String) {
        voiceprints.removeAll { $0.id == id }
        save()
    }

    nonisolated struct Match: Sendable {
        let speakerID: String
        let voiceprintID: String
        let name: String
        let email: String?
        let score: Float
        /// High-confidence matches are applied as confirmed; the rest are
        /// filled in as suggestions the user can accept.
        var isConfident: Bool { score >= VoiceprintStore.autoThreshold }
    }

    /// Match unconfirmed speakers of a recording to known voices. Candidates
    /// are limited to the meeting's attendees when the invite lists people
    /// we have voiceprints for; each person is used at most once.
    func identify(_ recording: Recording, store: RecordingStore) async -> [Match] {
        let usable = voiceprints.filter { $0.backend == VoiceEmbedding.backend.rawValue && !$0.embeddings.isEmpty }
        guard !usable.isEmpty else { return [] }
        let attendeeKeys = Set(recording.meeting.attendees.map { Voiceprint.key(name: $0.displayName, email: $0.email) })
        // Only people on this meeting's invite are candidates: matching
        // against everyone you ever met invites false names for strangers.
        // Someone already confirmed as one speaker here can't be another.
        let confirmed = Set(recording.speakers.filter(\.isConfirmed).map { Voiceprint.key(name: $0.name, email: $0.email) })
        var candidates = usable.filter { attendeeKeys.contains($0.id) && $0.id != Self.meID && !confirmed.contains($0.id) }
        // Your own voice is a candidate whenever nobody is marked as you yet.
        if !recording.speakers.contains(where: \.isMe), let me = usable.first(where: { $0.id == Self.meID }) {
            candidates.append(me)
        }
        guard !candidates.isEmpty else { return [] }

        var scored: [(speaker: String, vp: Voiceprint, score: Float, runnerUp: Float)] = []
        for speaker in recording.speakers where !speaker.isConfirmed && !speaker.isMe {
            let spans = VoiceEmbedding.cleanSpans(for: speaker.id, in: recording)
            guard let channel = spans.first?.0 else { continue }
            let offset = recording.channelOffsets?[channel.rawValue] ?? 0
            let url = store.audioURL(for: recording.id, channel: channel)
            guard let vector = try? await VoiceEmbedding.embedding(url: url, spans: spans.filter { $0.0 == channel }.map { ($0.1 - offset, $0.2 - offset) }) else { continue }
            let ranked = candidates.map { vp in (vp, vp.embeddings.map { VoiceEmbedding.cosine(vector, $0) }.max() ?? -1) }
                .sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { continue }
            scored.append((speaker.id, best.0, best.1, ranked.dropFirst().first?.1 ?? -1))
        }
        var used = Set<String>(), assigned = Set<String>()
        var matches: [Match] = []
        for s in scored.sorted(by: { $0.score > $1.score }) {
            guard s.score >= Self.suggestThreshold, s.score - s.runnerUp >= Self.margin,
                  !used.contains(s.vp.id), !assigned.contains(s.speaker) else { continue }
            used.insert(s.vp.id)
            assigned.insert(s.speaker)
            matches.append(Match(speakerID: s.speaker, voiceprintID: s.vp.id, name: s.vp.name, email: s.vp.email, score: s.score))
        }
        return matches
    }

    private func save() {
        guard let data = try? RecordingStore.encoder.encode(voiceprints) else { return }
        try? data.write(to: folder.appendingPathComponent("voiceprints.json"), options: .atomic)
    }

    private func writeWAV(_ samples: [Float], to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16],
                                          commonFormat: .pcmFormatFloat32, interleaved: false) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        return (try? file.write(from: buffer)) != nil
    }
}
