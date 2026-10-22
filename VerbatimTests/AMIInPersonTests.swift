import Foundation
import Testing
@testable import Verbatim

/// The real in-person proof: a whole AMI meeting recorded on one far-field
/// mic goes through the shipped post-meeting pipeline (re-transcription plus
/// speaker clustering), and every recognized word is scored against the
/// human-annotated speaker turns. Skipped unless Bench/ami has the audio.
@MainActor
struct AMIInPersonTests {
    @Test(.enabled(if: DiarizationBenchmarkTests.available), .timeLimit(.minutes(30)), arguments: DiarizationBenchmarkTests.meetings)
    func refinedTranscriptAttributesWordsToTheRightPerson(meeting: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-ami-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let rec = Recording(meeting: MeetingInfo(title: "AMI \(meeting)", attendees: [
            Attendee(name: "Me", isSelf: true), Attendee(name: "P2"), Attendee(name: "P3"), Attendee(name: "P4"),
        ]), startedAt: .now, endedAt: .now, language: "en-US", engine: "apple", micMode: .room)
        try FileManager.default.createDirectory(at: store.folder(for: rec.id), withIntermediateDirectories: true)
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "alac",
                             DiarizationBenchmarkTests.dir.appendingPathComponent("\(meeting).Array1-01.wav").path,
                             store.audioURL(for: rec.id, channel: .mic).path]
        try convert.run()
        convert.waitUntilExit()
        store.save(rec)

        let started = Date()
        let refined = try await TranscriptRefiner.refine(rec, store: store, myName: "Me", terms: [], retranscribe: true) { _ in }
        let elapsed = Date().timeIntervalSince(started)

        let ref = DiarizationBenchmarkTests.reference(meeting)
        var confusion: [String: [String: Int]] = [:]
        var scored = 0, words = 0
        for seg in refined.visibleSegments {
            for w in seg.words ?? [] {
                words += 1
                let mid = (w.start + w.end) / 2
                let active = ref.filter { $0.start <= mid && mid < $0.end }
                guard active.count == 1 else { continue }
                scored += 1
                confusion[active[0].speaker, default: [:]][seg.speakerID, default: 0] += 1
            }
        }
        var pairs = confusion.flatMap { r, p in p.map { (r, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        var usedR = Set<String>(), usedP = Set<String>(), matched = 0
        while let (r, p, n) = pairs.first {
            pairs.removeFirst()
            guard !usedR.contains(r), !usedP.contains(p) else { continue }
            usedR.insert(r); usedP.insert(p); matched += n
        }
        let accuracy = Double(matched) / Double(max(scored, 1))
        let clusters = Set(refined.visibleSegments.map(\.speakerID)).count
        print(String(format: "AMI-INPERSON %@: %d words (%d single-speaker), word attribution %.1f%%, %d speakers found (truth %d), %.0fs",
                     meeting, words, scored, accuracy * 100, clusters, Set(ref.map(\.speaker)).count, elapsed))
        for s in refined.visibleSegments.prefix(12) { print("  [\(s.start.clockString)] \(refined.speakerName(s.speakerID)): \(s.text.prefix(90))") }
        #expect(accuracy >= 0.8)
        #expect(clusters >= 3 && clusters <= 5)
    }
}
