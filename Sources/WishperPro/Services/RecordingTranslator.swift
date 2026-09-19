import Foundation

/// A phrase that was translated and read aloud.
struct TranslatedPhrase: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// PCM16 24 kHz mono.
    var audio: Data
}

struct TranslationResult: Sendable {
    /// In the order they were said.
    var phrases: [TranslatedPhrase]
    /// Phrases still without a voice after every try.
    var failed: Int
    var firstError: Error?
}

/// The network steps of a phrase, apart so the self-test can replace them.
struct TranslationSteps: Sendable {
    var transcribe: @Sendable (Phrase) async throws -> String
    var translate: @Sendable (String, [OpenAITextProcessor.NarrationContext]) async throws -> String
    var read: @Sendable (String) async throws -> Data
    var close: @Sendable () async -> Void
}

extension TranslationSteps {
    /// `gpt-transcribe` with the dictionary, `gpt-5.6-luna` for the narration, and GPT-Live's voice.
    static func live(
        apiKey: String,
        source: SupportedLanguage,
        target: SupportedLanguage,
        dictionary: [String],
        voice: String
    ) -> TranslationSteps {
        let reader = GPTLiveReader(apiKey: apiKey, voice: voice)
        let languages = source.isoCode.map { [$0] } ?? []
        let sourceName = source == .auto ? nil : source.translationName
        return TranslationSteps(
            transcribe: { phrase in
                try await OpenAITranscriptionClient().transcribe(
                    wav: WAV.make(pcm16: phrase.pcm),
                    apiKey: apiKey,
                    languages: languages,
                    keywords: dictionary,
                    prompt: nil
                )
            },
            translate: { text, context in
                try await OpenAITextProcessor().process(
                    OpenAITextProcessor.Request(
                        text: text,
                        style: .unchanged,
                        category: .other,
                        appName: "",
                        dictionary: dictionary,
                        sourceLanguage: sourceName,
                        targetLanguage: target.translationName,
                        narration: context
                    ),
                    apiKey: apiKey
                )
            },
            read: { text in try await reader.read(text).audio },
            close: { await reader.close() }
        )
    }
}

/// Translates a screen recording's voice while it is recorded: phrases from `PhraseDetector` are transcribed and
/// translated in order (each with the three before it as context), and read aloud in order, so reading one phrase
/// overlaps with translating the next. Each call gets three tries; what still fails gets one more round at the end.
actor RecordingTranslator {
    private enum Input: Sendable {
        case room(Data)
        case voice(Data, TimeInterval)
    }

    private let steps: TranslationSteps
    private let stream: AsyncStream<Input>
    private nonisolated let input: AsyncStream<Input>.Continuation
    private var detector = PhraseDetector()
    private var context: [OpenAITextProcessor.NarrationContext] = []
    private var translated: [TranslatedPhrase] = []
    /// Each phrase that failed, with its translation when only the voice failed.
    private var failures: [(phrase: Phrase, text: String?)] = []
    private var firstError: Error?
    /// A refused API key fails every call alike: after one, nothing more is sent.
    private var isRefused = false
    private var worker: Task<Void, Never>?

    init(steps: TranslationSteps) {
        self.steps = steps
        (stream, input) = AsyncStream.makeStream(of: Input.self)
    }

    /// Voice from the recorder, in order. Before time zero (`time` nil) it only teaches the room's noise.
    nonisolated func add(_ pcm: Data, at time: TimeInterval?) {
        input.yield(time.map { .voice(pcm, $0) } ?? .room(pcm))
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { await run() }
    }

    /// The recording stopped: the last phrase, what is still on its way, and one more round for what failed.
    func finish() async -> TranslationResult {
        input.finish()
        await worker?.value
        let retry = failures
        failures = []
        for (index, (phrase, text)) in retry.enumerated() {
            let before = failures.count
            if let text {
                await speak(phrase, text)
            } else {
                await translate(phrase, then: nil)
            }
            // A phrase that fails again means the network is still down: the rest stay failed instead of each
            // waiting through its three tries.
            if failures.count > before {
                failures += retry[(index + 1)...]
                break
            }
        }
        await steps.close()
        return TranslationResult(
            phrases: translated.sorted { $0.start < $1.start },
            failed: failures.count,
            firstError: firstError
        )
    }

    /// The recording was cancelled, or the app is quitting.
    func cancel() async {
        input.finish()
        worker?.cancel()
        await steps.close()
    }

    /// Up to three tries, 0.5 s then 1 s apart. A refused key or a cancellation is not tried again.
    static func retrying<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var delay = Duration.milliseconds(500)
        for _ in 0..<2 {
            do {
                return try await operation()
            } catch {
                if error is CancellationError || isRefusal(error) { throw error }
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
        return try await operation()
    }

    static func isRefusal(_ error: Error) -> Bool {
        switch error {
        case GPTLiveError.unauthorized, RealtimeTranscriptionError.unauthorized:
            return true
        case OpenAITranscriptionError.api(let status, _), TextProcessingError.api(let status, _):
            return status == 401
        default:
            return false
        }
    }

    private func run() async {
        let (texts, textQueue) = AsyncStream.makeStream(of: (Phrase, String).self)
        let voices = Task {
            for await (phrase, text) in texts {
                await speak(phrase, text)
            }
        }
        for await item in stream {
            switch item {
            case .room(let pcm):
                detector.prime(pcm)
            case .voice(let pcm, let time):
                for phrase in detector.append(pcm, at: time) {
                    await translate(phrase, then: textQueue)
                }
            }
        }
        for phrase in detector.finish() {
            await translate(phrase, then: textQueue)
        }
        textQueue.finish()
        await voices.value
    }

    /// Transcribes and translates a phrase, then queues it to be read (or reads it now, with no queue).
    private func translate(_ phrase: Phrase, then queue: AsyncStream<(Phrase, String)>.Continuation?) async {
        guard !isRefused else {
            failures.append((phrase, nil))
            return
        }
        let steps = steps
        do {
            let source = try await Self.retrying { try await steps.transcribe(phrase) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Noise or a cough: nothing to say.
            guard !source.isEmpty else { return }
            let context = context
            let text = try await Self.retrying { try await steps.translate(source, context) }
            self.context = Array((self.context + [.init(source: source, translation: text)]).suffix(3))
            // A hesitation: nothing to read.
            guard !text.isEmpty else { return }
            if let queue {
                queue.yield((phrase, text))
            } else {
                await speak(phrase, text)
            }
        } catch {
            record(error, phrase, text: nil)
        }
    }

    private func speak(_ phrase: Phrase, _ text: String) async {
        guard !isRefused else {
            failures.append((phrase, text))
            return
        }
        let steps = steps
        do {
            let audio = try await Self.retrying { try await steps.read(text) }
            translated.append(TranslatedPhrase(start: phrase.start, end: phrase.end, text: text, audio: audio))
        } catch {
            record(error, phrase, text: text)
        }
    }

    private func record(_ error: Error, _ phrase: Phrase, text: String?) {
        guard !(error is CancellationError) else { return }
        failures.append((phrase, text))
        if firstError == nil { firstError = error }
        if Self.isRefusal(error) { isRefused = true }
    }
}
