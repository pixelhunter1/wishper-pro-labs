import Foundation

/// A GPT-Live voice: its name in the API and how it sounds.
struct LiveVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// OpenAI documents the accent of the voices that came with GPT-Live; the older ones have none.
    let accent: String?

    var label: String {
        accent.map { "\(name) — \($0)" } ?? name
    }

    static let defaultID = "meridian"

    /// The voices GPT-Live accepted on 2026-09-19 (it refuses fable, onyx and nova), the new ones first.
    static let all: [LiveVoice] = [
        LiveVoice(id: "meridian", name: "Meridian", accent: "inglês norte-americano, masculina"),
        LiveVoice(id: "gleam", name: "Gleam", accent: "inglês norte-americano, feminina"),
        LiveVoice(id: "vesper", name: "Vesper", accent: "inglês britânico, masculina"),
        LiveVoice(id: "willow", name: "Willow", accent: "inglês irlandês, feminina"),
        LiveVoice(id: "stone", name: "Stone", accent: "inglês irlandês, masculina"),
        LiveVoice(id: "quartz", name: "Quartz", accent: "inglês australiano, feminina"),
        LiveVoice(id: "ripple", name: "Ripple", accent: "inglês australiano, masculina"),
        LiveVoice(id: "delta", name: "Delta", accent: "inglês do sul dos EUA, feminina"),
        LiveVoice(id: "cinder", name: "Cinder", accent: "inglês do sul dos EUA, masculina"),
        LiveVoice(id: "beacon", name: "Beacon", accent: "inglês filipino, masculina"),
        LiveVoice(id: "bossa", name: "Bossa", accent: "português do Brasil, feminina"),
        LiveVoice(id: "tempo", name: "Tempo", accent: "português do Brasil, masculina"),
        LiveVoice(id: "marin", name: "Marin", accent: nil),
        LiveVoice(id: "cedar", name: "Cedar", accent: nil),
        LiveVoice(id: "alloy", name: "Alloy", accent: nil),
        LiveVoice(id: "ash", name: "Ash", accent: nil),
        LiveVoice(id: "ballad", name: "Ballad", accent: nil),
        LiveVoice(id: "coral", name: "Coral", accent: nil),
        LiveVoice(id: "echo", name: "Echo", accent: nil),
        LiveVoice(id: "sage", name: "Sage", accent: nil),
        LiveVoice(id: "shimmer", name: "Shimmer", accent: nil),
        LiveVoice(id: "verse", name: "Verse", accent: nil),
    ]

    /// A saved voice that is no longer offered becomes the default.
    static func stored(_ id: String?) -> String {
        all.contains { $0.id == id } ? id ?? defaultID : defaultID
    }
}

/// How the narrator should sound. The voice picks the timbre and the accent; this picks the delivery, which is what
/// makes a reading sound like a person rather than a system voice.
enum NarrationTone: String, CaseIterable, Identifiable, Sendable {
    case calm
    case conversational
    case lively
    case documentary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: return "Calmo"
        case .conversational: return "Conversa"
        case .lively: return "Animado"
        case .documentary: return "Documentário"
        }
    }

    var detail: String {
        switch self {
        case .calm: return "Suave e contido. O que a app usava antes."
        case .conversational: return "Como quem explica a um colega, com o à-vontade da fala normal."
        case .lively: return "Desperto e com energia, para demonstrações e redes sociais."
        case .documentary: return "Pausado e seguro, com peso nas palavras que contam."
        }
    }

    /// Added to the narrator's brief. Kept as delivery only: never a licence to change the words.
    var instruction: String {
        switch self {
        case .calm:
            return "Read in a soft, calm, natural voice."
        case .conversational:
            return "Read the way a person explains something to a colleague: warm and relaxed, with the light stresses and rhythm of ordinary speech."
        case .lively:
            return "Read with energy and a bright, engaged tone, leaning into the words that carry the point, as a good demo narrator would."
        case .documentary:
            return "Read at a measured pace with a confident, grounded tone, giving weight to the words that matter, as a documentary narrator would."
        }
    }

    /// A saved tone that no longer exists becomes the default.
    static func stored(_ value: String?) -> NarrationTone {
        NarrationTone(rawValue: value ?? "") ?? .calm
    }
}

enum GPTLiveError: LocalizedError {
    case unauthorized
    case timeout
    case silent
    case server(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "A API key é inválida."
        case .timeout: return "A voz não respondeu a tempo."
        case .silent: return "A voz não leu a frase."
        case .server(let message): return "Erro OpenAI (voz): \(message)"
        case .connection(let message): return "Falha na ligação à voz: \(message)"
        }
    }
}

