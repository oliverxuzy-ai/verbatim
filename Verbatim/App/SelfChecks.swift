import AppKit
import SwiftUI
import Foundation

/// Command-line self checks that run as the installed app (with its own
/// privacy grants) and write a JSON report. They never ask for new
/// permissions and leave no recordings behind.
///   --probe-calendar <report.json>
///   --probe-recording <report.json>   (6 s real session in a temp store)
enum SelfChecks {
    static func calendar(writingTo url: URL, requestAccess: Bool = false) async {
        let service = CalendarService()
        // Only when explicitly asked (the user is present to answer the prompt).
        if requestAccess, service.access != .granted { await service.requestAccess() }
        if service.access == .granted {
            service.refreshRemoteSources()
            try? await Task.sleep(for: .seconds(3))
        }
        var report: [String: Any] = ["access": "\(service.access)"]
        if service.access == .granted {
            service.refresh()
            report["calendars"] = service.calendars.map { ["title": $0.title, "account": $0.account] }
            let iso = ISO8601DateFormatter()
            report["events"] = service.events.prefix(20).map { m -> [String: Any] in
                [
                    "title": m.title,
                    "start": m.scheduledStart.map(iso.string(from:)) ?? "",
                    "attendees": m.attendees.count,
                    "conference": m.conferenceProvider?.label ?? "",
                ]
            }
            report["current"] = service.current?.title ?? ""
            if let i = CommandLine.arguments.firstIndex(of: "--days"), i + 1 < CommandLine.arguments.count, let days = Int(CommandLine.arguments[i + 1]) {
                let wide = service.meetings(withinDays: days)
                report["wideCount"] = wide.count
                report["wideMeetings"] = wide.filter { $0.meeting.attendees.count > 1 || $0.meeting.conferenceURL != nil }.prefix(25).map { item -> [String: Any] in
                    let m = item.meeting
                    return [
                        "title": m.title,
                        "start": m.scheduledStart.map(iso.string(from:)) ?? "",
                        "calendar": item.calendar,
                        "account": item.account,
                        "attendees": m.attendees.map { "\($0.displayName)\($0.isSelf ? " (me)" : "")\($0.isOrganizer ? " (organizer)" : "")" },
                        "conference": m.conferenceProvider?.label ?? "",
                        "link": m.conferenceURL?.absoluteString ?? "",
                    ]
                }
            }
        }
        write(report, to: url)
    }

