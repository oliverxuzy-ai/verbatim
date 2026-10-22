import AVFAudio
import Foundation

/// `Verbatim --probe-system-audio <report.json>`: runs the real system audio
/// capture as the installed app (so with its own privacy grants) for four
/// seconds while a short system sound plays, then writes what it saw. Never
/// requests permission; used to diagnose "call audio is empty" reports.
nonisolated enum SystemAudioDiagnostics {
    static func run(writingTo url: URL) async {
        let clocked = CommandLine.arguments.contains("--clocked")
        var report: [String: Any] = [
            "permission": "\(SystemAudioPermission.status)",
            "outputDevice": AudioRouting.defaultOutputName() ?? "unknown",
            "outputUID": AudioRouting.defaultOutputUID() ?? "unknown",
            "headphones": AudioRouting.outputIsHeadphones(),
            "layout": CommandLine.arguments.contains("--clocked") ? "output-clocked" : "tap-only",
        ]
        let capture = SystemAudioCapture()
        let stats = Locked((frames: 0, peak: Float(-160)))
        do {
            try capture.start(clockedByOutput: clocked) { buffer, _ in
                guard let mono = buffer.monoFloat(.average) else { return }
                let db = mono.rmsDecibels()
                stats.withLock { $0.frames += Int(buffer.frameLength); $0.peak = max($0.peak, db) }
            }
            if let f = capture.format { report["tapFormat"] = "\(f.sampleRate) Hz, \(f.channelCount) ch, interleaved \(f.isInterleaved)" }
        } catch {
            report["startError"] = error.localizedDescription
        }
        try? await Task.sleep(for: .milliseconds(500))
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.3", "/System/Library/Sounds/Tink.aiff"]
        try? player.run()
        try? await Task.sleep(for: .seconds(3.5))
        capture.stop()
        let s = stats.current
        report["callbacks"] = capture.callbacks.current
        report["frames"] = s.frames
        report["seconds"] = Double(s.frames) / (capture.format?.sampleRate ?? 48_000)
        report["peakDB"] = s.peak
        report["verdict"] = s.frames == 0 ? "no audio callbacks" : (s.peak > -70 ? "audio captured" : "callbacks but silence (permission?)")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
