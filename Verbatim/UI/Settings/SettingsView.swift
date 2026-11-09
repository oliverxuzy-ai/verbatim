import AVFAudio
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel
    private var section: Section { model.settingsSection }
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case transcription = "Transcription"
        case speakers = "Speakers"
        case calendar = "Calendar"
        case export = "Export"
        case permissions = "Permissions"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape.fill"
            case .transcription: "waveform"
            case .speakers: "person.2.fill"
            case .calendar: "calendar"
            case .export: "square.and.arrow.up.fill"
            case .permissions: "lock.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: Color(nsColor: .systemGray)
            case .transcription: Color(nsColor: .systemBlue)
            case .speakers: Color(nsColor: .systemPurple)
            case .calendar: Color(nsColor: .systemRed)
            case .export: Color(nsColor: .systemGreen)
            case .permissions: Color(nsColor: .systemIndigo)
            }
        }

        var subtitle: String {
            switch self {
            case .general: "You, startup, updates and where recordings are kept."
            case .transcription: "Which engine turns speech into text, and in what language."
            case .speakers: "Telling voices apart and putting names on them."
            case .calendar: "Your meetings, and recording that starts and stops on its own."
            case .export: "Where finished transcripts go."
            case .permissions: "What macOS has to allow before Verbatim can listen."
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Hairline(vertical: true)
            VStack(spacing: 0) {
                Color.clear.frame(height: 28) // below the title bar, like the main window
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SettingsPageHeader(section: section)
                        switch section {
                        case .general: GeneralSettings(model: model)
                        case .transcription: TranscriptionSettings(model: model)
                        case .speakers: SpeakerSettings(model: model)
                        case .calendar: CalendarSettings(model: model)
                        case .export: ExportSettings(model: model)
                        case .permissions: PermissionSettings(model: model)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(section) // each page opens at the top
            }
            .background(Theme.bg)
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { s in
                let attention = attentionNote(s)
                Button { model.settingsSection = s } label: {
                    HStack(spacing: 9) {
                        SettingsIcon(systemName: s.icon, tint: s.tint)
                        Text(s.rawValue)
                            .font(Theme.bodyFont.weight(section == s ? .medium : .regular))
                            .foregroundStyle(section == s ? Theme.text : Theme.textSecondary)
                        Spacer(minLength: 0)
                        if attention != nil {
                            Circle().fill(Theme.warning).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 32)
                    .background {
                        if section == s { SelectionPill(space: selectionSpace) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(attention ?? "")
            }
            Spacer()
        }
        .animation(Theme.Motion.snappy(reduceMotion), value: model.settingsSection)
        .padding(10)
        .padding(.top, 34) // below the traffic lights
        .frame(width: 190)
        .background(SidebarBackground())
    }

    /// A short reason when a page has something that stops a feature from
    /// working (shown as a dot in the sidebar), or nil.
    private func attentionNote(_ s: Section) -> String? {
        let settings = model.settings
        switch s {
        case .transcription where settings.engine == .soniox && !settings.hasSonioxKey:
            return "Soniox needs an API key."
        case .speakers where settings.claudeNaming && !settings.hasAnthropicKey:
            return "Suggesting names with Claude needs an Anthropic API key."
        case .permissions where !MicCapture.permissionGranted:
            return "Microphone access is off."
        default:
            return nil
        }
    }
}

// MARK: Building blocks

/// A white symbol on a coloured rounded square, like System Settings.
struct SettingsIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

private struct SettingsPageHeader: View {
    let section: SettingsView.Section

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: section.icon, tint: section.tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue).font(Theme.serifTitleFont).foregroundStyle(Theme.text)
                Text(section.subtitle).font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.bottom, 2)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    /// false lays the content out without the shared card, for content that
    /// brings its own (the engine cards).
    var boxed = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.leading, 2)
            if boxed {
                VStack(alignment: .leading, spacing: 0) { content }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            } else {
                content
            }
            if let footnote {
                Text(footnote).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var icon: String?
    var showDivider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.bodyFont).foregroundStyle(Theme.text)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            if showDivider { Hairline().padding(.leading, icon == nil ? 14 : 46) }
        }
    }
}

