import AVFAudio
import CoreMedia
import Foundation
import Speech

/// On-device transcription with SpeechAnalyzer / SpeechTranscriber (macOS 26).
nonisolated final class AppleSpeechTranscriber: StreamingTranscriber, @unchecked Sendable {
    let displayName = "Apple on-device"
    let providesDiarization = false

    private let localeID: String
    private let terms: [String]
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: StreamConverter?
    private var resultsTask: Task<Void, Never>?

    init(language: String, terms: [String]) {
        // Apple has one model per locale; for mixed meetings the Mandarin
        // model copes with English words better than the reverse.
        self.localeID = language == "mixed" ? "zh-CN" : language
        self.terms = terms
    }

    func start(updates: @escaping @Sendable (EngineUpdate) -> Void) async throws {
        let locale = try await Self.resolveLocale(localeID)
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        try await Self.ensureAssets(for: module, progress: nil)

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.audioFormat
        }
        converter = StreamConverter(to: format)
        try await analyzer.prepareToAnalyze(in: format)
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try? await analyzer.setContext(context)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.input = continuation
        self.module = module
        self.analyzer = analyzer

        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in module.results {
                    let mapped = Self.map(result)
                    if result.isFinal {
                        updates(EngineUpdate(finals: mapped.text.trimmed.isEmpty ? [] : [mapped], volatile: nil))
                    } else {
                        updates(EngineUpdate(finals: [], volatile: mapped.text.trimmed.isEmpty ? nil : mapped))
                    }
                }
            } catch {
                Log.asr.error("Apple transcriber results ended: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter?.convert(buffer) else { return }
        input?.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        input?.finish()
        input = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.asr.error("Finalize failed: \(error.localizedDescription)")
        }
        // Let the results loop drain the last finals.
        _ = await resultsTask?.result
        analyzer = nil
        module = nil
    }

    // MARK: Helpers

    static func map(_ result: SpeechTranscriber.Result) -> EngineResult {
        let text = String(result.text.characters)
        var words: [TimedWord] = []
        var confidences: [Double] = []
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            if let c = run.transcriptionConfidence { confidences.append(c) }
            guard let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite else {
                // Untimed pieces (usually punctuation) stick to the previous word.
                if !words.isEmpty { words[words.count - 1].text += piece }
                continue
            }
            let end = range.end.seconds
            // The analyzer folds preceding silence into a word's range (very
            // visible on the first word after a pause); word ends are
            // accurate, so cap each word at a plausible spoken length.
            let start = max(range.start.seconds, end - plausibleDuration(of: piece))
            words.append(TimedWord(text: piece, start: start, end: end))
        }
        let start = words.first?.start ?? result.range.start.seconds
        let end = result.range.end.seconds
        return EngineResult(
            start: start.isFinite ? start : 0,
            end: end.isFinite ? end : (words.last?.end ?? 0),
            text: text,
            words: words,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
    }

    /// Generous upper bound for how long a word takes to say.
    static func plausibleDuration(of word: String) -> Double {
        var seconds = 0.3
        for ch in word where !ch.isWhitespace && !ch.isPunctuation {
            seconds += ch.isCJKIdeograph ? 0.32 : 0.09
        }
        return seconds
    }

    static func resolveLocale(_ identifier: String) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw TranscriberError.unsupportedLanguage(identifier)
        }
        return locale
    }

    /// Download the on-device model for a locale if needed.
    static func ensureAssets(for module: SpeechTranscriber, progress: (@Sendable (Double) -> Void)?) async throws {
        let status = await AssetInventory.status(forModules: [module])
        if status == .installed { return }
        if status == .unsupported { throw TranscriberError.unsupportedLanguage(module.selectedLocales.first?.identifier ?? "") }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observer = progress.map { cb in
                    request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in cb(p.fractionCompleted) }
                }
                try await request.downloadAndInstall()
                observer?.invalidate()
            }
        } catch {
            throw TranscriberError.assetsUnavailable(error.localizedDescription)
        }
    }

    /// Pre-download a language model (used from Settings / onboarding).
    static func prepareLanguage(_ identifier: String, progress: (@Sendable (Double) -> Void)?) async throws {
        let locale = try await resolveLocale(identifier == "mixed" ? "zh-CN" : identifier)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: module, progress: progress)
    }

    static func isLanguageInstalled(_ identifier: String) async -> Bool {
        guard let locale = try? await resolveLocale(identifier == "mixed" ? "zh-CN" : identifier) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
}
