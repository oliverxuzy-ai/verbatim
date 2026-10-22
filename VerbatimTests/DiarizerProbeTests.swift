import AVFAudio
import Foundation
import Testing
@testable import Verbatim

/// Diagnostic: label distribution of the live diarizer variants on the room fixture.
struct DiarizerProbeTests {
    @Test(.timeLimit(.minutes(5)), arguments: [LiveDiarizer.Variant.room, .call])
    func labelDistribution(variant: LiveDiarizer.Variant) async throws {
        let d = LiveDiarizer(variant: variant)
        try await d.prepare()
        let file = try AVAudioFile(forReading: PipelineIntegrationTests.fixtures.appendingPathComponent("meeting-room-mic.m4a"))
        let converter = StreamConverter(to: AudioFormats.mono16k)
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800) else { break }
            try? file.read(into: buf, frameCount: 4800)
            guard buf.frameLength > 0, let mono = buf.monoFloat(.firstChannel), let n = converter.convert(mono) else { break }
            d.feed(n)
        }
        await d.finish()
        var counts: [Int: Int] = [:]
        var t = 0.0
        while t < d.coveredUntil { counts[d.speaker(from: t, to: t + 0.1) ?? -1, default: 0] += 1; t += 0.1 }
        let truth = RoomDiarizationTests.truth
        let perTurn = truth.map { turn in "\(turn.speaker):\(d.speaker(from: turn.start, to: turn.end).map(String.init) ?? "-")" }
        print("VARIANT \(variant) covered=\(d.coveredUntil) counts=\(counts.sorted { $0.key < $1.key }) turns=\(perTurn.joined(separator: " "))")
    }
}