/// A connected service (Notion, and later others) on the Export page: a
/// header with its mark and whether it is set up, then its settings rows.
struct IntegrationCard<Content: View>: View {
    let name: String
    let letter: String
    let summary: String
    let connected: Bool
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(letter)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.hairline))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(Theme.headingFont).foregroundStyle(Theme.text)
                        Text(summary).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Pill(text: connected ? "Connected" : "Not set up",
                         color: connected ? Theme.success : Theme.textSecondary,
                         systemImage: connected ? "checkmark" : nil)
                }
                .padding(14)
                Hairline()
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            if let footnote {
                Text(footnote).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SecretField: View {
    let placeholder: String
    let isSet: Bool
    let onSave: (String?) -> Void
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            if isSet && !editing {
                Label("Saved", systemImage: "checkmark.seal.fill")
                    .font(Theme.smallFont).foregroundStyle(Theme.success)
                Button("Replace") { editing = true }.buttonStyle(.v(.secondary, .small))
                Button("Remove") { onSave(nil) }.buttonStyle(.v(.ghost, .small))
            } else {
                SecureField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .onSubmit(save)
                Button("Save", action: save).buttonStyle(.v(.primary, .small)).disabled(draft.trimmed.isEmpty)
            }
        }
    }

    private func save() {
        guard !draft.trimmed.isEmpty else { return }
        onSave(draft)
        draft = ""
        editing = false
    }
}

private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 2)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.hairline))
            }
        }
    }
}

private struct StatusIcon: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(ok ? Theme.success : Theme.warning)
    }
}

// MARK: General

