import AVFoundation
import Foundation

enum DictationError: LocalizedError {
    case noSpeech

    var errorDescription: String? {
        "Não ouvi nada."
    }
}

/// One dictation: microphone → live transcription → final text, falling back to `gpt-transcribe`
/// with the recorded audio when the live connection fails.
@MainActor
final class DictationSession {
    struct Options: Sendable {
        var apiKey: String
        var languages: [String]
        var prompt: String?
        var keywords: [String] = []
    }

    /// A 100 ms chunk above this level counts as speech (the threshold the old meter used).
    static let speechThreshold = 0.12

    /// Accumulated live text and the latest level, on the main actor.
    var onUpdate: (@MainActor (_ liveText: String, _ level: Double) -> Void)?
    /// The microphone stopped and couldn't restart (e.g. the input device went away); the owner should call `finish()`.
    var onInterruption: (@MainActor () -> Void)?

    private(set) var heardSpeech = false
    private(set) var usedFallback = false

    private let options: Options
    private let microphone = MicrophoneStream()
    private let fallbackClient = OpenAITranscriptionClient()
    private var transcriber: OpenAIRealtimeTranscriber?
    private var audioSink: AsyncStream<(Data, Double)>.Continuation?
    private var deltaSink: AsyncStream<String>.Continuation?
    private var audioPump: Task<Void, Never>?
    private var liveText = ""
    private var level = 0.0

    init(options: Options) {
        self.options = options
    }

    /// Starts the microphone and the live connection in parallel.
    func start() throws {
        let sink = openConnection()
        try microphone.start(
            onChunk: { chunk, level in sink.yield((chunk, level)) },
            onInterruption: { [weak self] in
                Task { @MainActor in self?.onInterruption?() }
            }
        )
    }

    /// Like `start()` but without the microphone: the self-test feeds audio into the returned stream.
    func startWithoutMicrophone(inputFormat: AVAudioFormat) throws -> MicrophoneStream {
        let sink = openConnection()
        try microphone.prepare(inputFormat: inputFormat) { chunk, level in sink.yield((chunk, level)) }
        return microphone
    }

    /// Stops the microphone and returns the final text.
    func finish() async throws -> String {
        microphone.stop()
        audioSink?.finish()
        await audioPump?.value
        guard heardSpeech, let transcriber else {
            await close()
            throw DictationError.noSpeech
        }
        do {
            let text = try await transcriber.commit()
            await close()
            return text
        } catch RealtimeTranscriptionError.unauthorized {
            await close()
            throw RealtimeTranscriptionError.unauthorized
        } catch {
            await close()
            usedFallback = true
            return try await fallbackClient.transcribe(
                wav: WAV.make(pcm16: microphone.recordedAudio),
                apiKey: options.apiKey,
                languages: options.languages,
                keywords: options.keywords,
                prompt: options.prompt
            )
        }
    }

    /// Discards everything without transcribing.
    func cancel() {
        microphone.stop()
        audioSink?.finish()
        Task { await close() }
    }

    /// Audio and deltas go through AsyncStreams so they keep their order across actors.
    private func openConnection() -> AsyncStream<(Data, Double)>.Continuation {
        let (audio, audioSink) = AsyncStream.makeStream(of: (Data, Double).self)
        let (deltas, deltaSink) = AsyncStream.makeStream(of: String.self)
        let transcriber = OpenAIRealtimeTranscriber(
            apiKey: options.apiKey,
            configuration: .init(languages: options.languages, prompt: options.prompt, keywords: options.keywords),
            onDelta: { deltaSink.yield($0) }
        )
        self.transcriber = transcriber
        self.audioSink = audioSink
        self.deltaSink = deltaSink
        Task { await transcriber.connect() }
        audioPump = Task { [weak self] in
            for await (chunk, level) in audio {
                await transcriber.append(chunk)
                self?.receive(level: level)
            }
        }
        Task { [weak self] in
            for await delta in deltas {
                self?.receive(delta: delta)
            }
        }
        return audioSink
    }

    private func receive(level: Double) {
        self.level = level
        if level > Self.speechThreshold {
            heardSpeech = true
        }
        onUpdate?(liveText, level)
    }

    private func receive(delta: String) {
        liveText += delta
        onUpdate?(liveText, level)
    }

    private func close() async {
        deltaSink?.finish()
        await transcriber?.close()
    }
}
