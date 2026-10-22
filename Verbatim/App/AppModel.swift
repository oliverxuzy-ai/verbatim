import AppKit
import Observation
import SwiftUI

@Observable
final class AppModel {
    enum ExportState: Equatable {
        case idle
        case exporting
        case done(URL)
        case failed(String)
    }

    let settings = AppSettings()
    let store: RecordingStore
    let calendar = CalendarService()
    let windows = WindowManager()
    let toasts = ToastCenter()
    let panel = FloatingPanelController()
    let reminder = MeetingReminder()
    let voiceprints: VoiceprintStore
    /// Off for tests and snapshots: never call cloud APIs or touch the
    /// user's real voiceprints from an isolated model.
    let allowsCloud: Bool
    private var hotKey: GlobalHotKey?

    private(set) var session: RecordingSession?
    var selectedRecordingID: UUID?
    var settingsSection: SettingsView.Section = .transcription
    private(set) var exportStates: [UUID: ExportState] = [:]
    private(set) var refineStates: [UUID: RefineState] = [:]
    /// Re-entrancy guard for refine, separate from the displayed state
    /// (postProcess shows "running" before it calls refine).
    private var refining: Set<UUID> = []

    enum RefineState: Equatable {
        case running(String)
        case done
        case failed(String)
    }
    var lastError: String?

    init(storeRoot: URL? = nil) {
        store = RecordingStore(rootURL: storeRoot)
        voiceprints = VoiceprintStore(folder: storeRoot?.deletingLastPathComponent().appendingPathComponent("Voiceprints-\(storeRoot!.lastPathComponent)"))
        allowsCloud = storeRoot == nil
        calendar.hiddenCalendarIDs = Set(settings.hiddenCalendarIDs)
    }

    func launch() {
        windows.model = self
        panel.model = self
        store.recoverInterrupted(except: session?.recordingID)
        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
        hotKey?.register()
        calendar.startAutoRefresh()
        reminder.model = self
        reminder.start()
        if settings.meetingReminders, settings.hasCompletedOnboarding {
            Task { _ = await MeetingReminder.requestPermission() }
        }
        if !settings.hasCompletedOnboarding {
            windows.showOnboarding()
        }
        if settings.liveDiarization {
            Task.detached(priority: .background) { await LiveDiarizer.warmUp() }
        }
    }

    var isRecording: Bool { session?.isActive == true }

    /// Every "Connect calendar" button: sign in to Google, or open the
    /// one-time OAuth client setup if it isn't done yet.
    func connectCalendar() {
        if calendar.google.hasClient {
            Task { await calendar.connectGoogle() }
        } else {
            windows.showSettings(section: .calendar)
        }
    }

