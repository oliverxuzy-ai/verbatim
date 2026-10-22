import SwiftUI

/// Home: the day at a glance, like Dia's morning brief. Today's meetings in
/// order with one-click recording, the live recording on top while it runs.
struct TodayView: View {
    let model: AppModel
    @State private var language = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The scroll view starts below the title bar: content scrolling under
        // the transparent title bar ends up in macOS's scroll-edge layer.
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            content
        }
        .background(Theme.bg)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(Theme.displayFont)
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 3)

                if let session = model.session, session.isActive {
                    LiveCard(model: model, session: session)
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                } else {
                    HStack(spacing: 8) {
                        Button { model.startRecording(meeting: .adHoc(), language: language) } label: {
                            Label("New recording", systemImage: "mic")
                        }
                        .buttonStyle(.vPrimary)
                        .help("Record without a calendar event (⌥⌘R)")
                        Menu {
                            ForEach(LanguageOption.all) { option in
                                Button(option.label) { language = option.id }
                            }
                        } label: {
                            Label(LanguageOption.label(for: language), systemImage: "globe")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.vSecondary)
                        .fixedSize()
                        .help("Meeting language. Online or in person is detected automatically.")
                    }
                    .padding(.top, 20)
                }

                if !model.calendar.isConnected {
                    ConnectCard(model: model).padding(.top, 28)
                } else {
                    if model.calendar.looksDisconnected { CalendarConnectHint(model: model).padding(.top, 20) }
                    section("Today", meetings: today)
                    if today.isEmpty {
                        Text("No more meetings today. Start a recording anytime.")
                            .font(Theme.smallFont).foregroundStyle(Theme.textTertiary)
                            .padding(.top, 10)
                    }
                    section("Tomorrow", meetings: tomorrow)
                }
            }
            .animation(Theme.Motion.gentle(reduceMotion), value: model.isRecording)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if language.isEmpty { language = model.settings.language }
            model.calendar.refresh()
        }
    }

    private var subtitle: String {
        guard model.calendar.isConnected else { return "Connect a calendar to see your meetings here." }
        let count = today.count
        let source = model.calendar.google.isSignedIn ? "Google Calendar" : "macOS Calendar"
        return count == 0 ? "Nothing else on the calendar today · \(source)" : "\(count) meeting\(count == 1 ? "" : "s") today · \(source)"
    }

    private var today: [MeetingInfo] { model.calendar.upcoming.filter { ($0.scheduledStart ?? .now) < Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400) } }
    private var tomorrow: [MeetingInfo] { model.calendar.upcoming.filter { !today.contains($0) } }

    @ViewBuilder
    private func section(_ title: String, meetings: [MeetingInfo]) -> some View {
        if !meetings.isEmpty {
            SectionLabel(title).padding(.top, 30).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element) { index, meeting in
                    MeetingLine(model: model, meeting: meeting, language: language, index: index)
                    if meeting != meetings.last { Hairline() }
                }
            }
        }
    }
}

private struct MeetingLine: View {
    let model: AppModel
    let meeting: MeetingInfo
    let language: String
    /// Position in its list: rows fade up one after another on appear.
    let index: Int
    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isNow = model.calendar.current == meeting
        let recorded = model.store.recordings.first { $0.meeting.calendarEventID != nil && $0.meeting.calendarEventID == meeting.calendarEventID }
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(meeting.scheduledStart?.timeString ?? "")
                Text(meeting.scheduledEnd?.timeString ?? "").foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.monoSmallFont)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 62, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(meeting.title).font(Theme.bodyFont.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if isNow { Pill(text: "Now", color: Theme.recording) }
                }
                HStack(spacing: 6) {
                    let others = meeting.attendees.filter { !$0.isSelf }
                    if !others.isEmpty {
                        // Overlapping avatars fan out while the row is hovered.
                        HStack(spacing: hovering && !reduceMotion ? 3 : -5) {
                            ForEach(Array(others.prefix(4).enumerated()), id: \.offset) { index, person in
                                Avatar(name: person.displayName, colorIndex: index + 1, size: 18)
                                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                                    .help(person.displayName)
                            }
                        }
                        .animation(Theme.Motion.snappy(reduceMotion), value: hovering)
                    }
                    Text(detail(others: others.count))
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let recorded {
                Button { model.selectedRecordingID = recorded.id } label: { Label("Transcript", systemImage: "text.alignleft") }
                    .buttonStyle(.v(.secondary, .small))
            } else if !model.isRecording && (isNow || hovering) {
                // The meeting happening now always offers Record; the others on hover.
                Button { model.startRecording(meeting: meeting, language: language) } label: { Label("Record", systemImage: "mic") }
                    .buttonStyle(.v(isNow ? .primary : .secondary, .small))
                    .help("Start transcribing this meeting")
                    .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(hovering ? Theme.surfaceHover.opacity(0.55) : .clear)
        )
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy(reduceMotion), value: hovering)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .onAppear {
            withAnimation(Theme.Motion.gentle(reduceMotion).delay(reduceMotion ? 0 : Double(index) * 0.045)) { appeared = true }
        }
    }

    private func detail(others: Int) -> String {
        var parts: [String] = []
        if let provider = meeting.conferenceProvider { parts.append(provider.label) }
        if others > 0 { parts.append(others == 1 ? "1 other" : "\(others) others") }
        return parts.isEmpty ? "No attendees" : parts.joined(separator: " · ")
    }
}

/// The meeting being recorded, with its controls, at the top of Today.
private struct LiveCard: View {
    let model: AppModel
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 14) {
            RecordingDot(size: 7, active: !session.isPaused)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.transcript.recording.meeting.title)
                    .font(Theme.serifSmallFont).foregroundStyle(Theme.text).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(session.isPaused ? "Paused · \(session.elapsed.shortClockString)" : "Recording · \(session.elapsed.shortClockString)")
                        .font(Theme.monoSmallFont).foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer()
            WaveformView(levels: session.levelHistory, color: Theme.textSecondary, barWidth: 2, spacing: 1.5)
                .frame(width: 70, height: 22)
            Button("Open") { model.selectedRecordingID = session.recordingID }.buttonStyle(.v(.secondary, .small))
            Button { model.stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.v(.danger, .small))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .raisedPill(cornerRadius: Theme.radiusLarge)
    }
}

private struct ConnectCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Google Calendar").font(Theme.serifSmallFont).foregroundStyle(Theme.text)
            Text("Your meetings show up here with attendees and video links, ready to record in one click.")
                .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.calendar.google.hasClient ? "Sign in with Google" : "Set up Google Calendar") { model.connectCalendar() }
                .buttonStyle(.v(.secondary, .small))
                .padding(.top, 4)
            if let error = model.calendar.google.lastError {
                Text(error).font(Theme.captionFont).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedPill(cornerRadius: Theme.radiusLarge)
    }
}

struct CalendarConnectHint: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No meetings found on your calendars")
                .font(Theme.smallFont.weight(.medium)).foregroundStyle(Theme.text)
            Text("Connect Google Calendar directly to see your meetings with attendees and Meet links.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect Google Calendar") { model.connectCalendar() }
                .buttonStyle(.v(.secondary, .small))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}
