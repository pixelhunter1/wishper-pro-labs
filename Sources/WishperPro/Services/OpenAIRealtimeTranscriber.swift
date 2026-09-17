import Foundation

enum RealtimeTranscriptionError: LocalizedError {
    case unauthorized
    case timeout
    case server(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "A API key é inválida."
        case .timeout:
            return "A ligação ao vivo não respondeu a tempo."
        case .server(let message):
            return "Erro OpenAI (ao vivo): \(message)"
        case .connection(let message):
            return "Falha na ligação ao vivo: \(message)"
        }
    }
}

/// The subset of Realtime server events the app reads.
struct RealtimeEvent: Decodable, Sendable {
    struct ErrorInfo: Decodable, Sendable {
        let message: String?
        let code: String?
    }

    let type: String
    let delta: String?
    let transcript: String?
    let error: ErrorInfo?

    static func parse(_ text: String) -> RealtimeEvent? {
        try? JSONDecoder().decode(RealtimeEvent.self, from: Data(text.utf8))
    }
}

/// Live transcription over the Realtime WebSocket (`gpt-live-transcribe`, one manual commit per session).
actor OpenAIRealtimeTranscriber {
    struct Configuration: Sendable {
        var model = "gpt-live-transcribe"
        var languages: [String] = []
        var prompt: String?
        // Calibration knob: "minimal" ≈ 0.7 s to first text, "low" ≈ 1.2 s, higher values trade speed for stability.
        var delay = "low"
        /// Personal dictionary: literal terms (no `<`, `>` or line breaks) the model should recognise.
        var keywords: [String] = []
    }

    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    private static let readyTimeout: Duration = .seconds(5)
    private static let finalTimeout: Duration = .seconds(8)

    private let apiKey: String
    private let configuration: Configuration
    private let onDelta: @Sendable (String) -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isReady = false
    private var isClosed = false
    private var hasCommitted = false
    private var failure: Error?
    private var finalTranscript: String?
    private var queuedAudio: [Data] = []
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var finalWaiter: CheckedContinuation<String, Error>?

    init(apiKey: String, configuration: Configuration, onDelta: @escaping @Sendable (String) -> Void) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.onDelta = onDelta
    }

    /// Opens the socket and configures the session. Failures are kept and surface in `commit()`.
    func connect() {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        send(Self.sessionUpdateJSON(configuration))
        Task { await self.receiveLoop() }
        Task {
            try? await Task.sleep(for: Self.readyTimeout)
            self.failIfNotReady()
        }
    }

    /// Sends audio in order; audio received before `session.updated` is queued.
    func append(_ chunk: Data) {
        guard failure == nil, !isClosed else { return }
        if isReady {
            send(Self.appendJSON(chunk))
        } else {
            queuedAudio.append(chunk)
        }
    }

    /// Commits the buffered audio and waits for the final transcript.
    func commit() async throws -> String {
        try await waitUntilReady()
        hasCommitted = true
        send(#"{"type":"input_audio_buffer.commit"}"#)
        Task {
            try? await Task.sleep(for: Self.finalTimeout)
            self.fail(with: RealtimeTranscriptionError.timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            finalWaiter = continuation
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let error = CancellationError()
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        finalWaiter?.resume(throwing: error)
        finalWaiter = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
    }

    nonisolated static func sessionUpdateJSON(_ configuration: Configuration) -> String {
        var transcription: [String: Any] = [
            "model": configuration.model,
            "delay": configuration.delay,
        ]
        if !configuration.languages.isEmpty {
            transcription["languages"] = configuration.languages
        }
        if let prompt = configuration.prompt, !prompt.isEmpty {
            transcription["prompt"] = prompt
        }
        if !configuration.keywords.isEmpty {
            transcription["keywords"] = configuration.keywords
        }
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
            "transcription": transcription,
            "turn_detection": NSNull(),
        ]
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input],
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func appendJSON(_ chunk: Data) -> String {
        #"{"type":"input_audio_buffer.append","audio":""# + chunk.base64EncodedString() + #""}"#
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            Task { await self.failFromTransport(error) }
        }
    }

    private func receiveLoop() async {
        while let task, !isClosed {
            do {
                switch try await task.receive() {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    handle(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                failFromTransport(error)
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = RealtimeEvent.parse(text) else { return }
        switch event.type {
        case "session.updated":
            guard !isReady else { return }
            isReady = true
            queuedAudio.forEach { send(Self.appendJSON($0)) }
            queuedAudio.removeAll()
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event.delta, !delta.isEmpty {
                onDelta(delta)
            }
        case "conversation.item.input_audio_transcription.completed":
            guard hasCommitted, finalTranscript == nil else { return }
            let transcript = event.transcript ?? ""
            finalTranscript = transcript
            finalWaiter?.resume(returning: transcript)
            finalWaiter = nil
        case "error":
            if event.error?.code == "invalid_api_key" {
                fail(with: RealtimeTranscriptionError.unauthorized)
            } else {
                fail(with: RealtimeTranscriptionError.server(event.error?.message ?? "erro desconhecido"))
            }
        default:
            break
        }
    }

    private func waitUntilReady() async throws {
        if let failure { throw failure }
        if isReady { return }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    private func failIfNotReady() {
        if !isReady {
            fail(with: RealtimeTranscriptionError.timeout)
        }
    }

    private func failFromTransport(_ error: Error) {
        if (task?.response as? HTTPURLResponse)?.statusCode == 401 {
            fail(with: RealtimeTranscriptionError.unauthorized)
        } else {
            fail(with: RealtimeTranscriptionError.connection(error.localizedDescription))
        }
    }

    private func fail(with error: Error) {
        guard failure == nil, finalTranscript == nil, !isClosed else { return }
        failure = error
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        finalWaiter?.resume(throwing: error)
        finalWaiter = nil
        task?.cancel(with: .goingAway, reason: nil)
    }
}