    /// ⌥⌘R: stop if recording, otherwise record the current meeting.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(meeting: calendar.current ?? .adHoc())
        }
    }

    #if DEBUG
    func debugSetSession(_ session: RecordingSession) { self.session = session }
    #endif

    // MARK: Recording

    /// Recordings always start with the mic as you; whether it was really a
    /// room (in person or hybrid) is decided from the audio after the meeting.
    func startRecording(meeting: MeetingInfo, language: String? = nil) {
        guard !isRecording else { return }
        lastError = nil
        let mode = MicMode.solo
        let session = RecordingSession(
            meeting: meeting,
            language: language ?? settings.language,
            micMode: mode,
            settings: settings,
            store: store
        )
        self.session = session
        // Forgotten recordings stop on their own once the meeting is over.
        session.onAutoStopPending = { [weak self] reason in
            self?.reminder.autoStopPending(reason, title: meeting.title)
        }
        session.onMeetingEnded = { [weak self, weak session] reason in
            guard let self, let session, self.session === session else { return }
            self.stopRecording(automatically: reason)
        }
        panel.show()
        Task {
            await session.start()
            if case let .failed(message) = session.phase {
                lastError = message
                panel.showError(message)
                if self.session === session { self.session = nil }
            }
        }
    }

    func stopRecording(automatically reason: MeetingEndDetector.Reason? = nil) {
        guard let session, session.isActive, session.phase != .stopping else { return }
        let id = session.recordingID
        if let reason {
            let title = session.transcript.recording.meeting.title
            reminder.autoStopped(title: title, reason: reason)
            toasts.show(.info, "Recording stopped automatically", detail: "\(reason.message) Everything up to now is saved.")
        }
        // Bring the meeting up right away so it's obvious the recording ended
        // and its notes are being finished.
        selectedRecordingID = id
        refineStates[id] = .running("Finishing transcript…")
        panel.hide()
        windows.showMain()
        Task {
            let recording = await session.stop()
            if self.session === session { self.session = nil }
            await postProcess(recording)
        }
    }

    /// After a recording: name speakers, refine, suggest names, export.
    /// Every step is bounded so the banner can never spin forever.
    func postProcess(_ recording: Recording) async {
        let id = recording.id
        refineStates[id] = .running("Recognizing voices…")
        var named = (try? await withTimeout(90) { await self.identifySpeakers(recording) }) ?? recording
        named = CalendarRules.apply(named, myName: settings.myName)
        let willRefine = settings.autoRefine && canRefine(named)
        if !willRefine {
            refineStates[id] = .running("Suggesting names…")
            let toName = named
            named = (try? await withTimeout(150) { await self.suggestNamesWithClaude(toName) }) ?? named
        }
        store.save(named)
        if willRefine {
            await refine(id)
        } else {
            refineStates[id] = .done
        }
        if let latest = store.recording(id) {
            _ = try? await withTimeout(120) { await self.learnVoices(from: latest) }
        }
        if allowsCloud, settings.autoExportOnStop, settings.hasNotionToken { await export(id) }
    }

    /// The recording to display: the live one if it is selected.
    func recording(_ id: UUID) -> Recording? {
        if let session, session.recordingID == id { return session.transcript.recording }
        return store.recording(id)
    }

    // MARK: Speakers

    func updateSpeaker(recordingID: UUID, speakerID: String, name: String, email: String?, isMe: Bool = false) {
        mutate(recordingID) { rec in
            guard let i = rec.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            rec.speakers[i].name = name.trimmed.isEmpty ? rec.speakers[i].name : name.trimmed
            rec.speakers[i].email = email
            rec.speakers[i].isConfirmed = true
            rec.speakerSources = (rec.speakerSources ?? [:]).merging([speakerID: "user"]) { $1 }
            if isMe {
                for j in rec.speakers.indices { rec.speakers[j].isMe = (j == i) }
            }
        }
        guard session?.recordingID != recordingID, let rec = store.recording(recordingID),
              let speaker = rec.speaker(speakerID) else { return }
        Task {
            if speaker.isMe {
                await voiceprints.learn(speaker: speaker, in: rec, store: store, id: VoiceprintStore.meID, displayName: settings.myName)
            } else {
                await voiceprints.learn(speaker: speaker, in: rec, store: store)
            }
        }
    }

    /// Move every segment of `from` onto `into` (fixes diarizer splits).
    func mergeSpeaker(recordingID: UUID, from: String, into: String) {
        guard from != into else { return }
        mutate(recordingID) { rec in
            for i in rec.segments.indices where rec.segments[i].speakerID == from {
                rec.segments[i].speakerID = into
            }
            rec.speakers.removeAll { $0.id == from }
        }
    }

    func reassignSegment(recordingID: UUID, segmentID: UUID, to speakerID: String) {
        mutate(recordingID) { rec in
            if let i = rec.segments.firstIndex(where: { $0.id == segmentID }) { rec.segments[i].speakerID = speakerID }
        }
    }

    func updateSegmentText(recordingID: UUID, segmentID: UUID, text: String) {
        mutate(recordingID) { rec in
            if let i = rec.segments.firstIndex(where: { $0.id == segmentID }) {
                rec.segments[i].text = text
                rec.segments[i].words = nil
            }
        }
    }

    func renameRecording(_ id: UUID, title: String) {
        guard !title.trimmed.isEmpty else { return }
        mutate(id) { $0.meeting.title = title.trimmed }
    }

    func deleteRecording(_ id: UUID) {
        guard session?.recordingID != id else { return }
        store.delete(id)
        if selectedRecordingID == id { selectedRecordingID = store.recordings.first?.id }
    }

    private func mutate(_ id: UUID, _ change: (inout Recording) -> Void) {
        if let session, session.recordingID == id {
            change(&session.transcript.recording)
            return
        }
        guard var rec = store.recording(id) else { return }
        change(&rec)
        store.save(rec)
    }

    // MARK: Refine

    /// Every finished recording can be refined: Apple recordings get both
    /// stages, Soniox recordings keep their (stronger) text and only get the
    /// whole-meeting speaker pass.
    func canRefine(_ recording: Recording) -> Bool {
        recording.endedAt != nil
    }

    func refine(_ id: UUID) async {
        guard let original = store.recording(id), canRefine(original), !refining.contains(id) else { return }
        refining.insert(id)
        defer { refining.remove(id) }
        refineStates[id] = .running("Preparing…")
        let terms = VocabularyBuilder.terms(meeting: original.meeting, userTerms: settings.vocabularyTerms, myName: settings.myName)
        do {
            var refined = try await TranscriptRefiner.refine(
                original, store: store, myName: settings.myName, terms: terms,
                retranscribe: original.engine == EngineKind.apple.rawValue
            ) { [weak self] message in
                Task { @MainActor in self?.refineStates[id] = .running(message) }
            }
            refineStates[id] = .running("Recognizing voices…")
            let separated = refined
            refined = (try? await withTimeout(90) { await self.identifySpeakers(separated) }) ?? refined
            refined = CalendarRules.apply(refined, myName: settings.myName)
            refineStates[id] = .running("Suggesting names…")
            let toName = refined
            refined = (try? await withTimeout(150) { await self.suggestNamesWithClaude(toName) }) ?? refined
            // Keep anything the user changed meanwhile (title, export link).
            if let latest = store.recording(id) {
                refined.meeting = latest.meeting
                refined.notionPageURL = latest.notionPageURL
                refined.exportedAt = latest.exportedAt
            }
            store.save(refined)
            refineStates[id] = .done
            toasts.show(.success, "Transcript refined", detail: "Re-transcribed with whole-meeting speaker separation")
        } catch RefineError.noAudio {
            refineStates[id] = .failed("No speech was detected in this recording.")
        } catch {
            Log.asr.error("Refine failed: \(error.localizedDescription)")
            refineStates[id] = .failed(error.localizedDescription)
        }
    }

    /// Ask Claude to suggest names for speakers still anonymous after
    /// voiceprints and calendar rules. Suggestions stay unconfirmed.
    func suggestNamesWithClaude(_ recording: Recording) async -> Recording {
        guard allowsCloud, settings.claudeNaming, let key = settings.anthropicKey,
              recording.speakers.contains(where: { !$0.isMe && !$0.isConfirmed && CalendarRules.isGeneric($0.name) }) else { return recording }
        do {
            var rec = recording
            for s in try await LLMSpeakerNamer.suggest(for: recording, apiKey: key, myName: settings.myName) {
                guard let i = rec.speakers.firstIndex(where: { $0.id == s.speakerID }), CalendarRules.isGeneric(rec.speakers[i].name) else { continue }
                rec.speakers[i].name = s.name
                rec.speakers[i].email = rec.meeting.attendees.first { $0.displayName == s.name }?.email
                rec.speakers[i].isConfirmed = false
                rec.speakerSources = (rec.speakerSources ?? [:]).merging([s.speakerID: "llm"]) { $1 }
            }
            return rec
        } catch {
            Log.app.error("Claude naming failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return recording
        }
    }

    func suggestNames(_ id: UUID) async {
        guard let rec = store.recording(id) else { return }
        refineStates[id] = .running("Asking Claude…")
        let named = await suggestNamesWithClaude(rec)
        store.save(named)
        refineStates[id] = .done
    }

    // MARK: Voices

    /// Name unconfirmed speakers from the voiceprint library.
    func identifySpeakers(_ recording: Recording) async -> Recording {
        var rec = recording
        for match in await voiceprints.identify(rec, store: store) {
            guard let i = rec.speakers.firstIndex(where: { $0.id == match.speakerID }) else { continue }
            if match.voiceprintID == VoiceprintStore.meID {
                for j in rec.speakers.indices { rec.speakers[j].isMe = false }
                rec.speakers[i].isMe = true
                rec.speakers[i].name = settings.myName
            } else {
                rec.speakers[i].name = match.name
                rec.speakers[i].email = match.email
            }
            rec.speakers[i].isConfirmed = match.isConfident
            rec.speakerSources = (rec.speakerSources ?? [:]).merging([match.speakerID: "voiceprint"]) { $1 }
        }
        return rec
    }

    /// Learn voices the user has confirmed, and your own voice from online
    /// meetings where the mic is only you.
    func learnVoices(from recording: Recording) async {
        for speaker in recording.speakers where speaker.isConfirmed {
            let source = recording.speakerSources?[speaker.id]
            guard source != "voiceprint" else { continue }
            if speaker.isMe {
                if recording.micMode == .solo, !TranscriptRefiner.isInPerson(recording) {
                    var me = speaker
                    me.name = VoiceprintStore.meID
                    me.email = nil
                    await voiceprints.learn(speaker: me, in: recording, store: store, id: VoiceprintStore.meID, displayName: settings.myName)
                }
            } else {
                await voiceprints.learn(speaker: speaker, in: recording, store: store)
            }
        }
    }

    // MARK: Notion

    func exportState(_ id: UUID) -> ExportState {
        if let s = exportStates[id] { return s }
        if let url = store.recording(id)?.notionPageURL { return .done(url) }
        return .idle
    }

    func export(_ id: UUID) async {
        guard let recording = store.recording(id) else { return }
        guard let token = settings.notionToken else {
            exportStates[id] = .failed(NotionError.missingToken.localizedDescription)
            return
        }
        exportStates[id] = .exporting
        let exporter = NotionExporter(
            client: NotionClient(token: token),
            dataSourceID: settings.notionDataSourceID.trimmed,
            sourceOption: settings.notionSourceOption
        )
        do {
            let url = try await exporter.export(recording)
            var updated = store.recording(id) ?? recording
            updated.notionPageURL = url
            updated.exportedAt = .now
            store.save(updated)
            exportStates[id] = .done(url)
            toasts.show(.success, "Saved to Notion", detail: recording.meeting.title, actionTitle: "Open") { [weak self] in
                self?.openInNotion(url)
            }
        } catch {
            Log.notion.error("Export failed: \(error.localizedDescription)")
            exportStates[id] = .failed(error.localizedDescription)
            toasts.show(.failure, "Couldn't save to Notion", detail: error.localizedDescription, actionTitle: "Retry") { [weak self] in
                Task { await self?.export(id) }
            }
        }
    }

    func openInNotion(_ url: URL) {
        // Prefer the desktop app when installed.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "notion"
        if let app = components?.url, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
