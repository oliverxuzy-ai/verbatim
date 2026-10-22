import AVFAudio
import FluidAudio
import Foundation
import Testing
@testable import Verbatim

/// Speaker attribution on real AMI meetings (single far-field mic, four
/// speakers, overlaps). Skipped unless Bench/ami/*.wav exist (see Bench/README.md).
/// Score: duration-weighted share of single-speaker reference speech whose
/// predicted speaker maps (one-to-one, best assignment) to the true speaker.
nonisolated struct DiarizationBenchmarkTests {
    /// Outside ~/Desktop so unattended runs never hit a folder-access prompt.
    static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VerbatimBench/ami")
    static let meetings = ["ES2004a", "IS1009a"]
    static var available: Bool {
        meetings.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).Array1-01.wav").path) }
    }

    struct Ref { let start: Double; let end: Double; let speaker: String }

    static func reference(_ meeting: String) -> [Ref] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("\(meeting).rttm"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 8, let s = Double(f[3]), let d = Double(f[4]) else { return nil }
            return Ref(start: s, end: s + d, speaker: String(f[7]))
        }
    }

    static func score(_ ref: [Ref], duration: Double, step: Double = 0.05, hyp: (Double) -> String?) -> (accuracy: Double, missed: Double, clusters: Int) {
        var confusion: [String: [String: Double]] = [:]
        var total = 0.0, missed = 0.0
        var clusters = Set<String>()
        var t = 0.0
        while t < duration {
            let active = ref.filter { $0.start <= t && t < $0.end }
            if active.count == 1 {
                total += step
                if let p = hyp(t) {
                    confusion[active[0].speaker, default: [:]][p, default: 0] += step
                    clusters.insert(p)
                } else {
                    missed += step
                }
            }
            t += step
        }
        // Greedy one-to-one assignment by largest shared time.
        var pairs = confusion.flatMap { r, preds in preds.map { (r, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        var usedR = Set<String>(), usedP = Set<String>()
        var matched = 0.0
        while let (r, p, v) = pairs.first {
            pairs.removeFirst()
            guard !usedR.contains(r), !usedP.contains(p) else { continue }
            usedR.insert(r); usedP.insert(p); matched += v
        }
        return (matched / max(total, 1e-9), missed / max(total, 1e-9), clusters.count)
    }

    static func streaming(_ url: URL, model: LSEENDVariant) async throws -> LiveDiarizer {
        let d = LiveDiarizer(variant: .call, model: model)
        try await d.prepare()
        let file = try AVAudioFile(forReading: url)
        let converter = StreamConverter(to: AudioFormats.mono16k)
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000) else { break }
            try? file.read(into: buf, frameCount: 16000)
            guard buf.frameLength > 0, let mono = buf.monoFloat(.firstChannel), let n = converter.convert(mono) else { break }
            d.feed(n)
        }
        await d.finish()
        return d
    }

    static func offline(_ url: URL, numSpeakers: Int?) async throws -> [DiarizedSpan] {
        var config = OfflineDiarizerConfig()
        config.clustering.numSpeakers = numSpeakers
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        return try await manager.process(url).segments.map {
            DiarizedSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    @Test(.enabled(if: available), .timeLimit(.minutes(30)), arguments: meetings)
    func compareDiarizers(meeting: String) async throws {
        let url = Self.dir.appendingPathComponent("\(meeting).Array1-01.wav")
        let ref = Self.reference(meeting)
        let duration = (ref.map(\.end).max() ?? 0) + 1
        var rows: [String] = []
        func row(_ name: String, _ r: (accuracy: Double, missed: Double, clusters: Int), _ secs: Double) {
            rows.append(String(format: "%@ | %@ | acc %5.1f%% | missed %4.1f%% | %d spk | %.0fs", meeting, name.padding(toLength: 30, withPad: " ", startingAt: 0), r.accuracy * 100, r.missed * 100, r.clusters, secs))
        }
        for model in [LSEENDVariant.dihard3, .ami] {
            let t0 = Date()
            let d = try await Self.streaming(url, model: model)
            row("live LS-EEND \(model)", Self.score(ref, duration: duration) { t in d.speaker(from: t, to: t + 0.05).map(String.init) }, Date().timeIntervalSince(t0))
        }
        for n in [nil, 4] as [Int?] {
            let t0 = Date()
            let spans = try await Self.offline(url, numSpeakers: n)
            row("offline pyannote \(n.map { "n=\($0)" } ?? "auto")", Self.score(ref, duration: duration) { t in
                OfflineDiarization.speaker(for: TimedWord(text: "", start: t, end: t + 0.05), in: spans)
            }, Date().timeIntervalSince(t0))
        }
        print("BENCH\n" + rows.joined(separator: "\n"))
    }
}
