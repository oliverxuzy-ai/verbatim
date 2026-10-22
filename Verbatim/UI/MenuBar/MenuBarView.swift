import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    @State private var selected: MeetingInfo?
    @State private var language: String = ""
    @State private var listHeight: CGFloat = 0
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let session = model.session, session.isActive {
                activeSession(session)
            } else {
                meetingPicker
            }
            Hairline()
            footer
        }
        .frame(width: 360)
        .background(GlassBackground(material: .popover, tint: Theme.bg, opacity: 0.72))
        .onAppear {
            if language.isEmpty { language = model.settings.language }
            model.calendar.refresh()
            if selected == nil { select(model.calendar.current) }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(height: 13)
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(Theme.serifSmallFont)
                .foregroundStyle(Theme.text)
            Spacer()
            IconButton(systemName: "arrow.clockwise", help: "Refresh calendar") { model.calendar.refresh() }
            IconButton(systemName: "macwindow", help: "Open Verbatim") { closingMenu { model.windows.showMain() } }
            IconButton(systemName: "gearshape", help: "Settings") { closingMenu { model.windows.showSettings() } }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 46)
    }

    private var footer: some View {
        HStack {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.captionFont).foregroundStyle(Theme.warning).lineLimit(1)
            } else {
                Text(model.settings.engine.label).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.v(.ghost, .small))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: Active

    private func activeSession(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RecordingDot(size: 7, active: session.phase == .recording && !session.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.transcript.recording.meeting.title)
                        .font(Theme.bodyFont.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(session.elapsed.shortClockString) · \(session.isPaused ? "Paused" : LanguageOption.label(for: session.language))")
                            .font(Theme.monoSmallFont).foregroundStyle(Theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                WaveformView(levels: session.levelHistory, color: Theme.textSecondary, barWidth: 2, spacing: 1.5)
                    .frame(width: 64, height: 22)
            }
            HStack(spacing: 8) {
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.v(.danger, .small))
                Button {
                    session.togglePause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.v(.secondary, .small))
                .disabled(session.phase != .recording)
                Button("Transcript") {
                    closingMenu {
                        model.selectedRecordingID = session.recordingID
                        model.windows.showMain()
                    }
                }
                .buttonStyle(.v(.secondary, .small))
                .help("Open the live transcript")
                Spacer()
            }
        }
        .padding(14)
        .raisedPill(cornerRadius: Theme.radiusLarge)
        .padding(10)
    }

    // MARK: Picker

    private var meetingPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.calendar.isConnected {
                calendarPrompt
            } else {
                let meetings = model.calendar.upcoming
                if model.calendar.looksDisconnected {
                    CalendarConnectHint(model: model).padding(12)
                }
                if meetings.isEmpty {
                    Text("No more meetings today or tomorrow.")
                        .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                        .padding(14)
                } else {
                    // A ScrollView has no height of its own inside the menu bar
                    // window and collapses to zero; size it to its rows (capped).
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groups(meetings), id: \.0) { day, items in
                                SectionLabel(day).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                                ForEach(items, id: \.self) { m in
                                    MeetingRow(meeting: m, isSelected: selected == m, isNow: isNow(m), selectionSpace: selectionSpace) {
                                        select(m)
                                    } onRecord: {
                                        select(m)
                                        model.startRecording(meeting: m, language: language)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: min(max(listHeight, 44), 300))
                }
            }
            Hairline()
            startBar
        }
    }

    private var calendarPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Google Calendar").font(Theme.bodyFont.weight(.semibold)).foregroundStyle(Theme.text)
            Text("Pick meetings from your calendar with their attendees and video links. You can still record without one.")
                .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.calendar.google.hasClient ? "Sign in with Google" : "Set up Google Calendar") { model.connectCalendar() }
                .buttonStyle(.vSecondary)
            if let error = model.calendar.google.lastError {
                Text(error).font(Theme.captionFont).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var startBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $language) {
                    ForEach(LanguageOption.all) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 150)
                Spacer()
                Text("Online or in person: automatic")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 8) {
                Button {
                    model.startRecording(meeting: selected ?? .adHoc(), language: language)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                        Text(selected == nil ? "Start untitled recording" : "Transcribe \u{201C}\(selected!.title)\u{201D}")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vPrimary)
                .keyboardShortcut(.defaultAction)
                if selected != nil {
                    IconButton(systemName: "xmark", help: "Record without a calendar event") { select(nil) }
                }
            }
        }
        .padding(12)
    }

    // MARK: Helpers

    /// Opening a window from the menu closes the menu first, so the window
    /// comes up in front with focus instead of under the open panel.
    private func closingMenu(_ open: @escaping () -> Void) {
        // Toggle it shut through its own status item (closing the window
        // directly leaves the menu thinking it is open, and the next click
        // on the icon would do nothing).
        let statusButton = NSApp.windows
            .first { String(describing: type(of: $0)).contains("StatusBar") }?
            .contentView.flatMap { Self.statusButton(in: $0) }
        statusButton?.performClick(nil)
        Task { open() } // next turn of the main actor, after the menu has closed
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let button = statusButton(in: sub) { return button } }
        return nil
    }

    private func select(_ meeting: MeetingInfo?) {
        withAnimation(Theme.Motion.snappy(reduceMotion)) { selected = meeting }
    }

    private func isNow(_ m: MeetingInfo) -> Bool {
        guard let s = m.scheduledStart, let e = m.scheduledEnd else { return false }
        return s.addingTimeInterval(-5 * 60) <= .now && .now < e
    }

    private func groups(_ meetings: [MeetingInfo]) -> [(String, [MeetingInfo])] {
        var out: [(String, [MeetingInfo])] = []
        for m in meetings {
            let label = isNow(m) ? "Now" : (m.scheduledStart ?? .now).dayLabel
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(m) } else { out.append((label, [m])) }
        }
        return out
    }
}

private struct MeetingRow: View {
    let meeting: MeetingInfo
    let isSelected: Bool
    let isNow: Bool
    var selectionSpace: Namespace.ID?
    let action: () -> Void
    let onRecord: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(meeting.scheduledStart?.timeString ?? "")
                    Text(meeting.scheduledEnd?.timeString ?? "").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.monoSmallFont)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 58, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(meeting.title)
                            .font(Theme.smallFont.weight(.medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if isNow && !(hovering || isSelected) { Pill(text: "Now", color: Theme.recording) }
                    }
                    HStack(spacing: 6) {
                        if let provider = meeting.conferenceProvider {
                            Label(provider.label, systemImage: "video").labelStyle(.titleAndIcon)
                        }
                        let others = meeting.attendees.filter { !$0.isSelf }.count
                        if others > 0 { Label("\(others)", systemImage: "person.2") }
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if hovering || isSelected {
                    Button(action: onRecord) {
                        Label("Record", systemImage: "mic")
                    }
                    .buttonStyle(.v(isSelected ? .primary : .secondary, .small))
                    .help("Start transcribing this meeting")
                    .transition(.opacity.combined(with: .offset(x: 8)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    SelectionPill(space: selectionSpace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.surfaceHover.opacity(0.7))
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
    }
}