/// Reads text aloud with GPT-Live (`gpt-live-1`), word for word and one text at a time, in a session that stays open
/// between texts (it is billed per second while open). Measured on 2026-09-19: verbatim in 13 readings of 13 (English,
/// Portuguese, Spanish, French, German, Italian, and a text with an instruction in it), first sound after 0.7–2.1 s.
actor GPTLiveReader {
    struct Reading: Sendable {
        /// PCM16 24 kHz mono, without the silence around the words.
        var audio: Data
        /// What GPT-Live said, from its transcript.
        var transcript: String
    }

    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static let model = "gpt-live-1"
    /// The part of the narrator's brief that never changes; `NarrationTone` adds how it should sound.
    static let narrator = "You are a voice-over narrator for a screen recording. Never converse, never greet, never add or change words. When you receive commentary, read it aloud exactly as written, word for word. Take your time: speak at an unhurried narration pace of about 120 words per minute, the pace of someone explaining their own screen, not of someone reading a script quickly. Then stay silent."
    /// Output audio at or above this level (dBFS) is speech; the rest is the silence GPT-Live streams between texts.
    static let speechLevel = -45.0
    /// Share of a text's words its transcript must hold for the reading to count as word for word.
    static let minimumKept = 0.9
    private static let startTimeout: Duration = .seconds(8)
    private static let readTimeout: Duration = .seconds(25)
    // GPT-Live listens all the time, so it gets 100 ms of silence every 100 ms.
    private static let silenceJSON = #"{"type":"session.input_audio.append","audio":""#
        + Data(count: PCM16.chunkBytes).base64EncodedString() + #""}"#

    private let apiKey: String
    private let voice: String
    private let tone: NarrationTone
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isStarted = false
    private var isClosedByServer = false
    /// Set by `close()`: the reader never connects again.
    private var isClosed = false
    private var failure: Error?
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var silence: Task<Void, Never>?
    // The text being read: its audio, what was said and when the last speech arrived.
    private var chunks: [Data] = []
    private var transcript = ""
    private var lastSpeech: ContinuousClock.Instant?
    private var isReading = false

    init(apiKey: String, voice: String, tone: NarrationTone = .calm) {
        self.apiKey = apiKey
        self.voice = voice
        self.tone = tone
    }

    /// Reads `text` aloud. A reading that misses words is read again once, and the one with more words stays.
    func read(_ text: String) async throws -> Reading {
        var best: Reading?
        for _ in 0..<2 {
            let reading = try await readOnce(text)
            let kept = Self.wordsKept(text, in: reading.transcript)
            if kept >= Self.minimumKept { return reading }
            if best.map({ kept > Self.wordsKept(text, in: $0.transcript) }) ?? true {
                best = reading
            }
        }
        guard let best, !best.audio.isEmpty else { throw GPTLiveError.silent }
        return best
    }

    /// Ends the session (and its billing) for good: a read waiting for the session throws, and no later read connects.
    func close() async {
        isClosed = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        await disconnect()
    }

    /// Closes the socket, with `session.close` first when the session started. The reader can connect again.
    private func disconnect() async {
        silence?.cancel()
        silence = nil
        guard let task else { return }
        if isStarted {
            send(#"{"type":"session.close"}"#)
            for _ in 0..<40 where !isClosedByServer && failure == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        self.task = nil
        session = nil
        isStarted = false
    }

    nonisolated static func startJSON(voice: String, tone: NarrationTone = .calm) -> String {
        json([
            "type": "session.start",
            "session": [
                "model": model,
                "instructions": "\(narrator) \(tone.instruction)",
                "audio": [
                    "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                    // GPT-Live has no speed parameter: session.audio.output.speed is refused. The pace is asked for
                    // in the narrator's brief instead.
                    "output": ["voice": voice],
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    nonisolated static func commentaryJSON(_ text: String) -> String {
        json(["type": "session.commentary.append", "delegation_id": NSNull(), "content": text])
    }

    /// Share of `text`'s words found in `said`, ignoring case, accents and punctuation.
    nonisolated static func wordsKept(_ text: String, in said: String) -> Double {
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let expected = words(text)
        guard !expected.isEmpty else { return 1 }
        let heard = Set(words(said))
        return Double(expected.filter(heard.contains).count) / Double(expected.count)
    }

    /// The audio from the first to the last chunk with speech, with one chunk of margin on each side.
    nonisolated static func trimmed(_ chunks: [Data]) -> Data {
        let speech = chunks.map { PCM16.decibels(of: $0) >= speechLevel }
        guard let first = speech.firstIndex(of: true), let last = speech.lastIndex(of: true) else { return Data() }
        return chunks[max(0, first - 1)...min(chunks.count - 1, last + 1)].reduce(into: Data()) { $0.append($1) }
    }

    private nonisolated static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// One reading. It ends when the transcript holds every word and 300 ms passed without speech, or after 1.5 s
    /// without speech, or at the time limit.
    private func readOnce(_ text: String) async throws -> Reading {
        try await start()
        chunks = []
        transcript = ""
        lastSpeech = nil
        isReading = true
        defer { isReading = false }
        send(Self.commentaryJSON(text))
        let begin = ContinuousClock.now
        while true {
            try await Task.sleep(for: .milliseconds(50))
            if isClosed { throw CancellationError() }
            if let failure { throw failure }
            let now = ContinuousClock.now
            if let lastSpeech {
                let quiet = now - lastSpeech
                if quiet >= .milliseconds(1_500) || (quiet >= .milliseconds(300) && Self.wordsKept(text, in: transcript) >= 1) {
                    break
                }
            }
            if now - begin >= Self.readTimeout {
                guard lastSpeech != nil else {
                    // A session that stays silent is dead: the next read connects again.
                    fail(GPTLiveError.timeout)
                    throw GPTLiveError.timeout
                }
                break
            }
        }
        return Reading(audio: Self.trimmed(chunks), transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Opens the session if needed (again after a dropped one) and waits for `session.started`.
    private func start() async throws {
        if isClosed { throw CancellationError() }
        if failure != nil {
            await disconnect()
            failure = nil
        }
        // close() may have run while disconnecting.
        if isClosed { throw CancellationError() }
        if isStarted { return }
        if task == nil { connect() }
        try await withCheckedThrowingContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func connect() {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        isClosedByServer = false
        task.resume()
        send(Self.startJSON(voice: voice, tone: tone))
        Task { await self.receive(from: task) }
        Task {
            try? await Task.sleep(for: Self.startTimeout)
            self.failIfNotStarted(task)
        }
    }

    private func receive(from task: URLSessionWebSocketTask) async {
        while self.task === task {
            do {
                switch try await task.receive() {
                case .string(let text): handle(text)
                case .data(let data): handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                failFromTransport(error, on: task)
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = RealtimeEvent.parse(text) else { return }
        switch event.type {
        case "session.started":
            isStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            startSilence()
        case "session.output_audio.delta":
            guard isReading, let delta = event.delta, let audio = Data(base64Encoded: delta) else { return }
            chunks.append(audio)
            if PCM16.decibels(of: audio) >= Self.speechLevel {
                lastSpeech = .now
            }
        case "session.output_transcript.delta":
            if isReading, let delta = event.delta {
                transcript += delta
            }
        case "session.closed":
            isClosedByServer = true
        case "error":
            fail(event.error?.code == "invalid_api_key"
                ? GPTLiveError.unauthorized
                : GPTLiveError.server(event.error?.message ?? "erro desconhecido"))
        default:
            break
        }
    }

    private func startSilence() {
        silence?.cancel()
        silence = Task {
            while !Task.isCancelled {
                send(Self.silenceJSON)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func send(_ text: String) {
        guard let task else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            Task { await self.failFromTransport(error, on: task) }
        }
    }

    private func failIfNotStarted(_ task: URLSessionWebSocketTask) {
        if self.task === task, !isStarted {
            fail(GPTLiveError.timeout)
        }
    }

    /// An error from a socket that was already replaced (after a reconnect) is ignored.
    private func failFromTransport(_ error: Error, on task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        if (task.response as? HTTPURLResponse)?.statusCode == 401 {
            fail(GPTLiveError.unauthorized)
        } else {
            fail(GPTLiveError.connection(error.localizedDescription))
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        startWaiters.forEach { $0.resume(throwing: error) }
        startWaiters.removeAll()
        silence?.cancel()
        silence = nil
        isStarted = false
    }
}

/// A short sample of a voice in a language, for the Settings. Cached, so only the first listen reaches the API.
enum VoicePreview {
    static func sentence(_ language: SupportedLanguage) -> String {
        switch language {
        case .portuguesePT: return "Olá! É assim que as tuas gravações vão soar com esta voz."
        case .portugueseBR: return "Oi! É assim que as suas gravações vão soar com esta voz."
        case .spanish: return "¡Hola! Así sonarán tus grabaciones con esta voz."
        case .french: return "Bonjour ! Voici comment vos enregistrements sonneront avec cette voix."
        case .german: return "Hallo! So klingen deine Aufnahmen mit dieser Stimme."
        case .italian: return "Ciao! Ecco come suoneranno le tue registrazioni con questa voce."
        case .english, .auto: return "Hi! This is how your screen recordings will sound with this voice."
        }
    }

    /// The tone is part of the name: the same voice read calmly and read lively are different samples.
    static func cachedURL(voice: String, language: SupportedLanguage, tone: NarrationTone) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wishper.pro", isDirectory: true)
            .appendingPathComponent("Vozes", isDirectory: true)
            .appendingPathComponent("\(voice)-\(tone.rawValue)-\(language.rawValue).wav")
    }

    /// The sample's file: from the cache, or read now.
    static func sample(voice: String, language: SupportedLanguage, tone: NarrationTone, apiKey: String) async throws -> URL {
        let url = cachedURL(voice: voice, language: language, tone: tone)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let reader = GPTLiveReader(apiKey: apiKey, voice: voice, tone: tone)
        let reading: GPTLiveReader.Reading
        do {
            reading = try await reader.read(sentence(language))
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WAV.make(pcm16: reading.audio).write(to: url, options: .atomic)
        return url
    }
}