    /// Temporary event "happening now" on the user's personal Google calendar
    /// (no attendees, no alarms, nothing sent), then: does it show up as the
    /// current meeting with its Meet link, and does recording from it carry
    /// the title and link? The event is deleted afterwards.
    static func calendarRoundTrip(writingTo url: URL) async {
        var report: [String: Any] = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-cal-\(UUID().uuidString)/Recordings")
        let model = AppModel(storeRoot: root)
        model.windows.model = model
        model.panel.model = model
        let calendar = model.calendar
        report["access"] = "\(calendar.access)"
        guard calendar.access == .granted else { write(report, to: url); return }
        // --title <t>: use an existing meeting (e.g. created on Google's side)
        // instead of creating a local one.
        let args = CommandLine.arguments
        let existing = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let title = existing ?? "Verbatim calendar test (auto-deleted)"
        var eventID: String?
        if existing == nil {
            do {
                eventID = try calendar.createTemporaryEvent(title: title, link: URL(string: "https://meet.google.com/vbt-test-now")!, account: "oliverxuzy")
            } catch {
                report["createError"] = error.localizedDescription
            }
            report["created"] = eventID != nil
        }
        defer { if let eventID { try? calendar.deleteEvent(eventID) } }
        try? await Task.sleep(for: .seconds(2))
        calendar.refresh()
        // A past meeting can be replayed by title too (same mapping, read from a wider window).
        let past = existing.flatMap { t in calendar.meetings(withinDays: 400).first(where: { $0.meeting.title == t })?.meeting }
        if let found = calendar.upcoming.first(where: { $0.title == title }) ?? past {
            report["attendees"] = found.attendees.map { "\($0.displayName) <\($0.email ?? "")>\($0.isSelf ? " (me)" : "")\($0.isOrganizer ? " (organizer)" : "")" }
            report["calendarName"] = found.calendarName ?? ""
        }
        let current = calendar.current
        report["currentMeeting"] = current?.title ?? ""
        report["currentProvider"] = current?.conferenceProvider?.label ?? ""
        report["currentLink"] = current?.conferenceURL?.absoluteString ?? ""
        report["inUpcomingList"] = calendar.upcoming.contains { $0.title == title }
        if let meeting = calendar.upcoming.first(where: { $0.title == title }) ?? past {
            // Same call the menu bar makes when you click the meeting's record button.
            model.startRecording(meeting: meeting, language: "en-US")
            for _ in 0..<80 where model.session?.phase != .recording { try? await Task.sleep(for: .milliseconds(100)) }
            if args.contains("--say") {
                // A remote voice through the speakers, so the call-audio channel has a speaker to name.
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", "Samantha", "Thanks for joining. Let's go over the launch checklist and the open questions for next week."]
                try? say.run()
                try? await Task.sleep(for: .seconds(7))
            } else {
                try? await Task.sleep(for: .seconds(3))
            }
            let id = model.session?.recordingID
            model.stopRecording()
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(200))
                if let id, case .done = model.refineStates[id] { break }
                if let id, case .failed = model.refineStates[id] { break }
            }
            if let id, let rec = model.store.recording(id) {
                report["recordingTitle"] = rec.meeting.title
                report["recordingLink"] = rec.meeting.conferenceURL?.absoluteString ?? ""
                report["recordingCalendar"] = rec.meeting.calendarName ?? ""
                let props = NotionExporter.properties(
                    for: rec, schema: ["会议标题": "title", "录音 / 会议链接": "url", "外部参会人": "rich_text"], members: [], sourceOption: "Verbatim"
                )
                report["notionLinkProperty"] = props["录音 / 会议链接"].map { "\($0)" } ?? ""
                report["notionExternalAttendees"] = props["外部参会人"].map { "\($0)" } ?? ""
                report["recordingAttendees"] = rec.meeting.attendees.map(\.displayName)
                report["speakers"] = rec.speakers.map { "\($0.id) = \($0.name)\($0.isMe ? " (me)" : "")\($0.isConfirmed ? " confirmed" : " suggested") via \(rec.speakerSources?[$0.id] ?? "-")" }
                report["finalSegments"] = rec.visibleSegments.map { "[\($0.start.clockString)] \(rec.speakerName($0.speakerID)): \($0.text)" }
            }
        }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        write(report, to: url)
    }

    static func recording(writingTo url: URL) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-selfcheck-\(UUID().uuidString)/Recordings")
        let model = AppModel(storeRoot: root)
        model.windows.model = model
        model.panel.model = model
        var report: [String: Any] = [
            "micPermission": MicCapture.permissionGranted,
            "systemPermission": "\(SystemAudioPermission.status)",
        ]
        guard MicCapture.permissionGranted, SystemAudioPermission.status == .granted else {
            report["skipped"] = "permissions not granted; not requesting from a self check"
            write(report, to: url)
            return
        }
        model.startRecording(meeting: MeetingInfo(title: "Verbatim self check"), language: "en-US")
        // Wait for the session to reach .recording.
        for _ in 0..<100 {
            if model.session?.phase == .recording { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        report["phaseAfterStart"] = "\(model.session?.phase ?? .finished)"
        try? await Task.sleep(for: .seconds(1))
        // Speech through the speakers: the call-audio channel should hear it.
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "Hello from the Verbatim self check. The semantic layer review is on Thursday."]
        try? say.run()
        var peak: Float = 0
        for i in 0..<70 {
            try? await Task.sleep(for: .milliseconds(100))
            peak = max(peak, model.session?.levelHistory.max() ?? 0)
            if i == 35, let panel = NSApp.windows.first(where: { $0 is RecordingPanel }) {
                report["capsuleVisible"] = panel.isVisible
                report["capsuleSize"] = "\(Int(panel.frame.width))x\(Int(panel.frame.height))"
                if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: url.deletingPathExtension().appendingPathExtension("capsule.png"))
                }
            }
        }
        report["waveformPeakLevel"] = peak
        report["liveWarnings"] = model.session?.warnings ?? []
        let live = model.session?.transcript.recording
        report["liveSegments"] = live?.visibleSegments.map { "[\($0.start.clockString)] \($0.channel.rawValue) \(live?.speakerName($0.speakerID) ?? ""): \($0.text)" } ?? []
        let id = model.session?.recordingID
        model.stopRecording()
        // Wait for stop + post-processing (bounded).
        for _ in 0..<600 {
            try? await Task.sleep(for: .milliseconds(200))
            if let id, case .done = model.refineStates[id] { break }
            if let id, case .failed = model.refineStates[id] { break }
        }
        if let id, let rec = model.store.recording(id) {
            report["finalState"] = "\(model.refineStates[id].map { "\($0)" } ?? "nil")"
            report["mode"] = rec.micMode.rawValue
            report["systemAudioSeconds"] = TranscriptRefiner.audioSeconds(model.store.audioURL(for: id, channel: .system))
            report["finalSegments"] = rec.visibleSegments.map { "[\($0.start.clockString)] \($0.channel.rawValue) \(rec.speakerName($0.speakerID)): \($0.text)" }
        }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        write(report, to: url)
    }

    // MARK: Real UI, end to end

    /// Store for `--probe-ui`: the app's own model runs on a temporary folder
    /// so the check never touches real recordings or voiceprints.
    static let uiProbeStoreRoot: URL? = ["--probe-ui", "--probe-identify", "--probe-menu", "--demo-session"].contains(where: CommandLine.arguments.contains)
        ? FileManager.default.temporaryDirectory.appendingPathComponent("verbatim-ui-\(UUID().uuidString)/Recordings")
        : nil

    /// Drives the windows a person would use, with real mouse events: click
    /// the menu bar item, click the current meeting's record button, pause,
    /// resume and stop from the capsule, then click "Export to Notion" in the
    /// main window that pops up. Buttons are found from the rendered pixels
    /// and the layout, like a person looking at the screen. Two voices play
    /// through the speakers as the remote side. The calendar event is
    /// temporary; the Notion page is real (the caller removes it).
    static func ui(model: AppModel, writingTo url: URL) async {
        var report: [String: Any] = [:]
        var steps: [String] = []
        let base = url.deletingPathExtension()
        func shot(_ window: NSWindow?, _ name: String) {
            guard let rep = window.flatMap(snapshot) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("\(name).png"))
        }
        let calendar = model.calendar
        guard calendar.access == .granted, MicCapture.permissionGranted, SystemAudioPermission.status == .granted else {
            report["skipped"] = "calendar, microphone or system audio permission missing"
            write(report, to: url)
            return
        }
        let title = "Verbatim UI check (auto-deleted)"
        let eventID = try? calendar.createTemporaryEvent(title: title, link: URL(string: "https://meet.google.com/vbt-uich-eck")!, account: "oliverxuzy")
        report["eventCreated"] = eventID != nil
        func finish() {
            if let eventID { try? calendar.deleteEvent(eventID) }
            report["steps"] = steps
            write(report, to: url)
            if let root = uiProbeStoreRoot { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        }
        try? await Task.sleep(for: .seconds(2))
        calendar.refresh()

        // 1. Menu bar item -> meeting picker -> the meeting's red record button.
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
        let statusButton = statusWindow?.contentView.flatMap { findView(NSStatusBarButton.self, in: $0) }
        report["statusItemInMenuBar"] = statusButton != nil
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        statusButton?.performClick(nil)
        try? await Task.sleep(for: .seconds(1.5))
        guard let menu = NSApp.windows.first(where: { $0.isVisible && !visibleBefore.contains(ObjectIdentifier($0)) }) else {
            steps.append("menu bar click did not open the picker")
            finish()
            return
        }
        steps.append("clicked the menu bar item; picker opened (\(Int(menu.frame.width))x\(Int(menu.frame.height)))")
        shot(menu, "menu")
        // The current meeting is preselected and shows a black "Record" pill.
        guard let record = colorBlockCenter(in: menu, color: Theme.text, minRun: 40) else {
            steps.append("no record button visible in the picker")
            finish()
            return
        }
        await click(menu, at: record)
        steps.append("clicked the meeting's record button at \(Int(record.x)),\(Int(record.y))")
        for _ in 0..<100 where model.session?.phase != .recording { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session = model.session, session.phase == .recording else {
            steps.append("recording did not start: \(model.lastError ?? "no error")")
            finish()
            return
        }
        report["recordingMeeting"] = session.transcript.recording.meeting.title
        report["recordingMeetLink"] = session.transcript.recording.meeting.conferenceURL?.absoluteString ?? ""
        report["menuClosedAfterStart"] = !menu.isVisible

        // 2. Capsule: visible, waveform moves with speech, pause / resume.
        guard let capsule = NSApp.windows.first(where: { $0 is RecordingPanel && $0.isVisible }), let capsuleView = capsule.contentView else {
            steps.append("capsule not visible")
            finish()
            return
        }
        report["capsule"] = "\(Int(capsule.frame.width))x\(Int(capsule.frame.height)), floating above other windows: \(capsule.level == .floating)"
        let stopPoint = CGPoint(x: capsuleView.bounds.midX, y: RecordingPanelView.Layout.stopCenterFromBottom)
        let pausePoint = CGPoint(x: capsuleView.bounds.midX, y: RecordingPanelView.Layout.pauseCenterFromBottom)
        try? await Task.sleep(for: .seconds(1.5))
        let quietPeak = session.levelHistory.suffix(10).max() ?? 0
        let lines: [(String, String)] = [
            ("Samantha", "Thanks everyone for joining. I want to walk through the launch checklist before Friday."),
            ("Daniel", "Sounds good. The data migration finished last night, and the dashboards are already pointing at the new tables."),
            ("Samantha", "Great. Then the only open item is the pricing page. Can you send the final copy by Wednesday?"),
            ("Daniel", "Yes, I will send it on Wednesday morning and loop in the design team for review."),
        ]
        var speechPeak: Float = 0
        for (index, line) in lines.enumerated() {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", line.0, line.1]
            try? say.run()
            while say.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
                speechPeak = max(speechPeak, session.levelHistory.suffix(3).max() ?? 0)
            }
            if index == 1 { shot(capsule, "capsule") }
            try? await Task.sleep(for: .milliseconds(700))
        }
        report["waveformLevel"] = String(format: "silence %.3f, speech %.3f", quietPeak, speechPeak)
        await click(capsule, at: pausePoint)
        try? await Task.sleep(for: .milliseconds(500))
        report["pausedByCapsuleClick"] = session.isPaused
        shot(capsule, "capsule-paused")
        await click(capsule, at: pausePoint)
        try? await Task.sleep(for: .milliseconds(500))
        report["resumedByCapsuleClick"] = !session.isPaused
        let live = session.transcript.recording
        report["liveTranscript"] = live.visibleSegments.map { "[\($0.start.clockString)] \(live.speakerName($0.speakerID)): \($0.text)" }

        // 3. One click on stop in the capsule -> main window pops up.
        let id = session.recordingID
        await click(capsule, at: stopPoint)
        steps.append("clicked stop in the capsule")
        try? await Task.sleep(for: .seconds(1))
        let main = NSApp.windows.first { $0.isVisible && $0.title == "Verbatim" && !($0 is RecordingPanel) && $0.frame.width > 500 }
        report["capsuleHiddenAfterStop"] = !capsule.isVisible
        report["mainWindowPoppedUp"] = main != nil
        shot(main, "main-processing")
        for _ in 0..<900 {
            try? await Task.sleep(for: .milliseconds(200))
            if case .done = model.refineStates[id] { break }
            if case .failed = model.refineStates[id] { break }
        }
        report["postProcessing"] = model.refineStates[id].map { "\($0)" } ?? "nil"
        guard let rec = model.store.recording(id) else { finish(); return }
        report["mode"] = rec.micMode.rawValue
        report["speakers"] = rec.speakers.map { "\($0.id) = \($0.name)\($0.isMe ? " (me)" : "")" }
        report["finalTranscript"] = rec.visibleSegments.map { "[\($0.start.clockString)] \(rec.speakerName($0.speakerID)): \($0.text)" }
        try? await Task.sleep(for: .seconds(1))
        shot(main, "main")

        // 4. One click on the title, type a new one, Return.
        if let main, let content = main.contentView,
           let titlePoint = colorBlockCenter(in: main, color: Theme.text,
                                             region: CGRect(x: content.bounds.width * 0.27, y: 52, width: content.bounds.width * 0.35, height: 44)) {
            await click(main, at: titlePoint)
            try? await Task.sleep(for: .milliseconds(500))
            shot(main, "main-editing-title")
            for character in "Renamed with one click" { await press(main, String(character)) }
            await press(main, "\r", keyCode: 36)
            try? await Task.sleep(for: .milliseconds(500))
            report["titleAfterClickRename"] = model.store.recording(id)?.meeting.title ?? ""
            shot(main, "main-renamed")
        } else {
            steps.append("meeting title not found in the main window")
        }
        // ⌘K: the command bar finds the renamed meeting.
        if let main {
            await press(main, "k", keyCode: 40, modifiers: .command)
            try? await Task.sleep(for: .milliseconds(500))
            for character in "renamed" { await press(main, String(character)) }
            try? await Task.sleep(for: .milliseconds(400))
            shot(main, "command-bar")
            await press(main, "\u{1b}", keyCode: 53)
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Settings → Calendar: the Google connection section.
        model.windows.showSettings(section: .calendar)
        try? await Task.sleep(for: .seconds(1))
        shot(NSApp.windows.first { $0.isVisible && $0.title == "Settings" }, "settings-calendar")

        // 5. One click on "Export to Notion" (the dark primary button in the header).
        if CommandLine.arguments.contains("--no-export") { finish(); return }
        guard let main, let content = main.contentView,
              let export = colorBlockCenter(in: main, color: Theme.text, minRun: 60,
                                            region: CGRect(x: content.bounds.width * 0.4, y: 0, width: content.bounds.width * 0.6, height: 160)) else {
            steps.append("no Export to Notion button found in the main window")
            finish()
            return
        }
        await click(main, at: export)
        steps.append("clicked Export to Notion at \(Int(export.x)),\(Int(export.y))")
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(200))
            if case .done = model.exportState(id) { break }
            if case .failed = model.exportState(id) { break }
        }
        switch model.exportState(id) {
        case .done(let page): report["notionPage"] = page.absoluteString
        case .failed(let message): report["notionError"] = message
        case .exporting: report["notionError"] = "timed out"
        case .idle: report["notionError"] = "click did not start an export"
        }
        try? await Task.sleep(for: .seconds(1))
        shot(main, "main-exported")
        finish()
    }

    /// Who is speaking, with a real invite (`--title <calendar event>` with
    /// two other attendees): two meetings, two voices through the speakers.
    /// Meeting 1 must name the voices from how people address each other;
    /// the suggestions are accepted as in the speaker editor, and meeting 2
    /// must name them by voice alone. Each meeting is stopped
    /// with a click on the capsule, and the second is exported with a click
    /// on "Export to Notion".
    static func identify(model: AppModel, writingTo url: URL) async {
        var report: [String: Any] = [:]
        let base = url.deletingPathExtension()
        func shot(_ window: NSWindow?, _ name: String) {
            guard let rep = window.flatMap(snapshot) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("\(name).png"))
        }
        let args = CommandLine.arguments
        func finish() {
            if args.contains("--keep") { report["keptStore"] = uiProbeStoreRoot?.path ?? "" }
            write(report, to: url)
            if !args.contains("--keep"), let root = uiProbeStoreRoot { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        }
        guard model.calendar.access == .granted, MicCapture.permissionGranted, SystemAudioPermission.status == .granted,
              let title = args.firstIndex(of: "--title").flatMap({ $0 + 1 < args.count ? args[$0 + 1] : nil }),
              let meeting = model.calendar.meetings(withinDays: 400).first(where: { $0.meeting.title == title })?.meeting else {
            report["skipped"] = "permissions missing or meeting not found"
            finish()
            return
        }
        let invitees = meeting.attendees.filter { !$0.isSelf }
        guard invitees.count >= 2 else {
            report["skipped"] = "the meeting needs two other attendees"
            finish()
            return
        }
        report["invitees"] = invitees.map { "\($0.displayName) <\($0.email ?? "")>" }
        let voices = ["Samantha", "Daniel"]
        // Voice 0 is invitee 0 and voice 1 is invitee 1; they address each
        // other by first name, as people do, which is all meeting 1 has to go on.
        let a = CalendarRules.firstName(invitees[0].displayName) ?? invitees[0].displayName
        let b = CalendarRules.firstName(invitees[1].displayName) ?? invitees[1].displayName
        let first: [(Int, String)] = [
            (0, "Thanks everyone for joining. \(b), can you start with the data migration?"),
            (1, "Sure. The migration finished last night, and the dashboards are already pointing at the new tables."),
            (0, "Great. And is the pricing page ready, \(b)?"),
            (1, "Almost. \(a), do you want the final copy by Wednesday?"),
            (0, "Wednesday works for me. Thanks, \(b)."),
        ]
        let second: [(Int, String)] = [
            (0, "Welcome back. Let's check where we landed on the pricing page since last week."),
            (1, "The copy is final. Design signed off yesterday, so we can publish it on Monday morning."),
            (0, "Perfect. I will tell the sales team that the new pricing goes live on Monday."),
            (1, "Sounds good. I will also update the help center articles before then."),
        ]
        func lines(_ rec: Recording) -> [String] {
            rec.visibleSegments.map { "[\($0.start.clockString)] \(rec.speakerName($0.speakerID)): \($0.text)" }
        }
        func speakers(_ rec: Recording) -> [String] {
            rec.speakers.map { "\($0.name)\($0.isMe ? " (me)" : "")\($0.isConfirmed ? "" : " (unconfirmed)") via \(rec.speakerSources?[$0.id] ?? "live")" }
        }

        // Meeting 1: nobody is known yet.
        guard let id1 = await runMeeting(model, meeting, lines: first, voices: voices), let rec1 = model.store.recording(id1) else {
            report["error"] = "meeting 1 did not record: \(model.lastError ?? "")"
            finish()
            return
        }
        report["meeting1Speakers"] = speakers(rec1)
        report["meeting1Transcript"] = lines(rec1)
        report["meeting1Live"] = liveSnapshots[id1].map(lines) ?? []
        let voiceOwner = [invitees[0], invitees[1]]
        func named(_ rec: Recording, _ lines: [(Int, String)]) -> String {
            var correct = 0, total = 0
            for (index, text) in lines {
                guard let seg = rec.visibleSegments.first(where: { text.hasPrefix(String($0.text.prefix(14))) }) else { continue }
                total += 1
                if rec.speakerName(seg.speakerID) == voiceOwner[index].displayName { correct += 1 }
            }
            return "\(correct)/\(total)"
        }
        report["meeting1LinesNamedCorrectly"] = named(rec1, first)

        // Accept the suggestions, as clicking the check mark in the speaker editor does.
        for speaker in rec1.speakers where !speaker.isMe && !speaker.isConfirmed && !CalendarRules.isGeneric(speaker.name) {
            model.updateSpeaker(recordingID: id1, speakerID: speaker.id, name: speaker.name, email: speaker.email)
        }
        for _ in 0..<150 where model.voiceprints.voiceprints.filter({ $0.id != VoiceprintStore.meID }).count < 2 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        report["voiceprintsAfterConfirming"] = model.voiceprints.voiceprints.map(\.name)

        // Meeting 2: same people, new sentences; names must come from their voices.
        guard let id2 = await runMeeting(model, meeting, lines: second, voices: voices), let rec2 = model.store.recording(id2) else {
            report["error"] = "meeting 2 did not record: \(model.lastError ?? "")"
            finish()
            return
        }
        report["meeting2Speakers"] = speakers(rec2)
        report["meeting2Transcript"] = lines(rec2)
        report["meeting2Live"] = liveSnapshots[id2].map(lines) ?? []
        report["meeting2LinesNamedCorrectly"] = named(rec2, second)
        // Export only a run that identified everyone, so a failed run adds
        // no page to the database.
        if args.contains("--no-export") { finish(); return }
        guard rec2.visibleSegments.filter({ $0.channel == .system }).allSatisfy({ !CalendarRules.isGeneric(rec2.speakerName($0.speakerID)) }) else {
            report["notionError"] = "skipped: not everyone was identified"
            finish()
            return
        }

        // One click: "Export to Notion" for meeting 2, under a test title.
        model.renameRecording(id2, title: "Verbatim speaker ID check (test page, delete me)")
        try? await Task.sleep(for: .seconds(1))
        let main = NSApp.windows.first { $0.isVisible && $0.title == "Verbatim" && !($0 is RecordingPanel) && $0.frame.width > 500 }
        shot(main, "main")
        guard let main, let content = main.contentView,
              let export = colorBlockCenter(in: main, color: Theme.text, minRun: 60,
                                            region: CGRect(x: content.bounds.width * 0.4, y: 0, width: content.bounds.width * 0.6, height: 160)) else {
            report["notionError"] = "no Export to Notion button found"
            finish()
            return
        }
        await click(main, at: export)
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(200))
            if case .done = model.exportState(id2) { break }
            if case .failed = model.exportState(id2) { break }
        }
        switch model.exportState(id2) {
        case .done(let page): report["notionPage"] = page.absoluteString
        case .failed(let message): report["notionError"] = message
        case .exporting: report["notionError"] = "timed out"
        case .idle: report["notionError"] = "click did not start an export"
        }
        try? await Task.sleep(for: .seconds(1))
        shot(main, "main-exported")
        finish()
    }

    /// The live transcript of each meeting right before it was stopped.
    private static var liveSnapshots: [UUID: Recording] = [:]

    /// Start from a meeting (the call the record buttons make), play the
    /// lines, stop with a click on the capsule, wait for post-processing.
    private static func runMeeting(_ model: AppModel, _ meeting: MeetingInfo, lines: [(Int, String)], voices: [String]) async -> UUID? {
        model.startRecording(meeting: meeting, language: "en-US")
        for _ in 0..<100 where model.session?.phase != .recording { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session = model.session, session.phase == .recording else { return nil }
        try? await Task.sleep(for: .seconds(1.5))
        for line in lines {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voices[line.0], line.1]
            try? say.run()
            while say.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(700))
        }
        let id = session.recordingID
        liveSnapshots[id] = session.transcript.recording
        guard let capsule = NSApp.windows.first(where: { $0 is RecordingPanel && $0.isVisible }), let view = capsule.contentView else { return nil }
        await click(capsule, at: CGPoint(x: view.bounds.midX, y: RecordingPanelView.Layout.stopCenterFromBottom))
        for _ in 0..<900 {
            try? await Task.sleep(for: .milliseconds(200))
            if case .done = model.refineStates[id] { break }
            if case .failed = model.refineStates[id] { break }
        }
        return id
    }

    /// Clicks the menu panel's header buttons (Settings, Open Verbatim) like
    /// a mouse and reports whether their windows came up.
    static func menuButtons(model: AppModel, writingTo url: URL) async {
        var report: [String: Any] = [:]
        let base = url.deletingPathExtension()
        if CommandLine.arguments.contains("--recording") {
            // The state from the report: a recording in progress, paused.
            model.startRecording(meeting: .adHoc())
            for _ in 0..<100 where model.session?.phase != .recording { try? await Task.sleep(for: .milliseconds(100)) }
            model.session?.togglePause()
            model.windows.hideAll()
            try? await Task.sleep(for: .seconds(1))
            report["recordingPaused"] = model.session?.isPaused ?? false
        }
        func openMenu() async -> NSWindow? {
            // Usually Verbatim isn't the active app when someone clicks its menu bar icon.
            if CommandLine.arguments.contains("--inactive") {
                NSApp.deactivate()
                try? await Task.sleep(for: .milliseconds(600))
                report["activeBeforeMenu"] = NSApp.isActive
            }
            let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
            let button = statusWindow?.contentView.flatMap { findView(NSStatusBarButton.self, in: $0) }
            let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            button?.performClick(nil)
            try? await Task.sleep(for: .seconds(1.2))
            return NSApp.windows.first { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
        }
        func visible(_ title: String) -> Bool { NSApp.windows.contains { $0.isVisible && $0.title == title } }
        guard let menu = await openMenu(), let view = menu.contentView else {
            report["error"] = "menu did not open"
            write(report, to: url)
            return
        }
        report["menuSize"] = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
        if let rep = snapshot(menu) { try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("menu.png")) }
        // Header: 46 pt tall, trailing padding 8, 26 pt icon buttons 8 pt apart (gear is last).
        let y = view.bounds.height - 23
        let gear = CGPoint(x: view.bounds.width - 8 - 13, y: y)
        report["hitAtGear"] = String(describing: type(of: view.hitTest(gear) as Any))
        await click(menu, at: gear)
        try? await Task.sleep(for: .seconds(1))
        report["settingsOpenedByGear"] = visible("Settings")
        report["settingsOnThisSpace"] = NSApp.windows.first { $0.title == "Settings" }?.isOnActiveSpace ?? false
        report["menuWindowClass"] = String(describing: type(of: menu))
        report["menuClosedAfterGear"] = !menu.isVisible
        let menu2 = menu.isVisible ? menu : await openMenu()
        report["menuReopenedAfterGear"] = menu2 != nil
        if let menu2, let view2 = menu2.contentView {
            let windowIcon = CGPoint(x: view2.bounds.width - 8 - 13 - 26 - 8, y: view2.bounds.height - 23)
            await click(menu2, at: windowIcon)
            try? await Task.sleep(for: .seconds(1))
            report["mainOpenedByWindowIcon"] = visible("Verbatim")
        }
        // The menu still opens normally after being closed from code.
        let again = await openMenu()
        report["menuOpensAgain"] = again != nil
        if model.session != nil {
            model.stopRecording()
            try? await Task.sleep(for: .seconds(2))
        }
        write(report, to: url)
        if let root = uiProbeStoreRoot { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private static func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Center, in window coordinates, of the pixels drawn in `color`. With
    /// `minRun`, only solid horizontal runs count (a filled button, not text).
    /// `region` is in points from the top-left of the window's content.
    private static func colorBlockCenter(in window: NSWindow, color: Color, minRun: Int = 1, region: CGRect? = nil) -> CGPoint? {
        guard let view = window.contentView, let rep = snapshot(window) else { return nil }
        // Compare raw samples in the bitmap's own color space (the display's,
        // usually P3), with the theme color converted into it.
        var target: NSColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance { target = NSColor(color).usingColorSpace(rep.colorSpace) }
        guard let target, rep.samplesPerPixel >= 3, rep.bitsPerSample == 8 else { return nil }
        let want = [target.redComponent, target.greenComponent, target.blueComponent].map { Int($0 * 255) }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let area = (region ?? view.bounds).applying(CGAffineTransform(scaleX: scale, y: scale))
            .intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        var pixel = [Int](repeating: 0, count: rep.samplesPerPixel)
        func matches(_ x: Int, _ y: Int) -> Bool {
            rep.getPixel(&pixel, atX: x, y: y)
            let o = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            return abs(pixel[o] - want[0]) < 24 && abs(pixel[o + 1] - want[1]) < 24 && abs(pixel[o + 2] - want[2]) < 24
        }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in Int(area.minY)..<Int(area.maxY) {
            var run = 0
            for x in Int(area.minX)..<Int(area.maxX) {
                run = matches(x, y) ? run + 1 : 0
                if run >= minRun {
                    minX = min(minX, x - run + 1); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            // Stop at the first block: rows below it belong to something else.
            if minRun > 1, maxY != Int.min, y > maxY + 4 { break }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cx = CGFloat(minX + maxX) / 2 / scale
        let cyFromTop = CGFloat(minY + maxY) / 2 / scale
        return CGPoint(x: cx, y: view.bounds.height - cyFromTop)
    }

    /// A left click delivered to the window like one from the mouse.
    private static func click(_ window: NSWindow, at point: CGPoint) async {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
        try? await Task.sleep(for: .milliseconds(80))
        if let up = event(.leftMouseUp) { NSApp.sendEvent(up) }
    }

    /// One key typed into the window's focused field.
    private static func press(_ window: NSWindow, _ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                // Shortcuts go through the app (key equivalents); typing goes to the window.
                if modifiers.isEmpty { window.sendEvent(event) } else { NSApp.sendEvent(event) }
            }
        }
        try? await Task.sleep(for: .milliseconds(15))
    }

    private static func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = findView(type, in: sub) { return match } }
        return nil
    }

    private static func write(_ report: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
