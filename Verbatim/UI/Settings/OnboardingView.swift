import SwiftUI

/// First-run setup: one place to grant all three permissions, fetch the
/// speech model, and connect Notion.
struct OnboardingView: View {
    let model: AppModel
    let close: () -> Void
    @State private var step = 0
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var modelReady = false
    @State private var modelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Capsule().fill(i <= step ? Theme.text : Theme.border).frame(height: 3)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: speechModel
                default: notion
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Hairline()
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.vGhost) }
                Spacer()
                Button(step == 3 ? "Done" : "Continue") {
                    if step == 3 {
                        model.settings.hasCompletedOnboarding = true
                        if model.settings.meetingReminders { Task { _ = await MeetingReminder.requestPermission() } }
                        close()
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.vPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .background(Theme.bg)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandMark(height: 30)
            Text("Verbatim").font(Theme.displayFont).foregroundStyle(Theme.text)
            Text("Live meeting transcripts with speakers and timestamps, saved to your Notion in one click.")
                .font(Theme.bodyFont).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 10) {
                bullet("calendar", "Pick a meeting from your calendar in the menu bar")
                bullet("waveform", "A small floating panel shows it's listening")
                bullet("person.2", "Your mic is you; the call audio is split by speaker")
                bullet("square.and.arrow.up", "Export the raw transcript to Meeting Transcripts")
            }
            .padding(.top, 6)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.textSecondary)
            Text(text).font(Theme.bodyFont).foregroundStyle(Theme.text)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(Theme.titleFont).foregroundStyle(Theme.text)
            Text("macOS asks once for each. Click each button and choose Allow.")
                .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
            PermissionSettings(model: model)
        }
    }

    private var speechModel: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 14) {
            Text("Transcription").font(Theme.titleFont).foregroundStyle(Theme.text)
            Text("Verbatim starts with Apple's on-device engine: free and private. You can switch to Soniox in Settings for higher accuracy and mixed Chinese/English.")
                .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Usual meeting language").font(Theme.bodyFont).foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: $settings.language) {
                    ForEach(LanguageOption.all) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().frame(width: 170)
            }
            .card()
            HStack(spacing: 10) {
                if modelReady {
                    Label("Speech model ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                } else if downloading {
                    ProgressView(value: progress).frame(width: 200)
                    Text("Downloading…").foregroundStyle(Theme.textSecondary)
                } else {
                    Button("Download speech model") { download() }.buttonStyle(.vSecondary)
                }
                if let modelError { Text(modelError).foregroundStyle(Theme.warning).lineLimit(2) }
            }
            .font(Theme.smallFont)
        }
        .task(id: settings.language) {
            modelReady = await AppleSpeechTranscriber.isLanguageInstalled(settings.language)
        }
    }

    private func download() {
        downloading = true
        modelError = nil
        Task {
            do {
                try await AppleSpeechTranscriber.prepareLanguage(model.settings.language) { p in
                    Task { @MainActor in progress = p }
                }
                modelReady = true
            } catch {
                modelError = error.localizedDescription
            }
            downloading = false
        }
    }

    private var notion: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 14) {
            Text("Notion").font(Theme.titleFont).foregroundStyle(Theme.text)
            Text("Paste a personal access token from notion.so/developers. Transcripts go to your Meeting Transcripts database with 整理状态 = 待整理. You can do this later in Settings.")
                .font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecretField(placeholder: "Notion token", isSet: settings.hasNotionToken) { settings.setNotionToken($0) }
            HStack {
                Text("Your name in transcripts").font(Theme.bodyFont).foregroundStyle(Theme.text)
                Spacer()
                TextField("Name", text: $settings.myName).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .card()
        }
    }
}