private struct GeneralSettings: View {
    let model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "You") {
            SettingsRow(title: "Your name", detail: "Labels your own lines (the microphone) in transcripts.", showDivider: false) {
                TextField("Name", text: $settings.myName).textFieldStyle(.roundedBorder).frame(width: 190)
            }
        }
        SettingsGroup(title: "App") {
            SettingsRow(title: "Open at login") {
                Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            SettingsRow(title: "Show in Dock", detail: "Handy when the notch hides the menu bar icon.") {
                Toggle("", isOn: Binding(get: { model.settings.showInDock }, set: { on in
                    model.settings.showInDock = on
                    NSApp.setActivationPolicy(on ? .regular : .accessory)
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Start or stop recording", detail: "Works from any app.", showDivider: false) {
                KeyCaps(keys: ["⌥", "⌘", "R"])
            }
        }
        UpdateSettings(model: model)
        SettingsGroup(title: "Storage") {
            SettingsRow(title: "Recordings folder",
                        detail: (model.store.rootURL.path as NSString).abbreviatingWithTildeInPath,
                        showDivider: false) {
                Button("Show in Finder") { NSWorkspace.shared.open(model.store.rootURL) }.buttonStyle(.v(.secondary, .small))
            }
        }
    }
}

private struct UpdateSettings: View {
    let model: AppModel

    var body: some View {
        let updater = model.updater
        SettingsGroup(title: "Updates", footnote: footnote) {
            SettingsRow(title: "Verbatim \(updater.current)", detail: status) {
                switch updater.state {
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                case .ready:
                    Button("Restart to update") { updater.act() }.buttonStyle(.v(.primary, .small))
                        .disabled(model.isRecording)
                case .available:
                    Button(updater.canInstall ? "Download" : "Get it on GitHub") { updater.act() }.buttonStyle(.v(.primary, .small))
                case .idle, .upToDate, .failed:
                    Button("Check now") { updater.act() }.buttonStyle(.v(.secondary, .small))
                }
            }
            SettingsRow(title: "Install updates automatically",
                        detail: "Downloads new versions in the background and restarts when you aren't recording or using Verbatim.",
                        showDivider: false) {
                Toggle("", isOn: Binding(get: { model.settings.autoUpdate }, set: { on in
                    model.settings.autoUpdate = on
                    if on { Task { await updater.tick() } }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var status: String {
        let updater = model.updater
        switch updater.state {
        case .idle:
            if let checked = updater.lastChecked { return "Last checked \(checked.formatted(.relative(presentation: .named)))." }
            return "Not checked yet."
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're on the latest version."
        case let .available(u):
            return updater.canInstall ? "Version \(u.version) is available." : "Version \(u.version) is available. Download it and drag it into Applications."
        case let .downloading(u): return "Downloading version \(u.version)…"
        case let .ready(u):
            return model.isRecording ? "Version \(u.version) is ready. It installs after this recording." : "Version \(u.version) is ready to install."
        case let .installing(u): return "Installing version \(u.version)…"
        case let .failed(message): return message
        }
    }

    private var footnote: String? {
        model.updater.canInstall ? nil
            : "Verbatim can only update itself when it runs from the Applications folder. Move it there to get updates automatically."
    }
}

// MARK: Transcription

private extension EngineKind {
    var icon: String {
        switch self {
        case .apple: "laptopcomputer"
        case .soniox: "cloud"
        }
    }

    var highlights: [String] {
        switch self {
        case .apple: ["Free, runs on this Mac", "Audio never leaves your Mac", "One language per meeting"]
        case .soniox: ["Most accurate", "Chinese and English mixed", "About $0.12 per audio hour per channel"]
        }
    }
}

private struct EngineCard: View {
    let kind: EngineKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: kind.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                }
                Text(kind.label).font(Theme.bodyFont.weight(.semibold)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(kind.highlights, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.accentSoft : (hovering ? Theme.surfaceRaised : Theme.surface), in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : Theme.hairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
        .animation(Theme.Motion.quick, value: selected)
    }
}

private struct TranscriptionSettings: View {
    let model: AppModel
    @State private var modelStatus: String = ""
    @State private var modelInstalled = false
    @State private var downloading = false
    @State private var progress: Double = 0

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "Engine", boxed: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(EngineKind.allCases) { kind in
                    EngineCard(kind: kind, selected: settings.engine == kind) { settings.engine = kind }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        if settings.engine == .soniox {
            SettingsGroup(title: "Soniox", footnote: "Get a key at console.soniox.com. Each meeting streams two channels (you and the others), billed per audio hour.") {
                SettingsRow(title: "API key", detail: settings.hasSonioxKey ? nil : "Needed to transcribe with Soniox.", showDivider: false) {
                    SecretField(placeholder: "Soniox API key", isSet: settings.hasSonioxKey) { settings.setSonioxKey($0) }
                }
            }
        }

        SettingsGroup(title: "Language") {
            SettingsRow(title: "Meeting language",
                        detail: settings.engine == .apple && settings.language == "mixed"
                            ? "Apple's model handles one language at a time, so mixed meetings use Mandarin. Soniox handles mixing natively." : nil,
                        showDivider: settings.engine == .apple) {
                Picker("", selection: $settings.language) {
                    ForEach(LanguageOption.all) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().frame(width: 170)
            }
            if settings.engine == .apple {
                SettingsRow(title: "On-device speech model", detail: modelStatus, showDivider: false) {
                    if downloading {
                        ProgressView(value: progress).frame(width: 120)
                    } else if modelInstalled {
                        StatusIcon(ok: true)
                    } else {
                        Button("Download") { download(settings.language) }.buttonStyle(.v(.secondary, .small))
                    }
                }
            }
        }
        .task(id: settings.language) { await refreshModelStatus(settings.language) }

        SettingsGroup(title: "Microphone") {
            SettingsRow(title: "Echo cancellation", detail: "When you use the Mac's speakers, removes the other side's voice from your mic so it isn't transcribed twice.", showDivider: false) {
                Toggle("", isOn: $settings.echoCancellation).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsGroup(title: "Custom vocabulary", footnote: "Names, products and jargon, separated by commas or new lines. Attendee names and the meeting title are added automatically.") {
            TextEditor(text: $settings.vocabulary)
                .font(Theme.bodyFont)
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(10)
        }
    }

    private func refreshModelStatus(_ language: String) async {
        let installed = await AppleSpeechTranscriber.isLanguageInstalled(language)
        modelInstalled = installed
        modelStatus = installed ? "Installed for \(LanguageOption.label(for: language))." : "Not downloaded yet for \(LanguageOption.label(for: language)). It downloads on first use."
    }

    private func download(_ language: String) {
        downloading = true
        progress = 0
        Task {
            do {
                try await AppleSpeechTranscriber.prepareLanguage(language) { p in
                    Task { @MainActor in progress = p }
                }
            } catch {
                modelStatus = error.localizedDescription
            }
            downloading = false
            await refreshModelStatus(language)
        }
    }
}

// MARK: Speakers

private struct SpeakerSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "Telling voices apart") {
            SettingsRow(title: "Separate speakers live",
                        detail: settings.engine == .apple
                            ? "Labels voices while you record, with an on-device model."
                            : "Soniox separates speakers itself.") {
                Toggle("", isOn: $settings.liveDiarization).labelsHidden().toggleStyle(.switch)
                    .disabled(settings.engine != .apple)
            }
            SettingsRow(title: "Refine after each meeting",
                        detail: "Re-groups voices over the whole recording (and, with Apple, re-transcribes with full context). About 20 seconds per hour of audio. Names you set are kept.",
                        showDivider: false) {
                Toggle("", isOn: $settings.autoRefine).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsGroup(title: "Names",
                      footnote: "Verbatim tries your voiceprint library first, then the calendar invite, then Claude. Claude's guesses show a question mark until you confirm them. With Claude on, the transcript is sent to Anthropic.") {
            SettingsRow(title: "Suggest names with Claude",
                        detail: "Uses Claude Opus 5.5. Only names on the invite or said in the meeting are accepted.",
                        showDivider: settings.claudeNaming) {
                Toggle("", isOn: $settings.claudeNaming).labelsHidden().toggleStyle(.switch)
            }
            if settings.claudeNaming {
                SettingsRow(title: "Anthropic API key", detail: settings.hasAnthropicKey ? nil : "Needed for name suggestions.", showDivider: false) {
                    SecretField(placeholder: "sk-ant-…", isSet: settings.hasAnthropicKey) { settings.setAnthropicKey($0) }
                }
            }
        }
    }
}

// MARK: Calendar

private struct CalendarSettings: View {
    let model: AppModel

    var body: some View {
        let cal = model.calendar
        GoogleCalendarSettings(model: model)
        if !cal.google.isSignedIn, cal.access == .granted {
            macOSAccess
        }
        automaticRecording
        if !cal.google.isSignedIn, cal.access == .granted {
            calendarsToShow
        }
    }

    private var macOSAccess: some View {
        let cal = model.calendar
        return SettingsGroup(title: "macOS Calendar", footnote: "Used until you sign in to Google above.") {
            SettingsRow(title: "Calendar access", detail: accessText(cal.access), showDivider: false) {
                if cal.access != .granted {
                    Button(cal.access == .denied ? "Open Settings" : "Allow") {
                        if cal.access == .denied {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        } else {
                            Task { await cal.requestAccess() }
                        }
                    }
                    .buttonStyle(.v(.secondary, .small))
                } else {
                    Button("Refresh") { cal.refresh() }.buttonStyle(.v(.secondary, .small))
                }
            }
        }
    }

    private var automaticRecording: some View {
        SettingsGroup(title: "Automatic recording") {
            SettingsRow(title: "Notify when a meeting starts", detail: "With a Transcribe button, for meetings with other people or a video link.") {
                Toggle("", isOn: Binding(get: { model.settings.meetingReminders }, set: { on in
                    model.settings.meetingReminders = on
                    if on { Task { _ = await MeetingReminder.requestPermission() } }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Start for video meetings", detail: "Begins when a meeting with a Meet, Zoom or Teams link starts. The capsule appears so you can stop it.") {
                Toggle("", isOn: Binding(get: { model.settings.autoStartVideoMeetings }, set: { model.settings.autoStartVideoMeetings = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Stop when the meeting ends", detail: "After 3 quiet minutes on the call, or 10 with nobody speaking. You get a 1-minute warning with a Keep recording button first.", showDivider: false) {
                Toggle("", isOn: Binding(get: { model.settings.autoStopWhenMeetingEnds }, set: { on in
                    model.settings.autoStopWhenMeetingEnds = on
                    if on { Task { _ = await MeetingReminder.requestPermission() } }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var calendarsToShow: some View {
        let cal = model.calendar
        return SettingsGroup(title: "Calendars to show") {
            ForEach(cal.calendars) { c in
                SettingsRow(title: c.title, detail: c.account, showDivider: c != cal.calendars.last) {
                    Toggle("", isOn: Binding(
                        get: { !model.settings.hiddenCalendarIDs.contains(c.id) },
                        set: { on in
                            var hidden = Set(model.settings.hiddenCalendarIDs)
                            if on { hidden.remove(c.id) } else { hidden.insert(c.id) }
                            model.settings.hiddenCalendarIDs = Array(hidden)
                            cal.hiddenCalendarIDs = hidden
                            cal.refresh()
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private func accessText(_ a: CalendarService.Access) -> String {
        switch a {
        case .granted: "Allowed. \(model.calendar.events.count) meetings in the next few days."
        case .denied: "Denied. Turn it on in System Settings → Privacy & Security → Calendars."
        case .unknown: "Not requested yet."
        }
    }
}

/// Direct Google Calendar connection: the user's own OAuth client, then
/// sign-in in the browser. Read-only access to the primary calendar.
private struct GoogleCalendarSettings: View {
    let model: AppModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    /// nil until the user opens or closes the guide; until then it is open
    /// only while there is no OAuth client yet.
    @State private var showGuide: Bool?

    var body: some View {
        let cal = model.calendar
        let google = cal.google
        SettingsGroup(title: "Google Calendar", footnote: "Read-only: titles, times, attendees and video links from your primary calendar, through your own OAuth client. Nothing goes through a third party.") {
            switch google.state {
            case let .signedIn(email):
                SettingsRow(title: email.isEmpty ? "Connected" : email,
                            detail: cal.googleError ?? "\(cal.events.count) meetings from yesterday through the day after tomorrow.",
                            icon: "checkmark.circle.fill",
                            showDivider: false) {
                    Button("Refresh") { cal.refresh() }.buttonStyle(.v(.secondary, .small))
                    Button("Disconnect") { Task { await cal.disconnectGoogle() } }.buttonStyle(.v(.ghost, .small))
                }
            case .signingIn:
                SettingsRow(title: "Waiting for Google…", detail: "Finish signing in in your browser, then come back here.", showDivider: false) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { google.cancelSignIn() }.buttonStyle(.v(.ghost, .small))
                }
            case .signedOut:
                SettingsRow(title: "1. OAuth client", detail: google.hasClient ? "Saved." : "Import the JSON from Google Cloud Console, or paste the ID and secret.") {
                    if google.hasClient {
                        StatusIcon(ok: true)
                        Button("Remove") { google.setClient(nil) }.buttonStyle(.v(.ghost, .small))
                    } else {
                        Button("Import JSON…", action: importJSON).buttonStyle(.v(.secondary, .small))
                    }
                }
                if !google.hasClient {
                    SettingsRow(title: "Client ID") {
                        TextField("…apps.googleusercontent.com", text: $clientID).textFieldStyle(.roundedBorder).frame(width: 250)
                    }
                    SettingsRow(title: "Client secret") {
                        SecureField("GOCSPX-…", text: $clientSecret).textFieldStyle(.roundedBorder).frame(width: 170)
                        Button("Save") {
                            google.setClient(GoogleOAuthClient(id: clientID, secret: clientSecret))
                            clientID = ""
                            clientSecret = ""
                        }
                        .buttonStyle(.v(.primary, .small))
                        .disabled(clientID.trimmed.isEmpty || clientSecret.trimmed.isEmpty)
                    }
                }
                SettingsRow(title: "2. Sign in", detail: google.lastError ?? (google.hasClient
                    ? "Opens Google in your browser. Choose the account whose meetings you record."
                    : "Needs the OAuth client first."), showDivider: false) {
                    // Never disabled: without a client, clicking says what's missing.
                    Button("Sign in with Google") { Task { await cal.connectGoogle() } }
                        .buttonStyle(.v(google.hasClient ? .primary : .secondary, .small))
                }
            }
        }
        if !google.isSignedIn { setupGuide(open: showGuide ?? !google.hasClient) }
    }

    private func setupGuide(open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showGuide = !open } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    Text("How to get an OAuth client").font(Theme.bodyFont.weight(.medium)).foregroundStyle(Theme.text)
                    Text("One time, about 10 minutes").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "In Google Cloud Console, create a project (any name, e.g. Verbatim).")
                    step(2, "Enable the Google Calendar API for that project.")
                    step(3, "Google Auth Platform → Branding: app name Verbatim and your email. Audience: External, then Publish app, so sign-in doesn't expire every 7 days.")
                    step(4, "Clients → Create client → Application type Desktop app → Create → Download JSON.")
                    step(5, "Import that JSON above and click Sign in with Google. When Google says the app isn't verified, choose Advanced → Go to Verbatim (it's your own client) and keep the calendar box checked.")
                    HStack(spacing: 8) {
                        Button("Open Google Cloud Console") { openLink("https://console.cloud.google.com/projectcreate") }
                        Button("Enable Calendar API") { openLink("https://console.cloud.google.com/apis/library/calendar-json.googleapis.com") }
                        Button("Create client") { openLink("https://console.cloud.google.com/auth/clients/create") }
                    }
                    .buttonStyle(.v(.secondary, .small))
                    .padding(.top, 4)
                    Text("If your company's Google Workspace blocks unverified apps, ask IT to allow it, or create the project while signed in with your work account and choose Internal in step 3 (no warning, no publishing).")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(14)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.monoSmallFont).foregroundStyle(Theme.textTertiary).frame(width: 14, alignment: .trailing)
            Text(text).font(Theme.smallFont).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openLink(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the client JSON you downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let client = GoogleOAuthClient.parse(json: data) {
            model.calendar.google.setClient(client)
            model.calendar.google.lastError = nil
        } else {
            model.calendar.google.lastError = "That file isn't a Google OAuth client JSON (it should contain client_id and client_secret)."
        }
    }
}

// MARK: Export

/// One card per destination. New destinations get their own card here.
private struct ExportSettings: View {
    let model: AppModel

    var body: some View {
        NotionSettings(model: model)
    }
}

private struct NotionSettings: View {
    let model: AppModel
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = model.settings
        IntegrationCard(name: "Notion", letter: "N",
                        summary: "Saves each transcript as a page in your Meeting Transcripts database.",
                        connected: settings.hasNotionToken,
                        footnote: "Easiest: a personal access token from notion.so/developers (acts as you, no sharing needed). An internal integration token also works if the database is shared with it under ••• → Connections.") {
            SettingsRow(title: "Token") {
                SecretField(placeholder: "ntn_… or secret_…", isSet: settings.hasNotionToken) { settings.setNotionToken($0) }
            }
            SettingsRow(title: "Database", detail: "Set to Meeting Transcripts. To use another, paste its link or ID.") {
                TextField("Data source ID", text: $settings.notionDataSourceID)
                    .textFieldStyle(.roundedBorder).frame(width: 230).font(Theme.monoFont)
            }
            SettingsRow(title: "Test connection", detail: testResult) {
                Button {
                    test()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .buttonStyle(.v(.secondary, .small))
                .disabled(!settings.hasNotionToken || testing)
            }
            SettingsRow(title: "来源 value", detail: "Written to the 来源 select so these pages are easy to filter.") {
                TextField("Verbatim", text: $settings.notionSourceOption).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            SettingsRow(title: "Save automatically when a meeting ends", showDivider: false) {
                Toggle("", isOn: $settings.autoExportOnStop).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func test() {
        guard let token = model.settings.notionToken else { return }
        testing = true
        testResult = nil
        Task {
            let client = NotionClient(token: token)
            do {
                let (dsID, schema) = try await client.dataSourceSchema(model.settings.notionDataSourceID.trimmed)
                let title = (try? await client.dataSourceTitle(dsID)) ?? "Database"
                let expected = [NotionExporter.Prop.title, NotionExporter.Prop.date, NotionExporter.Prop.duration,
                                NotionExporter.Prop.status, NotionExporter.Prop.external]
                let missing = expected.filter { schema[$0] == nil }
                testResult = "Connected to \u{201C}\(title)\u{201D}" + (missing.isEmpty ? ". All properties found." : ". Missing: \(missing.joined(separator: ", ")).")
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: Permissions

struct PermissionSettings: View {
    let model: AppModel
    @State private var micGranted = MicCapture.permissionGranted
    @State private var systemAudioResult: String?
    @State private var testingSystem = false

    var body: some View {
        SettingsGroup(title: "macOS permissions", footnote: "macOS asks for system audio the first time Verbatim records other apps. You can review it in System Settings → Privacy & Security → Screen & System Audio Recording.") {
            SettingsRow(title: "Microphone", detail: micGranted ? "Allowed." : "Needed to transcribe what you say.", icon: "mic.fill") {
                if !micGranted {
                    Button("Allow") { Task { micGranted = await MicCapture.requestPermission() } }
                        .buttonStyle(.v(.primary, .small))
                } else {
                    StatusIcon(ok: true)
                }
            }
            SettingsRow(title: "System audio", detail: systemAudioResult ?? "Needed to transcribe the other participants.", icon: "speaker.wave.2.fill") {
                Button { testSystemAudio() } label: {
                    if testingSystem { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .buttonStyle(.v(.secondary, .small))
                .disabled(testingSystem)
            }
            SettingsRow(title: "Google Calendar", detail: googleDetail, icon: "calendar", showDivider: false) {
                if model.calendar.google.isSignedIn {
                    StatusIcon(ok: true)
                } else if model.calendar.google.state == .signingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.calendar.google.hasClient ? "Sign in" : "Set up") { model.connectCalendar() }
                        .buttonStyle(.v(.secondary, .small))
                }
            }
        }
    }

    private var googleDetail: String {
        if case let .signedIn(email) = model.calendar.google.state { return email.isEmpty ? "Connected." : "Connected as \(email)." }
        return model.calendar.google.hasClient
            ? "Lists your meetings, attendees and video links."
            : "Lists your meetings. One-time setup in Settings → Calendar."
    }

    /// Plays a short system sound from a helper process (our own process is
    /// excluded from the tap) and checks that the tap hears it.
    private func testSystemAudio() {
        testingSystem = true
        systemAudioResult = nil
        Task {
            if SystemAudioPermission.status != .granted { _ = await SystemAudioPermission.request() }
            let heard = await SystemAudioProbe.run()
            let status = SystemAudioPermission.status
            systemAudioResult = heard
                ? "Working: Verbatim can hear other apps."
                : status == .granted
                    ? "Permission is on but no sound arrived. Play something and test again."
                    : "Access is off. Turn on Verbatim under Privacy & Security → Screen & System Audio Recording (if it's already on, switch it off and on), then test again."
            testingSystem = false
        }
    }
}

nonisolated enum SystemAudioProbe {
    static func run() async -> Bool {
        let capture = SystemAudioCapture()
        let peak = Locked<Float>(0)
        do {
            try capture.start { buffer, _ in
                guard let mono = buffer.monoFloat(.average) else { return }
                let db = mono.rmsDecibels()
                peak.withLock { $0 = max($0, db) }
            }
        } catch {
            return false
        }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.4", "/System/Library/Sounds/Glass.aiff"]
        try? await Task.sleep(for: .milliseconds(400))
        try? player.run()
        try? await Task.sleep(for: .seconds(2))
        capture.stop()
        return peak.current > -70
    }
}
