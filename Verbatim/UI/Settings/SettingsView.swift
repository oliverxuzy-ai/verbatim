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
        case notion = "Notion"
        case calendar = "Calendar"
        case permissions = "Permissions"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .transcription: "waveform"
            case .notion: "doc.text"
            case .calendar: "calendar"
            case .permissions: "lock.shield"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { s in
                    Button { model.settingsSection = s } label: {
                        Label(s.rawValue, systemImage: s.icon)
                            .font(Theme.smallFont.weight(.medium))
                            .foregroundStyle(section == s ? Theme.text : Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background {
                                if section == s { SelectionPill(space: selectionSpace) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .animation(Theme.Motion.snappy(reduceMotion), value: model.settingsSection)
            .padding(10)
            .padding(.top, 30) // below the traffic lights
            .frame(width: 170)
            .background(SidebarBackground())
            Hairline(vertical: true)
            VStack(spacing: 0) {
            Color.clear.frame(height: 28) // below the title bar, like the main window
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .general: GeneralSettings(model: model)
                    case .transcription: TranscriptionSettings(model: model)
                    case .notion: NotionSettings(model: model)
                    case .calendar: CalendarSettings(model: model)
                    case .permissions: PermissionSettings(model: model)
                    }
                }
                .padding(24)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .background(Theme.bg)
        }
        .ignoresSafeArea()
    }
}

// MARK: Building blocks

struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            if let footnote {
                Text(footnote).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var showDivider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.bodyFont).foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if showDivider { Hairline().padding(.leading, 12) }
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
                    .frame(width: 230)
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

// MARK: Sections

private struct GeneralSettings: View {
    let model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "You") {
            SettingsRow(title: "Your name", detail: "Used for your own lines in transcripts (the microphone channel).", showDivider: false) {
                TextField("Name", text: $settings.myName).textFieldStyle(.roundedBorder).frame(width: 200)
            }
        }
        SettingsGroup(title: "App", footnote: "Start or stop a recording from anywhere with ⌥⌘R.") {
            SettingsRow(title: "Show in Dock", detail: "Click the Dock icon to open Verbatim. Useful when the menu bar icon is hidden by the notch.") {
                Toggle("", isOn: Binding(get: { model.settings.showInDock }, set: { on in
                    model.settings.showInDock = on
                    NSApp.setActivationPolicy(on ? .regular : .accessory)
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Open at login", showDivider: false) {
                Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        SettingsGroup(title: "Storage", footnote: model.store.rootURL.path) {
            SettingsRow(title: "Recordings folder", detail: "Transcripts (JSON) and lossless 16 kHz audio per meeting.", showDivider: false) {
                Button("Show in Finder") { NSWorkspace.shared.open(model.store.rootURL) }.buttonStyle(.v(.secondary, .small))
            }
        }
    }
}

private struct TranscriptionSettings: View {
    let model: AppModel
    @State private var modelStatus: String = ""
    @State private var modelInstalled = false
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var speakerModelStatus = ""

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "Engine") {
            ForEach(EngineKind.allCases) { kind in
                Button { settings.engine = kind } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: settings.engine == kind ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.engine == kind ? Theme.accent : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.label).font(Theme.bodyFont.weight(.medium)).foregroundStyle(Theme.text)
                            Text(kind.detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if kind != EngineKind.allCases.last { Hairline().padding(.leading, 12) }
            }
        }

        if settings.engine == .soniox {
            SettingsGroup(title: "Soniox", footnote: "Create a key at console.soniox.com. Each meeting streams two channels (you and the others), billed per audio hour.") {
                SettingsRow(title: "API key", showDivider: false) {
                    SecretField(placeholder: "Soniox API key", isSet: settings.hasSonioxKey) { settings.setSonioxKey($0) }
                }
            }
        }

        SettingsGroup(title: "Language") {
            SettingsRow(title: "Default language", detail: settings.engine == .apple && settings.language == "mixed"
                        ? "Apple's on-device model is single-language; mixed meetings use the Mandarin model. Soniox handles mixing natively." : nil) {
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    } else {
                        Button("Download") { download(settings.language) }.buttonStyle(.v(.secondary, .small))
                    }
                }
            }
        }
        .task(id: settings.language) { await refreshModelStatus(settings.language) }

        SettingsGroup(title: "Speakers") {
            SettingsRow(title: "Separate speakers live", detail: settings.engine == .apple
                        ? "On-device speaker model (FluidAudio). \(speakerModelStatus)"
                        : "Soniox separates speakers itself.") {
                Toggle("", isOn: $settings.liveDiarization).labelsHidden().toggleStyle(.switch)
                    .disabled(settings.engine != .apple)
            }
            SettingsRow(title: "Refine after each meeting", detail: "Re-clusters speakers over the whole meeting (and, with the Apple engine, re-transcribes with full context). Also decides on its own whether it was an online, in-person or hybrid meeting. About 20 seconds per hour of audio; your speaker names are kept.") {
                Toggle("", isOn: $settings.autoRefine).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Echo cancellation on speakers", detail: "When you're not on headphones, removes the other side's voice from your mic so it isn't transcribed twice.", showDivider: false) {
                Toggle("", isOn: $settings.echoCancellation).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsGroup(title: "Speaker names", footnote: "Order: your voiceprint library, then the calendar invite (1:1s, elimination), then Claude reading the transcript for introductions and names. Claude's guesses are marked with a question mark until you confirm them. The transcript is sent to Anthropic.") {
            SettingsRow(title: "Suggest names with Claude", detail: "Uses Claude Opus 5.5. Only names on the invite or spoken in the meeting are accepted.") {
                Toggle("", isOn: $settings.claudeNaming).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Anthropic API key", showDivider: false) {
                SecretField(placeholder: "sk-ant-…", isSet: settings.hasAnthropicKey) { settings.setAnthropicKey($0) }
            }
        }

        SettingsGroup(title: "Custom vocabulary", footnote: "Names, products and jargon, separated by commas or new lines. Attendee names and the meeting title are added automatically.") {
            TextEditor(text: $settings.vocabulary)
                .font(Theme.bodyFont)
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(8)
        }
    }

    private func refreshModelStatus(_ language: String) async {
        let installed = await AppleSpeechTranscriber.isLanguageInstalled(language)
        modelInstalled = installed
        modelStatus = installed ? "Installed for \(LanguageOption.label(for: language))." : "Not downloaded yet for \(LanguageOption.label(for: language)). It downloads automatically on first use."
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

private struct NotionSettings: View {
    let model: AppModel
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "Connection", footnote: "Easiest: a personal access token from notion.so/developers (acts as you, no sharing needed). An internal integration token also works if the database is shared with it under ••• → Connections.") {
            SettingsRow(title: "Token") {
                SecretField(placeholder: "ntn_… or secret_…", isSet: settings.hasNotionToken) { settings.setNotionToken($0) }
            }
            SettingsRow(title: "Database", detail: "Already set to Meeting Transcripts; no need to change it. To use another database, paste its link or ID.") {
                TextField("Data source ID", text: $settings.notionDataSourceID)
                    .textFieldStyle(.roundedBorder).frame(width: 250).font(Theme.monoFont)
            }
            SettingsRow(title: "Test connection", detail: testResult, showDivider: false) {
                Button {
                    test()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .buttonStyle(.v(.secondary, .small))
                .disabled(!settings.hasNotionToken || testing)
            }
        }
        SettingsGroup(title: "Export") {
            SettingsRow(title: "来源 value", detail: "Written to the 来源 select so these pages are easy to filter.") {
                TextField("Verbatim", text: $settings.notionSourceOption).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            SettingsRow(title: "Export automatically when a meeting ends", showDivider: false) {
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

private struct CalendarSettings: View {
    let model: AppModel

    var body: some View {
        let cal = model.calendar
        GoogleCalendarSettings(model: model)
        if !cal.google.isSignedIn, cal.access == .granted {
            macOSAccess
        }
        oneClickStart
        if !cal.google.isSignedIn, cal.access == .granted {
            calendarsToShow
        }
    }

    private var macOSAccess: some View {
        let cal = model.calendar
        return SettingsGroup(title: "macOS Calendar", footnote: "In use until you sign in to Google above; not used after that.") {
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

    private var oneClickStart: some View {
        SettingsGroup(title: "One-click start") {
            SettingsRow(title: "Notify when a meeting starts", detail: "A notification with a Transcribe button, for meetings with other attendees or a video link.") {
                Toggle("", isOn: Binding(get: { model.settings.meetingReminders }, set: { on in
                    model.settings.meetingReminders = on
                    if on { Task { _ = await MeetingReminder.requestPermission() } }
                }))
                .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Start automatically for video meetings", detail: "Begins transcribing when a meeting with a Meet/Zoom/Teams link starts. The capsule appears so you can stop it.") {
                Toggle("", isOn: Binding(get: { model.settings.autoStartVideoMeetings }, set: { model.settings.autoStartVideoMeetings = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Stop automatically when the meeting ends", detail: "Stops once the call audio has been quiet for 3 minutes, or nobody has spoken for 10. You get a 1-minute warning with a Keep recording button first.", showDivider: false) {
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

    var body: some View {
        let cal = model.calendar
        let google = cal.google
        SettingsGroup(title: "Google Calendar", footnote: "Read-only: meeting titles, times, attendees and video links from your primary calendar. The connection uses your own OAuth client, so nothing goes through a third party.") {
            switch google.state {
            case let .signedIn(email):
                SettingsRow(title: email.isEmpty ? "Connected" : email,
                            detail: cal.googleError ?? "\(cal.events.count) meetings from yesterday through the day after tomorrow.",
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
                SettingsRow(title: "OAuth client", detail: google.hasClient ? "Saved." : "Import the JSON file you downloaded from Google Cloud Console, or paste the ID and secret.") {
                    Button("Import JSON…", action: importJSON).buttonStyle(.v(.secondary, .small))
                    if google.hasClient {
                        Button("Remove") { google.setClient(nil) }.buttonStyle(.v(.ghost, .small))
                    }
                }
                if !google.hasClient {
                    SettingsRow(title: "Client ID") {
                        TextField("…apps.googleusercontent.com", text: $clientID).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    SettingsRow(title: "Client secret") {
                        SecureField("GOCSPX-…", text: $clientSecret).textFieldStyle(.roundedBorder).frame(width: 180)
                        Button("Save") {
                            google.setClient(GoogleOAuthClient(id: clientID, secret: clientSecret))
                            clientID = ""
                            clientSecret = ""
                        }
                        .buttonStyle(.v(.primary, .small))
                        .disabled(clientID.trimmed.isEmpty || clientSecret.trimmed.isEmpty)
                    }
                }
                SettingsRow(title: "Sign in", detail: google.lastError ?? (google.hasClient
                    ? "Opens Google in your browser. Choose the account whose meetings you record."
                    : "Needs your OAuth client first: import it above (one-time setup below)."), showDivider: false) {
                    // Never disabled: without a client, clicking says what's missing.
                    Button("Sign in with Google") { Task { await cal.connectGoogle() } }
                        .buttonStyle(.v(google.hasClient ? .primary : .secondary, .small))
                }
            }
        }
        if !google.isSignedIn { setupSteps }
    }

    private var setupSteps: some View {
        SettingsGroup(title: "One-time setup (about 10 minutes)", footnote: "If your company's Google Workspace blocks unverified apps, ask IT to allow it, or create the project while signed in with your work account and choose Internal in step 3 (no warning, no publishing).") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "In Google Cloud Console, create a project (any name, e.g. Verbatim).")
                step(2, "Enable the Google Calendar API for that project.")
                step(3, "Google Auth Platform → Branding: app name Verbatim and your email. Audience: External, then Publish app, so sign-in doesn't expire every 7 days.")
                step(4, "Clients → Create client → Application type Desktop app → Create → Download JSON.")
                step(5, "Import that JSON above and click Sign in with Google. When Google says the app isn't verified, choose Advanced → Go to Verbatim (it's your own client) and keep the calendar box checked.")
                HStack(spacing: 8) {
                    Button("Open Google Cloud Console") { open("https://console.cloud.google.com/projectcreate") }
                    Button("Enable Calendar API") { open("https://console.cloud.google.com/apis/library/calendar-json.googleapis.com") }
                    Button("Create client") { open("https://console.cloud.google.com/auth/clients/create") }
                }
                .buttonStyle(.v(.secondary, .small))
                .padding(.top, 4)
            }
            .padding(12)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.monoSmallFont).foregroundStyle(Theme.textTertiary).frame(width: 14, alignment: .trailing)
            Text(text).font(Theme.smallFont).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func open(_ link: String) {
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

struct PermissionSettings: View {
    let model: AppModel
    @State private var micGranted = MicCapture.permissionGranted
    @State private var systemAudioResult: String?
    @State private var testingSystem = false

    var body: some View {
        SettingsGroup(title: "macOS permissions", footnote: "System audio recording is granted once in a macOS prompt the first time Verbatim captures other apps' audio. You can review it in System Settings → Privacy & Security → Screen & System Audio Recording.") {
            SettingsRow(title: "Microphone", detail: micGranted ? "Allowed" : "Needed to transcribe what you say.") {
                if !micGranted {
                    Button("Allow") { Task { micGranted = await MicCapture.requestPermission() } }
                        .buttonStyle(.v(.secondary, .small))
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
            }
            SettingsRow(title: "System audio", detail: systemAudioResult ?? "Needed to transcribe the other participants.") {
                Button { testSystemAudio() } label: {
                    if testingSystem { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .buttonStyle(.v(.secondary, .small))
                .disabled(testingSystem)
            }
            SettingsRow(title: "Google Calendar", detail: googleDetail, showDivider: false) {
                if model.calendar.google.isSignedIn {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
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
        if case let .signedIn(email) = model.calendar.google.state { return email.isEmpty ? "Connected" : "Connected as \(email)" }
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
