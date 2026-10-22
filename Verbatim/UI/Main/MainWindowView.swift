import AppKit
import SwiftUI

/// Sidebar of "tabs" (Today, the live recording, recent transcripts) over a
/// paper content pane, after the Dia browser. ⌘K opens the command bar.
struct MainWindowView: View {
    let model: AppModel
    @State private var commandBar = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, openCommandBar: { commandBar = true })
                .frame(width: 244)
                .background(SidebarBackground())
            Hairline(vertical: true)
            Group {
                if let id = model.selectedRecordingID, model.recording(id) != nil {
                    RecordingDetailView(model: model, recordingID: id)
                        .id(id)
                } else {
                    TodayView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .overlay(alignment: .bottomTrailing) {
            ToastStack(center: model.toasts)
        }
        .overlay {
            if commandBar {
                CommandBar(model: model, isPresented: $commandBar)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: commandBar)
        .background {
            Button("Command bar") { commandBar.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        }
        // Sidebar and content run up under the transparent title bar, so the
        // traffic lights sit on the sidebar instead of a separate strip.
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            if model.selectedRecordingID == nil, let live = model.session, live.isActive {
                model.selectedRecordingID = live.recordingID
            }
        }
    }
}

/// Warm paper over behind-window vibrancy: the same family as the content
/// pane, with a little of the desktop showing through.
struct SidebarBackground: View {
    var body: some View {
        GlassBackground(material: .sidebar, tint: Theme.sidebar, opacity: 0.74)
    }
}

/// Frosted paper: the theme colour laid over system vibrancy at `opacity`,
/// so surfaces stay warm and legible while hinting at what is behind them.
/// `.behindWindow` shows the desktop (menu, capsule, sidebar);
/// `.withinWindow` blurs the window's own content (toasts, command bar).
struct GlassBackground: View {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var tint: Color = Theme.bg
    var opacity: Double = 0.74

    var body: some View {
        ZStack {
            VisualEffect(material: material, blending: blending)
            tint.opacity(opacity)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active // keep the frost when the window isn't key (menu, capsule)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    let model: AppModel
    let openCommandBar: () -> Void
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights in the transparent title bar.
            Color.clear.frame(height: 38)
            Button(action: openCommandBar) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    Text("Search")
                    Spacer()
                    Text("⌘K").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.smallFont)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search transcripts and start recordings (⌘K)")
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarItem(isSelected: model.selectedRecordingID == nil, selectionSpace: selectionSpace) {
                        model.selectedRecordingID = nil
                    } content: {
                        Label("Today", systemImage: "sun.max")
                            .font(Theme.bodyFont.weight(.medium))
                            .foregroundStyle(Theme.text)
                    }
                    if let session = model.session, session.isActive {
                        SidebarItem(isSelected: model.selectedRecordingID == session.recordingID, selectionSpace: selectionSpace) {
                            model.selectedRecordingID = session.recordingID
                        } content: {
                            LiveItem(session: session)
                        }
                    }
                    ForEach(grouped, id: \.0) { day, items in
                        SectionLabel(day).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                        ForEach(items) { rec in
                            SidebarItem(isSelected: model.selectedRecordingID == rec.id, selectionSpace: selectionSpace) {
                                model.selectedRecordingID = rec.id
                            } content: {
                                RecordingItem(recording: rec)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { model.deleteRecording(rec.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(Theme.Motion.snappy(reduceMotion), value: model.selectedRecordingID)
            }

            HStack(spacing: 4) {
                Button { model.startRecording(meeting: .adHoc()) } label: {
                    Label("New recording", systemImage: "plus")
                        .font(Theme.smallFont.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isRecording)
                .help("Record without a calendar event (⌥⌘R)")
                IconButton(systemName: "gearshape", help: "Settings") { model.windows.showSettings() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var grouped: [(String, [Recording])] {
        let live = model.session?.isActive == true ? model.session?.recordingID : nil
        var out: [(String, [Recording])] = []
        for rec in model.store.recordings where rec.id != live {
            let label = rec.startedAt.dayLabel
            if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(rec) } else { out.append((label, [rec])) }
        }
        return out
    }
}

/// A sidebar row; the selected one is a raised white pill, like a Dia tab.
struct SidebarItem<Content: View>: View {
    let isSelected: Bool
    /// Shared by the items of one list, so the selection pill slides from
    /// the old item to the new one (like a segmented control) instead of jumping.
    var selectionSpace: Namespace.ID?
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
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

/// The raised white pill that marks the selected row; with a namespace it
/// glides between rows.
struct SelectionPill: View {
    var space: Namespace.ID?
    var cornerRadius: CGFloat = Theme.radius

    var body: some View {
        if let space {
            Color.clear.raisedPill(cornerRadius: cornerRadius)
                .matchedGeometryEffect(id: "selection", in: space)
        } else {
            Color.clear.raisedPill(cornerRadius: cornerRadius)
        }
    }
}

private struct RecordingItem: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.meeting.title)
                .font(Theme.smallFont.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(recording.startedAt.timeString)
                Text("·")
                Text(recording.duration.shortClockString).monospacedDigit()
                Spacer(minLength: 0)
                if recording.notionPageURL != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).help("Saved to Notion")
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct LiveItem: View {
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 8) {
            RecordingDot(size: 6, active: !session.isPaused)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.transcript.recording.meeting.title)
                    .font(Theme.smallFont.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(session.isPaused ? "Paused · \(session.elapsed.shortClockString)" : session.elapsed.shortClockString)
                        .font(Theme.monoSmallFont)
                        .foregroundStyle(Theme.recording)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

// MARK: Command bar

/// ⌘K: one box to start or stop a recording, record a meeting from today,
/// or find any transcript by title, speaker or what was said.
struct CommandBar: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        var detail: String?
        let run: () -> Void
    }

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField("Search transcripts or type a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { run(items) }
                        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onExitCommand { isPresented = false }
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                if !items.isEmpty {
                    Hairline()
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button { selection = index; run(items) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.icon).frame(width: 18).foregroundStyle(Theme.textSecondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title).font(Theme.bodyFont).foregroundStyle(Theme.text).lineLimit(1)
                                            if let detail = item.detail {
                                                Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if index == selection { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(index == selection ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    // A ScrollView has no height of its own; fit it to the results (capped).
                    .frame(height: min(max(listHeight, 44), 340))
                }
            }
            .frame(width: 560)
            .raisedGlass(cornerRadius: Theme.radiusLarge)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
            .opacity(appeared ? 1 : 0)
            .padding(.top, 72)
        }
        .onAppear {
            focused = true
            withAnimation(Theme.Motion.gentle(reduceMotion)) { appeared = true }
        }
        .onChange(of: query) { selection = 0 }
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        isPresented = false
        items[selection].run()
    }

    private var items: [Item] {
        let q = query.trimmed.lowercased()
        var out: [Item] = []
        func matches(_ text: String) -> Bool { q.isEmpty || text.lowercased().contains(q) }
        if model.isRecording {
            if matches("stop recording") { out.append(Item(id: "stop", icon: "stop.circle", title: "Stop recording") { model.stopRecording() }) }
        } else {
            if let now = model.calendar.current, matches("record \(now.title)") {
                out.append(Item(id: "now", icon: "record.circle", title: "Record \u{201C}\(now.title)\u{201D}", detail: "Happening now") {
                    model.startRecording(meeting: now)
                })
            }
            if matches("new recording") {
                out.append(Item(id: "new", icon: "plus.circle", title: "New recording", detail: "Without a calendar event") {
                    model.startRecording(meeting: .adHoc())
                })
            }
            for meeting in model.calendar.upcoming where meeting != model.calendar.current && !q.isEmpty && matches(meeting.title) {
                out.append(Item(id: "meet-\(meeting.calendarEventID ?? meeting.title)", icon: "calendar", title: "Record \u{201C}\(meeting.title)\u{201D}",
                                detail: meeting.scheduledStart.map { "\($0.dayLabel) \($0.timeString)" }) {
                    model.startRecording(meeting: meeting)
                })
            }
        }
        if matches("today") { out.append(Item(id: "today", icon: "sun.max", title: "Today") { model.selectedRecordingID = nil }) }
        for rec in model.store.recordings {
            let snippet = q.isEmpty ? nil : rec.visibleSegments.first { $0.text.lowercased().contains(q) }?.text
            guard q.isEmpty || matches(rec.meeting.title) || snippet != nil || rec.speakers.contains(where: { matches($0.name) }) else { continue }
            out.append(Item(id: rec.id.uuidString, icon: "text.alignleft", title: rec.meeting.title,
                            detail: snippet.map { "\u{201C}\($0)\u{201D}" } ?? "\(rec.startedAt.dayLabel) \(rec.startedAt.timeString) · \(rec.duration.shortClockString)") {
                model.selectedRecordingID = rec.id
            })
            if out.count >= 30 { break }
        }
        if matches("settings") { out.append(Item(id: "settings", icon: "gearshape", title: "Settings") { model.windows.showSettings() }) }
        return out
    }
}
