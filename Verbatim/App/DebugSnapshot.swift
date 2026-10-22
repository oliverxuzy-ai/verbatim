#if DEBUG
import AppKit
import SwiftUI

/// `Verbatim --snapshot <dir>`: renders every surface with sample data to
/// PNGs (light and dark) and quits. The app images its own views, so no
/// screen recording permission is involved.
enum DebugSnapshot {
    static func run(outputDir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-snapshot-\(UUID().uuidString)")
        let model = AppModel(storeRoot: root)
        model.windows.model = model
        model.panel.model = model
        seed(model)

        let lines: [(String, String, String)] = [
            ("system", "1", "Okay, let's go through your updates. Where are we with the onboarding redesign?"),
            ("mic", "", "The new flow is in review. Sign-up to first recording went from five steps to two."),
            ("system", "1", "Nice. Does that include connecting the calendar, or is that still a separate screen?"),
            ("mic", "", "It's inline now. I'll share the numbers on Thursday, once we have a full week of data."),
        ]
        let now = Date.now
        func event(_ title: String, _ startMin: Double, _ dur: Double, _ link: String?, _ people: Int) -> MeetingInfo {
            MeetingInfo(title: title, scheduledStart: now.addingTimeInterval(startMin * 60), scheduledEnd: now.addingTimeInterval((startMin + dur) * 60),
                        attendees: [Attendee(name: "Me", email: "me@x.com", isSelf: true)] + (0..<people).map { Attendee(name: "Person \($0)", email: "p\($0)@x.com") },
                        conferenceURL: link.flatMap(URL.init(string:)))
        }
        model.calendar.debugSetEvents([
            event("WKLY 1:1 Oliver & Hsiao", -3, 30, "https://meet.google.com/abc-defg-hij", 1),
            event("Weekly team sync", 55, 45, "https://zoom.us/j/1", 6),
            event("Q1 Planning｜新版定价范围介绍", 180, 60, nil, 5),
            event("Design review: capsule v2", 24 * 60 + 60, 30, "https://meet.google.com/xyz", 3),
        ])
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance(named: .darkAqua), "dark"), (NSAppearance(named: .aqua), "light")] {
            NSApp.appearance = appearance
            let idle = offscreen(MenuBarView(model: model).background(Theme.bg), width: 360)
            idle.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            save(idle, to: outputDir.appendingPathComponent("menubar-idle-\(suffix).png"))
            idle.close()
        }

        let meeting = MeetingInfo(title: "WKLY 1:1 Oliver & Hsiao", scheduledStart: .now.addingTimeInterval(-754), scheduledEnd: .now.addingTimeInterval(1046),
                                  attendees: [Attendee(name: "Oliver Xu", email: "o@x.com", isSelf: true), Attendee(name: "Hsiao-Wen Lin", email: "c@x.com")],
                                  conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let session = RecordingSession(meeting: meeting, language: "en-US", micMode: .solo, settings: model.settings, store: model.store)
        session.runDemo(lines: lines)
        model.debugSetSession(session)

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        Task { @MainActor in
            for (appearance, suffix) in [(NSAppearance(named: .darkAqua), "dark"), (NSAppearance(named: .aqua), "light")] {
                NSApp.appearance = appearance
                model.selectedRecordingID = model.store.recordings.first?.id
                model.windows.showMain()
                model.windows.showSettings()
                model.panel.show()
                let menu = offscreen(MenuBarView(model: model).background(Theme.bg), width: 360)
                try? await Task.sleep(for: .seconds(1.5))
                for window in NSApp.windows where window.isVisible {
                    let name: String
                    switch window {
                    case is RecordingPanel: name = "panel"
                    case menu: name = "menubar"
                    default: name = window.title.isEmpty ? "main" : window.title.lowercased().replacingOccurrences(of: " ", with: "-")
                    }
                    save(window, to: outputDir.appendingPathComponent("\(name)-\(suffix).png"))
                }
                menu.close()
            }
            // Today, the home page. Rendered in an offscreen copy of the main
            // window: capturing the titled window from inside the app leaves
            // this page blank (a capture limitation; it draws fine on screen).
            NSApp.appearance = NSAppearance(named: .aqua)
            let today = offscreen(MainWindowView(model: model).frame(height: 620), width: 1040)
            try? await Task.sleep(for: .seconds(0.5))
            model.selectedRecordingID = nil
            try? await Task.sleep(for: .seconds(1))
            save(today, to: outputDir.appendingPathComponent("main-today-light.png"))
            // Toasts, stacked.
            model.toasts.show(.success, "Transcript copied", detail: "42 lines with timestamps and speakers")
            model.toasts.show(.failure, "Couldn't save to Notion", detail: "Share the database with your integration.", actionTitle: "Retry") {}
            model.toasts.show(.success, "Saved to Notion", detail: "Pricing page review", actionTitle: "Open") {}
            try? await Task.sleep(for: .seconds(1))
            save(today, to: outputDir.appendingPathComponent("main-toasts-light.png"))
            today.close()
            // Live transcript view in the main window.
            model.selectedRecordingID = session.recordingID
            try? await Task.sleep(for: .seconds(1))
            if let main = NSApp.windows.first(where: { $0.title == "Verbatim" }) {
                save(main, to: outputDir.appendingPathComponent("main-live-light.png"))
            }
            try? FileManager.default.removeItem(at: root)
            exit(0)
        }
    }

    /// `--demo-session`: a fake live recording (moving levels, menu bar label,
    /// capsule) with no capture or permissions, for profiling the UI.
    static func runDemoSession(model: AppModel) {
        let meeting = MeetingInfo(title: "Demo meeting", attendees: [Attendee(name: "Me", isSelf: true), Attendee(name: "Hsiao")])
        let session = RecordingSession(meeting: meeting, language: "en-US", micMode: .solo, settings: model.settings, store: model.store)
        session.runDemo(lines: [("system", "1", "Hello there, this is a demo."), ("mic", "", "Hi, sounds good.")])
        session.debugStartTicker()
        model.debugSetSession(session)
        model.panel.show()
    }

    private static func offscreen<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: width))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func seed(_ model: AppModel) {
        let base = Date.now.addingTimeInterval(-3 * 3600)
        var rec = Recording(
            meeting: MeetingInfo(title: "Pricing page review", scheduledStart: base, scheduledEnd: base.addingTimeInterval(1800),
                                 attendees: [Attendee(name: "Oliver Xu", email: "o@x.com", isSelf: true), Attendee(name: "Maya Brooks", email: "k@x.com"),
                                             Attendee(name: "Diego Ramos", email: "r@x.com"), Attendee(name: "Ananya Iyer", email: "a@x.com")],
                                 conferenceURL: URL(string: "https://zoom.us/j/123")),
            startedAt: base, endedAt: base.addingTimeInterval(1712), language: "en-US", engine: "apple", micMode: .solo
        )
        rec.speakers = [
            Speaker(id: "me", name: "Oliver Xu", colorIndex: 0, isMe: true, isConfirmed: true),
            Speaker(id: "system:0", name: "Maya Brooks", email: "k@x.com", colorIndex: 1, isConfirmed: true),
            Speaker(id: "system:1", name: "Speaker 2", colorIndex: 2),
            Speaker(id: "system:2", name: "Diego Ramos", colorIndex: 3, isConfirmed: true),
        ]
        let script: [(String, String, String)] = [
            ("me", "mic", "Thanks for joining. Let's go through the pricing page feedback before we publish on Monday."),
            ("system:0", "system", "The big one from sales: people can't tell which plan includes calendar sync. It needs to be in the table, not a footnote."),
            ("system:1", "system", "And the annual toggle resets when you scroll back up, so the prices jump around. That reads as a bug."),
            ("system:0", "system", "Right. The FAQ also still mentions the old trial length."),
            ("me", "mic", "Good catches. I'll turn each of these into a ticket: plan comparison table, sticky toggle, and the FAQ copy."),
            ("system:2", "system", "Can we add a line about on-device transcription too? Privacy comes up on almost every call."),
            ("me", "mic", "Yes, I'll draft it today and share it before lunch."),
        ]
        var t = 4.0
        for (speaker, channel, text) in script {
            let dur = Double(text.count) / 15
            rec.segments.append(Segment(channel: AudioChannel(rawValue: channel)!, speakerID: speaker, start: t, end: t + dur, text: text, isFinal: true))
            t += dur + 3
        }
        model.store.save(rec)
        var older = rec
        older.id = UUID()
        older.meeting.title = "Weekly team sync"
        older.startedAt = base.addingTimeInterval(-26 * 3600)
        older.endedAt = older.startedAt.addingTimeInterval(2950)
        older.notionPageURL = URL(string: "https://www.notion.so/example")
        model.store.save(older)
        var third = older
        third.id = UUID()
        third.meeting.title = "Customer interview: onboarding"
        third.startedAt = base.addingTimeInterval(-50 * 3600)
        third.endedAt = third.startedAt.addingTimeInterval(1500)
        third.notionPageURL = nil
        model.store.save(third)
    }
}
#endif
