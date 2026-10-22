import AVFAudio
import Foundation
import Observation

/// Orchestrates one live recording: both captures, both pipelines, engines,
/// diarizers, the live transcript, levels for the waveform, and autosave.
@Observable
final class RecordingSession {
    enum Phase: Equatable {
        case preparing(String)
        case recording
        case stopping
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .preparing("Starting…")
    let transcript: LiveTranscript
    private(set) var startDate = Date.now
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    /// Rolling level history (newest last) for the waveform.
    private(set) var levelHistory: [Float] = Array(repeating: 0, count: 64)
    private(set) var warnings: [String] = []
    private(set) var echoCancellationActive = false
    private(set) var isPaused = false
    /// False once we know the call audio isn't arriving (permission missing).
    private(set) var systemAudioOK = true
    /// Set while a forgotten recording is about to stop on its own: seconds
    /// left before it stops, and why. Any speech or "Keep recording" clears it.
    private(set) var autoStopSecondsLeft: Int?
    private(set) var autoStopReason: MeetingEndDetector.Reason?
    /// Called when the countdown starts (with the reason) or is cancelled (nil).
    var onAutoStopPending: ((MeetingEndDetector.Reason?) -> Void)?
    /// Called once when the countdown runs out; the owner stops the session.
    var onMeetingEnded: ((MeetingEndDetector.Reason) -> Void)?
    static let autoStopGrace: TimeInterval = 60
    private var endDetector: MeetingEndDetector?
    private var autoStopDeadline: Date?
    private var cancelled = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    let engineKind: EngineKind
    let language: String
    let micMode: MicMode

    private let settings: AppSettings
    private let store: RecordingStore
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var pipelines: [AudioChannel: ChannelPipeline] = [:]
    private var updateTasks: [Task<Void, Never>] = []
    private var updateContinuations: [AsyncStream<EngineUpdate>.Continuation] = []
    private var ticker: Task<Void, Never>?
    private var sessionStartHost: Double = 0
    private var tickCount = 0

    init(meeting: MeetingInfo, language: String, micMode: MicMode, settings: AppSettings, store: RecordingStore) {
        self.settings = settings
        self.store = store
        self.engineKind = settings.engine
        self.language = language
        self.micMode = micMode
        let recording = Recording(
            meeting: meeting, startedAt: .now, language: language,
            engine: settings.engine.rawValue, micMode: micMode
        )
        self.transcript = LiveTranscript(recording: recording, myName: settings.myName)
    }

    var recordingID: UUID { transcript.recording.id }
    var elapsed: TimeInterval { phase == .recording || phase == .stopping ? Date.now.timeIntervalSince(startDate) : 0 }
    var isActive: Bool {
        switch phase {
        case .preparing, .recording, .stopping: true
        default: false
        }
    }

    // MARK: Start

    func start() async {
        do {
            try await startThrowing()
        } catch is CancellationError {
            teardownCaptures()
        } catch {
            Log.app.error("Recording failed to start: \(error.localizedDescription)")
            teardownCaptures()
            if phase != .stopping && phase != .finished { phase = .failed(error.localizedDescription) }
        }
    }

