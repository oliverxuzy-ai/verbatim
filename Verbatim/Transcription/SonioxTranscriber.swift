import AVFAudio
import Foundation

/// Soniox real-time WebSocket transcription (stt-rt-v5): word-level timing,
/// built-in speaker diarization and Chinese/English code-switching.
/// Protocol: https://soniox.com/docs/stt/api-reference/websocket-api
nonisolated final class SonioxTranscriber: StreamingTranscriber, @unchecked Sendable {
    let displayName = "Soniox"
    var providesDiarization: Bool { diarize }

    private let apiKey: String
    private let context: TranscriptionContext
    private let diarize: Bool
    private let model = "stt-rt-v5"
    private let session = URLSession(configuration: .default)

    private let state = Locked(State())
    var updates: (@Sendable (EngineUpdate) -> Void)?
    private var finishedContinuation: CheckedContinuation<Void, Never>?

    private struct State {
        var task: URLSessionWebSocketTask?
        /// Seconds of audio sent on previous connections (after a reconnect
        /// the server clock restarts at zero).
        var timeOffset: Double = 0
        var samplesSentThisConnection: Int = 0
        var isFinishing = false
        var reconnects = 0
        var pendingWord: TimedWord?
    }

    init(apiKey: String, context: TranscriptionContext, diarize: Bool) {
        self.apiKey = apiKey
        self.context = context
        self.diarize = diarize
    }

    func start(updates: @escaping @Sendable (EngineUpdate) -> Void) async throws {
        self.updates = updates
        try await connect()
    }

    private func connect() async throws {
        var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        state.withLock {
            $0.task = task
            $0.samplesSentThisConnection = 0
        }
        let config = try JSONSerialization.data(withJSONObject: configuration())
        try await task.send(.string(String(decoding: config, as: UTF8.self)))
        receive(on: task)
    }

    private func configuration() -> [String: Any] {
        var config: [String: Any] = [
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_speaker_diarization": diarize,
            "enable_endpoint_detection": false,
            "client_reference_id": "verbatim",
        ]
        let hints = Self.languageHints(context.language)
        if !hints.isEmpty { config["language_hints"] = hints }
        if context.language == "mixed" { config["enable_language_identification"] = true }
        var ctx: [String: Any] = [:]
        if !context.terms.isEmpty { ctx["terms"] = context.terms }
        var general: [[String: String]] = [["key": "domain", "value": "Work meeting"]]
        if !context.meetingTitle.isEmpty { general.append(["key": "topic", "value": context.meetingTitle]) }
        if !context.attendeeNames.isEmpty {
            general.append(["key": "participants", "value": context.attendeeNames.joined(separator: ", ")])
        }
        ctx["general"] = general
        config["context"] = ctx
        return config
    }

    static func languageHints(_ language: String) -> [String] {
        switch language {
        case "mixed": return ["en", "zh"]
        case "zh-CN", "zh-TW", "zh-HK": return ["zh", "en"]
        default:
            let code = language.split(separator: "-").first.map(String.init) ?? language
            return code.isEmpty ? [] : [code, "en"].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var data = Data(count: n * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = max(-1, min(1, samples[i]))
                out[i] = Int16(v * Float(Int16.max))
            }
        }
        let task: URLSessionWebSocketTask? = state.withLock {
            guard !$0.isFinishing else { return nil }
            $0.samplesSentThisConnection += n
            return $0.task
        }
        task?.send(.data(data)) { error in
            if let error { Log.asr.debug("Soniox send error: \(error.localizedDescription)") }
        }
    }

    func finish() async {
        let task: URLSessionWebSocketTask? = state.withLock {
            $0.isFinishing = true
            return $0.task
        }
        guard let task else { return }
        // An empty text frame ends the stream; the server flushes finals and
        // replies with `finished: true`.
        try? await task.send(.string(""))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.state.withLock { _ in self.finishedContinuation = c }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(12)) }
            await group.next()
            group.cancelAll()
        }
        flushPendingWord()
        task.cancel(with: .normalClosure, reason: nil)
        resumeFinished()
    }

    private func resumeFinished() {
        let c: CheckedContinuation<Void, Never>? = state.withLock { _ in
            let c = finishedContinuation
            finishedContinuation = nil
            return c
        }
        c?.resume()
    }

    // MARK: Receiving

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .string(text): self.handle(Data(text.utf8))
                case let .data(data): self.handle(data)
                @unknown default: break
                }
                if task.state == .running { self.receive(on: task) }
            case let .failure(error):
                self.handleFailure(error, task: task)
            }
        }
    }

    private func handleFailure(_ error: Error, task: URLSessionWebSocketTask) {
        let (finishing, current, attempts) = state.withLock { ($0.isFinishing, $0.task, $0.reconnects) }
        guard current === task else { return }
        if finishing {
            resumeFinished()
            return
        }
        Log.asr.error("Soniox connection lost: \(error.localizedDescription)")
        guard attempts < 5 else {
            updates?(EngineUpdate(finals: [], volatile: nil))
            return
        }
        state.withLock {
            $0.reconnects += 1
            $0.timeOffset += Double($0.samplesSentThisConnection) / 16_000
        }
        flushPendingWord()
        Task {
            try? await Task.sleep(for: .seconds(Double(attempts + 1)))
            try? await self.connect()
        }
    }

    private struct Response: Decodable {
        struct Token: Decodable {
            let text: String
            let start_ms: Double?
            let end_ms: Double?
            let confidence: Double?
            let is_final: Bool?
            let speaker: String?
            let language: String?
        }
        let tokens: [Token]?
        let finished: Bool?
        let error_code: Int?
        let error_type: String?
        let error_message: String?
    }

    func handle(_ data: Data) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        if let message = response.error_message {
            Log.asr.error("Soniox error \(response.error_code ?? 0) \(response.error_type ?? ""): \(message)")
            return
        }
        let offset = state.withLock { $0.timeOffset }
        let tokens = (response.tokens ?? []).filter { !($0.text.hasPrefix("<") && $0.text.hasSuffix(">")) }

        var finals: [EngineResult] = []
        var volatileWords: [TimedWord] = []
        for token in tokens {
            let word = TimedWord(
                text: token.text,
                start: (token.start_ms ?? 0) / 1000 + offset,
                end: (token.end_ms ?? token.start_ms ?? 0) / 1000 + offset,
                speaker: token.speaker
            )
            if token.is_final == true {
                if let done = appendFinalToken(word) { finals.append(done) }
            } else {
                volatileWords.append(word)
            }
        }
        // Words still being assembled count as volatile so the UI shows them.
        let pending = state.withLock { $0.pendingWord }
        if let pending { volatileWords.insert(pending, at: 0) }
        let volatile = volatileWords.isEmpty ? nil : Self.result(from: volatileWords)
        if !finals.isEmpty || response.tokens != nil {
            updates?(EngineUpdate(finals: finals, volatile: volatile))
        }
        if response.finished == true {
            flushPendingWord()
            resumeFinished()
        }
    }

    /// Soniox tokens are sub-word pieces; a leading space starts a new word.
    /// Returns a completed word as a final result when one closes.
    private func appendFinalToken(_ token: TimedWord) -> EngineResult? {
        state.withLock { s -> EngineResult? in
            let startsNewWord = token.text.hasPrefix(" ") || Self.isCJK(token.text)
            guard var current = s.pendingWord else {
                s.pendingWord = token
                return nil
            }
            if startsNewWord || current.speaker != token.speaker {
                s.pendingWord = token
                return Self.result(from: [current])
            }
            current.text += token.text
            current.end = token.end
            s.pendingWord = current
            return nil
        }
    }

    private func flushPendingWord() {
        let word: TimedWord? = state.withLock {
            let w = $0.pendingWord
            $0.pendingWord = nil
            return w
        }
        if let word { updates?(EngineUpdate(finals: [Self.result(from: [word])], volatile: nil)) }
    }

    static func result(from words: [TimedWord]) -> EngineResult {
        EngineResult(
            start: words.first?.start ?? 0,
            end: words.last?.end ?? 0,
            text: words.map(\.text).joined(),
            words: words,
            speaker: words.first?.speaker
        )
    }

    static func isCJK(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
