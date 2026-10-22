import Foundation
import Testing
@testable import Verbatim

/// Calibrates voiceprint matching on eight real AMI speakers: enroll from the
/// first half of each meeting, identify clean turns from the second half, and
/// treat the other meeting's people as strangers who must be rejected.
nonisolated struct VoiceprintCalibrationTests {
    typealias Ref = DiarizationBenchmarkTests.Ref

    /// Turns of 2 to 12 s with no other speaker inside them.
    static func cleanTurns(_ ref: [Ref]) -> [Ref] {
        ref.filter { r in
            let d = r.end - r.start
            let overlap = ref.filter { $0.speaker != r.speaker && $0.end > r.start && $0.start < r.end }
                .reduce(0.0) { $0 + min($1.end, r.end) - max($1.start, r.start) }
            return d >= 2 && d <= 15 && overlap < 0.15 * d
        }
    }

    @Test(.enabled(if: DiarizationBenchmarkTests.available), .timeLimit(.minutes(20)), arguments: VoiceEmbedding.Backend.allCases)
    func calibrateThreshold(backend: VoiceEmbedding.Backend) async throws {
        var prints: [String: [Float]] = [:]
        var probes: [(speaker: String, vector: [Float])] = []
        for meeting in DiarizationBenchmarkTests.meetings {
            let url = DiarizationBenchmarkTests.dir.appendingPathComponent("\(meeting).Array1-01.wav")
            let ref = DiarizationBenchmarkTests.reference(meeting)
            let half = (ref.map(\.end).max() ?? 0) / 2
            let turns = Self.cleanTurns(ref)
            for speaker in Set(ref.map(\.speaker)) {
                let enroll = turns.filter { $0.speaker == speaker && $0.end < half }
                    .sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(3)
                if let v = try await VoiceEmbedding.embedding(url: url, spans: enroll.map { ($0.start, $0.end) }, backend: backend) {
                    prints[speaker] = v
                }
                // Cluster-level probe, as the app does it: the speaker's four
                // longest clean turns from the second half, averaged.
                let later = turns.filter { $0.speaker == speaker && $0.start > half }
                    .sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(4)
                if let v = try await VoiceEmbedding.embedding(url: url, spans: later.map { ($0.start, $0.end) }, backend: backend) {
                    probes.append((speaker, v))
                }
            }
        }
        var same: [Float] = [], different: [Float] = []
        var top1 = 0
        var accepted: [Float: (correct: Int, wrong: Int, rejectedOK: Int)] = [:]
        let thresholds: [Float] = [0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75]
        for probe in probes {
            let ranked = prints.map { ($0.key, VoiceEmbedding.cosine(probe.vector, $0.value)) }.sorted { $0.1 > $1.1 }
            for (spk, score) in ranked { if spk == probe.speaker { same.append(score) } else { different.append(score) } }
            if ranked.first?.0 == probe.speaker { top1 += 1 }
            let best = ranked[0], margin = best.1 - ranked[1].1
            for th in thresholds {
                var c = accepted[th] ?? (0, 0, 0)
                if best.1 >= th && margin >= 0.08 { if best.0 == probe.speaker { c.correct += 1 } else { c.wrong += 1 } }
                accepted[th] = c
            }
            // Open set: remove the true speaker; the best remaining must be rejected.
            let strangers = ranked.filter { $0.0 != probe.speaker }
            for th in thresholds {
                var c = accepted[th] ?? (0, 0, 0)
                let m = strangers[0].1 - (strangers.count > 1 ? strangers[1].1 : -1)
                if !(strangers[0].1 >= th && m >= 0.08) { c.rejectedOK += 1 }
                accepted[th] = c
            }
        }
        func stats(_ a: [Float]) -> String {
            let s = a.sorted()
            return String(format: "min %.2f p10 %.2f median %.2f p90 %.2f max %.2f", s.first ?? 0, s[s.count / 10], s[s.count / 2], s[s.count * 9 / 10], s.last ?? 0)
        }
        var lines = ["VOICEPRINT \(backend) \(prints.count) people, \(probes.count) probes, top-1 \(top1)/\(probes.count)",
                     "same-person      \(stats(same))", "different-person \(stats(different))"]
        for th in thresholds {
            let c = accepted[th]!
            lines.append(String(format: "threshold %.2f: auto-named correct %d, wrong %d, missed %d | strangers rejected %d/%d",
                                th, c.correct, c.wrong, probes.count - c.correct - c.wrong, c.rejectedOK, probes.count))
        }
        print(lines.joined(separator: "\n"))
        if backend == .wespeaker {
            // The shipped thresholds must never misname or accept a stranger here.
            let atAuto = accepted[0.5]!
            #expect(atAuto.wrong == 0)
            #expect(atAuto.rejectedOK == probes.count)
            #expect(top1 * 4 >= probes.count * 3)
        }
    }
}