    private func startThrowing() async throws {
        phase = .preparing("Checking microphone…")
        if !MicCapture.permissionGranted {
            guard await MicCapture.requestPermission() else {
                throw TranscriberError.server("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.")
            }
        }

        let meeting = transcript.recording.meeting
        let terms = VocabularyBuilder.terms(meeting: meeting, userTerms: settings.vocabularyTerms, myName: settings.myName)
        let context = TranscriptionContext(
            language: language, terms: terms, meetingTitle: meeting.title,
            attendeeNames: meeting.attendees.map(\.displayName)
        )

        // Speaker strategy per channel.
        let micDiarize = micMode == .room
        let wantsLocalDiarization = settings.liveDiarization && engineKind == .apple

        var micDiarizer: LiveDiarizer?
        var systemDiarizer: LiveDiarizer?
        if wantsLocalDiarization {
            phase = .preparing("Loading speaker model…")
            systemDiarizer = await Self.prepareDiarizer(.call)
            if micDiarize { micDiarizer = await Self.prepareDiarizer(.room) }
            if systemDiarizer == nil { warnings.append("Speaker separation unavailable (model download failed). Remote speakers will share one label.") }
        }

        phase = .preparing(engineKind == .apple ? "Loading speech model…" : "Connecting to Soniox…")
        let micEngine = try makeTranscriber(context: context, diarize: micDiarize)
        let systemEngine = try makeTranscriber(context: context, diarize: true)

        transcript.configure(.mic, .init(
            fixedSpeaker: micMode == .solo ? Speaker.meID : nil,
            engineDiarizes: micDiarize && micEngine.providesDiarization,
            diarizer: micDiarizer,
            fallbackLabel: "In room"
        ))
        transcript.configure(.system, .init(
            fixedSpeaker: nil,
            engineDiarizes: systemEngine.providesDiarization,
            diarizer: systemDiarizer,
            fallbackLabel: "Speaker"
        ))

        try await micEngine.start(updates: makeUpdateSink(.mic))
        try await systemEngine.start(updates: makeUpdateSink(.system))

        let id = transcript.recording.id
        try FileManager.default.createDirectory(at: store.folder(for: id), withIntermediateDirectories: true)
        let micPipe = ChannelPipeline(
            channel: .mic, policy: .firstChannel,
            sink: try? AudioFileSink(url: store.liveAudioURL(for: id, channel: .mic)),
            transcriber: micEngine, diarizer: micDiarizer
        )
        let systemPipe = ChannelPipeline(
            channel: .system, policy: .average,
            sink: try? AudioFileSink(url: store.liveAudioURL(for: id, channel: .system)),
            transcriber: systemEngine, diarizer: systemDiarizer
        )
        pipelines = [.mic: micPipe, .system: systemPipe]

        phase = .preparing("Starting audio…")
        sessionStartHost = AudioFormats.nowHostSeconds
        startDate = .now
        transcript.recording.startedAt = startDate

        // Echo cancellation only matters when the mic can hear the speakers.
        let useAEC = settings.echoCancellation && micMode == .solo && !AudioRouting.outputIsHeadphones()
        // A missing "System Audio Recording" grant doesn't fail the tap, it
        // just yields silence, so check (and ask) before relying on it.
        if SystemAudioPermission.status != .granted {
            phase = .preparing("Requesting system audio access…")
            let granted = await SystemAudioPermission.request()
            if !granted, SystemAudioPermission.status != .granted {
                systemAudioOK = false
                warn("System audio access is off, so other participants won't be transcribed. Turn on Verbatim in System Settings → Privacy & Security → Screen & System Audio Recording.")
            }
        }
        if cancelled { throw CancellationError() }
        do {
            try system.start { buffer, host in systemPipe.ingest(buffer, hostTime: host) }
        } catch {
            systemAudioOK = false
            warn("System audio capture failed: \(error.localizedDescription). Only your microphone is recorded.")
        }
        // The aggregate is clocked by the output device; rebuild the tap when
        // the output changes (headphones, AirPods, an external display).
        outputListener = AudioRouting.observeDefaultOutput { [weak self] in
            Task { @MainActor in self?.restartSystemCapture() }
        }
        if cancelled { throw CancellationError() }
        try mic.start(voiceProcessing: useAEC) { buffer, host in micPipe.ingest(buffer, hostTime: host) }
        echoCancellationActive = mic.echoCancellationActive

        store.persist(transcript.recording)
        if settings.autoStopWhenMeetingEnds {
            endDetector = MeetingEndDetector(start: startDate, scheduledEnd: meeting.scheduledEnd)
        }
        phase = .recording
        startTicker()
    }

    private func makeTranscriber(context: TranscriptionContext, diarize: Bool) throws -> StreamingTranscriber {
        switch engineKind {
        case .apple:
            return AppleSpeechTranscriber(language: context.language, terms: context.terms)
        case .soniox:
            guard let key = settings.sonioxKey, !key.isEmpty else { throw TranscriberError.missingAPIKey("Soniox") }
            return SonioxTranscriber(apiKey: key, context: context, diarize: diarize)
        }
    }

    private static func prepareDiarizer(_ variant: LiveDiarizer.Variant) async -> LiveDiarizer? {
        let d = LiveDiarizer(variant: variant)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await d.prepare() }
                group.addTask {
                    try await Task.sleep(for: .seconds(45))
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
            return d
        } catch {
            Log.asr.error("Diarizer unavailable: \(error.localizedDescription)")
            return d.isReady ? d : nil
        }
    }

    /// Engines call back on arbitrary threads; funnel updates through an
    /// ordered stream consumed on the main actor.
    private func makeUpdateSink(_ channel: AudioChannel) -> @Sendable (EngineUpdate) -> Void {
        let (stream, continuation) = AsyncStream<EngineUpdate>.makeStream()
        updateContinuations.append(continuation)
        updateTasks.append(Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                self.alignOffsets()
                self.transcript.apply(update, channel: channel)
                if update.hasSpeech { self.endDetector?.heardSpeech(on: channel, at: .now) }
            }
        })
        return { continuation.yield($0) }
    }

    private func alignOffsets() {
        for (channel, pipe) in pipelines {
            if let host = pipe.startHostTime {
                transcript.setOffset(channel, max(0, AudioFormats.hostTimeToSeconds(host) - sessionStartHost))
            }
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                self?.tick()
            }
        }
    }

    func togglePause() {
        guard phase == .recording else { return }
        isPaused.toggle()
        for pipe in pipelines.values { pipe.paused.withLock { $0 = isPaused } }
        // Paused time is silence on purpose; don't count it toward auto-stop.
        if isPaused { cancelAutoStop() } else { endDetector?.resetQuiet(at: .now) }
    }

    /// "Keep recording": the meeting is still going, restart the quiet timers.
    func keepRecording() {
        endDetector?.resetQuiet(at: .now)
        cancelAutoStop()
    }

    private func checkMeetingEnd() {
        guard let detector = endDetector, !isPaused else { return }
        let now = Date.now
        guard let reason = detector.verdict(at: now, callAudioWorks: systemAudioOK) else {
            cancelAutoStop()
            return
        }
        if autoStopDeadline == nil {
            autoStopDeadline = now.addingTimeInterval(Self.autoStopGrace)
            autoStopReason = reason
            Log.app.info("Meeting looks over (\(String(describing: reason), privacy: .public)); stopping in \(Int(Self.autoStopGrace)) s unless someone speaks")
            onAutoStopPending?(reason)
        }
        let left = autoStopDeadline!.timeIntervalSince(now)
        autoStopSecondsLeft = max(0, Int(left.rounded(.up)))
        if left <= 0 {
            endDetector = nil // fire once
            onMeetingEnded?(reason)
        }
    }

    private func cancelAutoStop() {
        guard autoStopDeadline != nil else { return }
        autoStopDeadline = nil
        autoStopSecondsLeft = nil
        autoStopReason = nil
        onAutoStopPending?(nil)
    }

    private func tick() {
        guard phase == .recording else { return }
        tickCount += 1
        micLevel = pipelines[.mic]?.readLevel() ?? 0
        systemLevel = pipelines[.system]?.readLevel() ?? 0
        levelHistory.removeFirst()
        levelHistory.append(max(micLevel, systemLevel))
        if tickCount % 8 == 0 { transcript.resolvePending() }
        if tickCount % 15 == 0 { checkMeetingEnd() } // ~1 s
        if tickCount % 150 == 0 { store.persist(transcript.recording) } // ~10 s autosave
        // No call audio after 3 s: rebuild the tap once (this also recovers
        // the first recording right after the permission was granted), using
        // the output-clocked layout. Warn only if that doesn't help either.
        if tickCount == 45, let sys = pipelines[.system], sys.receivedSeconds < 0.5 {
            restartSystemCapture(clockedByOutput: true)
        }
        if tickCount == 120, let sys = pipelines[.system], sys.receivedSeconds < 0.5 {
            systemAudioOK = false
            warn("System audio isn't arriving. Allow Verbatim in System Settings → Privacy & Security → Screen & System Audio Recording, then start again.")
        }
        if tickCount == 600, let sys = pipelines[.system], sys.voicedSeconds < 0.05 {
            warn("System audio has been silent for 40 s. If others are talking, check the system audio permission.")
        }
    }

    private func restartSystemCapture(clockedByOutput: Bool = false) {
        guard phase == .recording, let pipe = pipelines[.system] else { return }
        Log.audio.error("Rebuilding the system audio tap (clocked: \(clockedByOutput))")
        system.stop()
        do {
            try system.start(clockedByOutput: clockedByOutput) { buffer, host in pipe.ingest(buffer, hostTime: host) }
        } catch {
            systemAudioOK = false
            warn("System audio capture couldn't restart: \(error.localizedDescription)")
        }
    }

    private func warn(_ message: String) {
        guard !warnings.contains(where: { $0 == message }) else { return }
        warnings.append(message)
        Log.app.error("Recording warning: \(message)")
    }

    // MARK: Stop

    @discardableResult
    func stop() async -> Recording {
        guard phase == .recording || isPreparing else { return transcript.recording }
        // Stopping during start-up: make the start sequence bail out before
        // it opens any device.
        cancelled = true
        phase = .stopping
        ticker?.cancel()
        endDetector = nil
        cancelAutoStop()
        teardownCaptures()
        // Flush engines and diarizers; never let a stuck engine block saving.
        for pipe in pipelines.values {
            do { try await withTimeout(30) { await pipe.finish() } } catch {
                Log.asr.error("Finishing \(pipe.channel.rawValue) timed out; saving what we have")
            }
        }
        // Let the update streams deliver the last finals, then close them.
        updateContinuations.forEach { $0.finish() }
        let tasks = updateTasks
        _ = try? await withTimeout(10) { for task in tasks { await task.value } }
        updateContinuations = []
        updateTasks = []
        alignOffsets()
        transcript.finalizeLive()
        var recording = transcript.recording
        recording.endedAt = .now
        recording.channelOffsets = transcript.offsets
        recording.diagnostics = warnings.isEmpty ? nil : warnings
        transcript.recording = recording
        let folder = store.folder(for: recording.id)
        await Task.detached(priority: .userInitiated) { RecordingStore.finalizeAudio(in: folder) }.value
        store.save(recording)
        phase = .finished
        return recording
    }

    private var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    #if DEBUG
    /// Animate levels like a live recording (used by --demo-session).
    func debugStartTicker() {
        ticker = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                guard let self else { return }
                i += 1
                self.micLevel = Float(abs(sin(Double(i) * 0.3)))
                self.systemLevel = Float(abs(cos(Double(i) * 0.2)))
                self.levelHistory.removeFirst()
                self.levelHistory.append(max(self.micLevel, self.systemLevel) * 0.8)
            }
        }
    }

    /// Fake a live session with sample transcript and moving levels (used by
    /// the --snapshot debug mode to render the UI).
    func runDemo(lines: [(String, String, String)]) {
        phase = .recording
        startDate = Date.now.addingTimeInterval(-754)
        transcript.recording.startedAt = startDate
        transcript.configure(.mic, .init(fixedSpeaker: Speaker.meID, fallbackLabel: "In room"))
        transcript.configure(.system, .init(engineDiarizes: true, fallbackLabel: "Speaker"))
        var t = 700.0
        for (channel, label, text) in lines {
            let ch = AudioChannel(rawValue: channel) ?? .system
            let dur = Double(text.count) / 14
            transcript.apply(EngineUpdate(finals: [EngineResult(start: t, end: t + dur, text: text, speaker: label)]), channel: ch)
            t += dur + 2.5
        }
        transcript.apply(EngineUpdate(finals: [], volatile: EngineResult(start: t, end: t + 1, text: "and the next step is to", speaker: "1")), channel: .system)
        levelHistory = (0..<64).map { (i: Int) -> Float in
            let wave = abs(sin(Double(i) * 0.45))
            let shape = 0.35 + 0.6 * Double(i % 7) / 7
            return Float(max(0.04, wave * shape))
        }
        micLevel = 0.1
        systemLevel = 0.6
    }
    #endif

    private func teardownCaptures() {
        if let outputListener { AudioRouting.stopObservingDefaultOutput(outputListener) }
        outputListener = nil
        mic.stop()
        system.stop()
    }
}
