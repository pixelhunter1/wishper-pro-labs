import AppKit
import AVFoundation
import Foundation

@main
enum AppEntry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest") {
            let audioPath = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            SelfTest.run(audioPath: audioPath)
        }
        WishperProApp.main()
    }
}

/// Thread-safe list for collecting callback results in the self-test.
final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// `WishperPro --selftest [audio]`: offline checks, plus live and fallback transcription when an audio file is given.
@MainActor
enum SelfTest {
    private static var failures = 0
    /// Same sentence `scripts/run-dev-app.sh --selftest` speaks with `say -v Joana`.
    private static let spokenSentence = "Olá, isto é um teste do Wishper Pro. O ditado ao vivo está a funcionar."
    /// Speech models vary between runs (synthetic voice); a real failure (empty or cut text) scores far lower.
    private static let minimumOverlap = 0.6

    static func run(audioPath: String?) -> Never {
        print("== Verificações offline ==")
        runOfflineChecks()
        guard let audioPath else { finish() }
        Task {
            print("== Verificações online (\(audioPath)) ==")
            await runOnlineChecks(audioURL: URL(fileURLWithPath: audioPath))
            finish()
        }
        dispatchMain()
    }

    static func check(_ condition: Bool, _ label: String) {
        if !condition { failures += 1 }
        print(condition ? "  ok      \(label)" : "  FALHOU  \(label)")
    }

    private static func finish() -> Never {
        print(failures == 0 ? "== Tudo OK ==" : "== \(failures) verificação(ões) falhada(s) ==")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runOfflineChecks() {
        check(CommandLine.arguments.contains("--selftest"), "autoteste arrancou sem abrir a app")
        checkBrandMark()
        checkHotkeyDecisions()
        checkAudioConversion()
        checkInputSwitch()
        checkRealtimeProtocol()
        checkClipboardRestore()
        checkFallbackRequest()
        checkWordOverlap()
        checkStyleCatalog()
        checkPersonalDictionary()
        checkTextSettings()
    }

    private static func runOnlineChecks(audioURL: URL) async {
        check(FileManager.default.fileExists(atPath: audioURL.path), "ficheiro de áudio existe")
        guard let apiKey = KeychainService().loadAPIKey(), !apiKey.isEmpty else {
            check(false, "API key no Keychain (abre a app dev, guarda a key nas Definições e repete)")
            return
        }
        await checkLiveTranscriber(audioURL: audioURL, apiKey: apiKey)
        await checkDictationSession(audioURL: audioURL, apiKey: apiKey)
        await checkInvalidKey(audioURL: audioURL)
    }

    /// A rejected key must surface as "A API key é inválida." without trying the fallback.
    private static func checkInvalidKey(audioURL: URL) async {
        let session = DictationSession(options: .init(apiKey: "sk-invalid-selftest", languages: ["pt"], prompt: nil))
        let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let microphone = try session.startWithoutMicrophone(inputFormat: toneFormat)
            for chunk in 0..<10 {
                microphone.ingest(sineBuffer(format: toneFormat, frames: 4_800, startFrame: chunk * 4_800))
            }
            _ = try await session.finish()
            check(false, "key inválida: devia falhar")
        } catch RealtimeTranscriptionError.unauthorized {
            check(!session.usedFallback, "key inválida: \"A API key é inválida.\" sem plano B")
        } catch {
            check(false, "key inválida: deu outro erro (\(error.localizedDescription))")
        }
    }

    private static func checkDictationSession(audioURL: URL, apiKey: String) async {
        guard let file = try? AVAudioFile(forReading: audioURL) else {
            check(false, "sessão: ler o ficheiro de áudio")
            return
        }
        let session = DictationSession(options: .init(apiKey: apiKey, languages: ["pt"], prompt: nil))
        var firstLiveText: TimeInterval?
        let started = Date()
        session.onUpdate = { text, _ in
            if firstLiveText == nil, !text.isEmpty {
                firstLiveText = Date().timeIntervalSince(started)
            }
        }
        do {
            let microphone = try session.startWithoutMicrophone(inputFormat: file.processingFormat)
            let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                try file.read(into: buffer, frameCount: frames)
                microphone.ingest(buffer)
                try await Task.sleep(for: .milliseconds(100))
            }
            let stoppedAt = Date()
            let text = try await session.finish()
            print("    sessão: texto ao vivo após \(format(firstLiveText ?? -1)) s; final \(format(Date().timeIntervalSince(stoppedAt))) s após parar: \(text)")
            check(session.heardSpeech, "sessão: voz detetada")
            check(firstLiveText != nil, "sessão: texto ao vivo chegou antes do fim")
            check(!session.usedFallback, "sessão: texto final veio da ligação ao vivo")
            checkTranscript(text, "sessão: texto final reconhecível")

            let fallback = try await OpenAITranscriptionClient().transcribe(
                wav: WAV.make(pcm16: microphone.recordedAudio),
                apiKey: apiKey,
                languages: ["pt"],
                prompt: nil
            )
            print("    plano B: \(fallback)")
            checkTranscript(fallback, "plano B: gpt-transcribe com languages[]")
        } catch {
            check(false, "sessão: \(error.localizedDescription)")
        }

        let silent = DictationSession(options: .init(apiKey: apiKey, languages: ["pt"], prompt: nil))
        do {
            let silenceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let microphone = try silent.startWithoutMicrophone(inputFormat: silenceFormat)
            let buffer = AVAudioPCMBuffer(pcmFormat: silenceFormat, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            microphone.ingest(buffer)
            _ = try await silent.finish()
            check(false, "sessão: silêncio devia dar \"Não ouvi nada\"")
        } catch DictationError.noSpeech {
            check(true, "sessão: silêncio dá \"Não ouvi nada\" sem commit")
        } catch {
            check(false, "sessão: silêncio deu outro erro: \(error.localizedDescription)")
        }
    }

    private static func checkLiveTranscriber(audioURL: URL, apiKey: String) async {
        let chunks: [Data]
        do {
            chunks = try pcmChunks(from: audioURL)
        } catch {
            check(false, "ler o ficheiro de áudio: \(error.localizedDescription)")
            return
        }
        let started = Date()
        let deltas = LockedList<(TimeInterval, String)>()
        var configuration = OpenAIRealtimeTranscriber.Configuration(languages: ["pt"])
        if let delay = ProcessInfo.processInfo.environment["WISHPER_SELFTEST_DELAY"] {
            configuration.delay = delay
        }
        print("    delay: \(configuration.delay)")
        let transcriber = OpenAIRealtimeTranscriber(
            apiKey: apiKey,
            configuration: configuration,
            onDelta: { deltas.append((Date().timeIntervalSince(started), $0)) }
        )
        await transcriber.connect()
        for chunk in chunks {
            await transcriber.append(chunk)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let committedAt = Date()
        do {
            let text = try await transcriber.commit()
            let received = deltas.all
            print("    \(received.count) deltas; primeiro após \(format(received.first?.0 ?? -1)) s")
            print("    final \(format(Date().timeIntervalSince(committedAt))) s após o commit: \(text)")
            check(!received.isEmpty, "ao vivo: chegaram deltas enquanto se falava")
            checkTranscript(text, "ao vivo: texto final reconhecível")
        } catch {
            check(false, "ao vivo: \(error.localizedDescription)")
        }
        await transcriber.close()
    }

    private static func pcmChunks(from url: URL) throws -> [Data] {
        let file = try AVAudioFile(forReading: url)
        let stream = MicrophoneStream()
        let chunks = LockedList<Data>()
        try stream.prepare(inputFormat: file.processingFormat) { chunk, _ in chunks.append(chunk) }
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            stream.ingest(buffer)
        }
        stream.stop()
        return chunks.all
    }

    private static func checkBrandMark() {
        let mark = BrandMark.image(pointSize: 18)
        check(mark.isTemplate, "marca: imagem template (adapta-se a claro/escuro)")
        if Bundle.main.url(forResource: "BrandMark", withExtension: "svg") != nil {
            check(mark.size == NSSize(width: 18, height: 18), "marca: 18 pt a partir do BrandMark.svg")
            check(mark.representations.count == 2, "marca: versões @1x e @2x")
        } else {
            print("  info    BrandMark.svg não está no bundle; a usar o símbolo waveform")
        }
    }

    private static func checkHotkeyDecisions() {
        func action(
            _ behavior: HotkeyBehavior,
            _ event: HotkeyEvent,
            _ state: HotkeyState,
            held: TimeInterval = 0
        ) -> HotkeyAction {
            HotkeyDecider.action(behavior: behavior, event: event, state: state, heldFor: held)
        }
        let tap = HotkeyDecider.tapThreshold
        check(action(.toggle, .press, .idle) == .start, "atalho alternar: premir em repouso inicia")
        check(action(.toggle, .press, .listening(handsFree: false)) == .stop, "atalho alternar: premir a ouvir termina")
        check(action(.toggle, .release, .listening(handsFree: false)) == .ignore, "atalho alternar: largar é ignorado")
        check(action(.hold, .press, .idle) == .start, "atalho manter: premir inicia")
        check(action(.hold, .release, .listening(handsFree: false), held: 0.1) == .stop, "atalho manter: largar termina")
        check(action(.auto, .press, .idle) == .start, "atalho automático: premir inicia")
        check(
            action(.auto, .release, .listening(handsFree: false), held: tap - 0.1) == .enterHandsFree,
            "atalho automático: toque passa a mãos-livres"
        )
        check(
            action(.auto, .release, .listening(handsFree: false), held: tap + 0.1) == .stop,
            "atalho automático: largar depois de segurar termina"
        )
        check(action(.auto, .press, .listening(handsFree: true)) == .stop, "atalho automático: premir em mãos-livres termina")
        check(action(.auto, .release, .listening(handsFree: true)) == .ignore, "atalho automático: largar em mãos-livres é ignorado")
        check(action(.auto, .press, .busy) == .ignore, "atalho: a finalizar ignora")
    }

    private static func checkAudioConversion() {
        let wav = WAV.make(pcm16: Data(count: PCM16.chunkBytes))
        check(wav.count == 44 + PCM16.chunkBytes, "WAV: cabeçalho de 44 bytes")
        check(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF", "WAV: começa por RIFF")
        check(readUInt32(wav, at: 24) == 24_000, "WAV: 24 kHz")
        check(readUInt32(wav, at: 40) == UInt32(PCM16.chunkBytes), "WAV: tamanho dos dados")
        check(PCM16.level(of: Data(count: PCM16.chunkBytes)) == 0, "nível: silêncio = 0")

        // 1 s of a -20 dBFS sine at 48 kHz in 10 buffers should become ~48 000 bytes in 100 ms chunks.
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let stream = MicrophoneStream()
        let chunks = LockedList<(Data, Double)>()
        do {
            try stream.prepare(inputFormat: inputFormat) { chunk, level in chunks.append((chunk, level)) }
        } catch {
            check(false, "conversor: preparar 48 kHz → 24 kHz")
            return
        }
        for part in 0..<10 {
            stream.ingest(sineBuffer(format: inputFormat, frames: 4_800, startFrame: part * 4_800))
        }
        stream.stop()
        let received = chunks.all
        let total = received.reduce(0) { $0 + $1.0.count }
        check(
            abs(total - PCM16.bytesPerSecond) <= PCM16.bytesPerSecond / 50,
            "conversor: 1 s ≈ 48 000 bytes (obtido \(total))"
        )
        check(received.dropLast().allSatisfy { $0.0.count == PCM16.chunkBytes }, "conversor: pedaços de 100 ms")
        check(stream.recordedAudio.count == total, "conversor: gravação completa guardada")
        let level = received.dropFirst().first?.1 ?? 0
        check(level > 0.5 && level < 0.65, "nível: seno a -20 dBFS ≈ 0,58 (obtido \(format(level)))")
    }

    /// Bluetooth headsets change format as the microphone starts (44.1 → 16 kHz); the recording must carry on.
    private static func checkInputSwitch() {
        let before = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let after = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let stream = MicrophoneStream()
        let chunks = LockedList<Data>()
        do {
            try stream.prepare(inputFormat: before) { chunk, _ in chunks.append(chunk) }
            for part in 0..<5 {
                stream.ingest(sineBuffer(format: before, frames: 4_410, startFrame: part * 4_410))
            }
            try stream.switchInput(to: after)
            // A late buffer from the old tap is dropped instead of being converted at the wrong rate.
            stream.ingest(sineBuffer(format: before, frames: 4_410, startFrame: 0))
            for part in 0..<5 {
                stream.ingest(sineBuffer(format: after, frames: 1_600, startFrame: part * 1_600))
            }
        } catch {
            check(false, "troca de formato: preparar os conversores")
            return
        }
        stream.stop()
        let total = chunks.all.reduce(0) { $0 + $1.count }
        check(
            abs(total - PCM16.bytesPerSecond) <= PCM16.bytesPerSecond / 50,
            "troca de formato: 0,5 s a 44,1 kHz + 0,5 s a 16 kHz ≈ 48 000 bytes (obtido \(total))"
        )
        check(stream.recordedAudio.count == total, "troca de formato: a gravação continua depois da troca")
    }

    private static func checkRealtimeProtocol() {
        var configuration = OpenAIRealtimeTranscriber.Configuration()
        let bare = jsonObject(OpenAIRealtimeTranscriber.sessionUpdateJSON(configuration))
        let session = bare?["session"] as? [String: Any]
        let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        check(bare?["type"] as? String == "session.update", "sessão: tipo session.update")
        check(session?["type"] as? String == "transcription", "sessão: tipo transcription")
        check(input?["turn_detection"] is NSNull, "sessão: turn_detection null")
        check((input?["format"] as? [String: Any])?["rate"] as? Int == 24_000, "sessão: PCM a 24 kHz")
        check(transcription?["model"] as? String == "gpt-live-transcribe", "sessão: modelo gpt-live-transcribe")
        check(
            transcription?["languages"] == nil && transcription?["prompt"] == nil,
            "sessão: sem languages nem prompt em Auto"
        )

        configuration.languages = ["pt"]
        configuration.prompt = "Português de Portugal."
        let hinted = jsonObject(OpenAIRealtimeTranscriber.sessionUpdateJSON(configuration))
        let hintedSession = hinted?["session"] as? [String: Any]
        let hintedInput = (hintedSession?["audio"] as? [String: Any])?["input"] as? [String: Any]
        let hints = hintedInput?["transcription"] as? [String: Any]
        check(hints?["languages"] as? [String] == ["pt"], "sessão: languages enviado")
        check(hints?["prompt"] as? String == "Português de Portugal.", "sessão: prompt enviado")

        let append = jsonObject(OpenAIRealtimeTranscriber.appendJSON(Data([1, 2, 3])))
        check(append?["type"] as? String == "input_audio_buffer.append", "append: tipo")
        check(append?["audio"] as? String == "AQID", "append: áudio em base64")

        let delta = RealtimeEvent.parse(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"Olá"}"#
        )
        check(delta?.delta == "Olá", "evento: delta")
        let completed = RealtimeEvent.parse(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Olá mundo"}"#
        )
        check(completed?.transcript == "Olá mundo", "evento: completed")
        let error = RealtimeEvent.parse(#"{"type":"error","error":{"message":"Falhou","code":"x"}}"#)
        check(error?.error?.message == "Falhou", "evento: error")
        check(RealtimeEvent.parse("não é json") == nil, "evento: texto inválido ignorado")
    }

    /// Uses a private named pasteboard, so the user's clipboard is never touched.
    private static func checkClipboardRestore() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.wishper.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.wishper.selftest.custom")
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([1, 2, 3]), forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([original])

        let saved = AutoPaster.snapshot(pasteboard)
        AutoPaster().copy("ditado", to: pasteboard)
        check(pasteboard.string(forType: .string) == "ditado", "clipboard: texto do ditado escrito")
        AutoPaster.restore(saved, to: pasteboard)
        check(pasteboard.string(forType: .string) == "original", "clipboard: texto original reposto")
        check(pasteboard.data(forType: customType) == Data([1, 2, 3]), "clipboard: outros tipos repostos")
    }

    private static func checkFallbackRequest() {
        let fields = OpenAITranscriptionClient.formFields(model: "gpt-transcribe", languages: ["pt"], prompt: nil)
        check(
            fields.map(\.name) == ["model", "response_format", "languages[]"],
            "plano B: campos model, response_format, languages[]"
        )
        let body = OpenAITranscriptionClient.multipartBody(
            boundary: "B",
            fields: fields,
            wav: WAV.make(pcm16: Data(count: 2))
        )
        let text = String(decoding: body, as: UTF8.self)
        check(text.contains("name=\"languages[]\"\r\n\r\npt\r\n"), "plano B: languages[] no multipart")
        check(!text.contains("name=\"language\""), "plano B: sem o campo antigo language")
        check(text.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav"), "plano B: ficheiro WAV")
    }

    private static func checkStyleCatalog() {
        func category(_ bundleID: String, _ host: String? = nil, overrides: [String: AppCategory] = [:]) -> AppCategory {
            StyleCatalog.category(forKey: StyleCatalog.key(bundleID: bundleID, host: host), overrides: overrides)
        }
        check(category("com.tinyspeck.slackmacgap") == .messages, "tipo: Slack é Mensagens")
        check(category("com.apple.mail") == .email, "tipo: Mail é Email")
        check(category("com.anthropic.claudefordesktop") == .aiChat, "tipo: Claude é Chat de IA")
        check(category("com.apple.Notes") == .documents, "tipo: Notas é Documentos e notas")
        check(category("com.apple.Terminal") == .other, "tipo: app desconhecida é Outros")
        check(category("com.google.Chrome", "mail.google.com") == .email, "tipo: Gmail no browser é Email")
        check(category("com.google.Chrome", "app.slack.com") == .messages, "tipo: subdomínio de slack.com é Mensagens")
        check(category("com.google.Chrome", "google.com") == .other, "tipo: google.com não é Gmail")
        check(category("com.google.Chrome", "xmail.google.com") == .other, "tipo: só conta o domínio inteiro")
        check(category("com.google.Chrome") == .other, "tipo: browser sem domínio é Outros")
        check(StyleCatalog.key(bundleID: "com.apple.mail", host: nil) == "app:com.apple.mail", "tipo: chave de app")
        check(StyleCatalog.key(bundleID: "com.apple.Safari", host: "claude.ai") == "site:claude.ai", "tipo: chave de site")
        check(
            category("com.apple.mail", overrides: ["app:com.apple.mail": .messages]) == .messages,
            "tipo: a escolha do utilizador vem primeiro"
        )
        check(StyleCatalog.browsers["com.apple.Safari"] == .safari, "tipo: Safari é um browser")
        check(
            AppCategory.email.defaultStyle == .formal && AppCategory.messages.defaultStyle == .casual
                && AppCategory.aiChat.defaultStyle == .natural,
            "estilo: predefinições por tipo"
        )
    }

    private static func checkPersonalDictionary() {
        func added(_ word: String, to entries: [String]) -> [String]? {
            try? PersonalDictionary.adding(word, to: entries).get()
        }
        func refusal(_ word: String, to entries: [String]) -> PersonalDictionary.Rejection? {
            if case .failure(let rejection) = PersonalDictionary.adding(word, to: entries) {
                return rejection
            }
            return nil
        }
        check(PersonalDictionary.clean("  Wishper\nPro <b> ") == "Wishper Pro b", "dicionário: tira quebras de linha, < e >")
        check(added("  Rui ", to: ["Wishper Pro"]) == ["Wishper Pro", "Rui"], "dicionário: acrescenta sem espaços nas pontas")
        check(refusal("   ", to: []) == .empty, "dicionário: recusa entrada vazia")
        check(refusal("wishper pro", to: ["Wishper Pro"]) == .duplicate, "dicionário: recusa repetida (maiúsculas)")
        check(refusal(String(repeating: "a", count: 61), to: []) == .tooLong, "dicionário: recusa mais de 60 caracteres")
        check(refusal("Nova", to: (1...100).map { "p\($0)" }) == .full, "dicionário: recusa além de 100 entradas")
        check(
            PersonalDictionary.sanitized(["Rui", "", "rui", "<>", "Ana\n"]) == ["Rui", "Ana"],
            "dicionário: ao ler, ignora inválidas e repetidas"
        )
    }

    /// Uses a private preferences suite, so the app's own settings are never touched.
    private static func checkTextSettings() {
        let suite = "com.wishper.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "definições de texto: criar preferências de teste")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = TextSettings(defaults: defaults)
        check(settings.cleanupEnabled, "definições de texto: IA ligada por omissão")
        check(settings.dictionary == ["Wishper Pro"], "definições de texto: dicionário começa com Wishper Pro")
        check(settings.style(for: .messages) == .casual, "definições de texto: Mensagens em Casual")
        check(settings.effectiveStyle(for: .email) == .formal, "definições de texto: Email em Formal")

        settings.setStyle(.formal, for: .messages)
        settings.setCategory(.email, forKey: "site:example.com")
        settings.recordTarget(key: "site:example.com", name: "example.com")
        for index in 0..<35 {
            settings.recordTarget(key: "app:test.\(index)", name: "App \(index)")
        }
        check(settings.addWord("Rui") == nil, "definições de texto: acrescenta palavra")
        check(settings.addWord("rui") == .duplicate, "definições de texto: recusa palavra repetida")
        settings.cleanupEnabled = false

        let reloaded = TextSettings(defaults: defaults)
        check(reloaded.style(for: .messages) == .formal, "definições de texto: estilo guardado")
        check(reloaded.category(forKey: "site:example.com") == .email, "definições de texto: tipo escolhido guardado")
        check(reloaded.dictionary == ["Wishper Pro", "Rui"], "definições de texto: dicionário guardado")
        check(reloaded.recentTargets.first?.key == "app:test.34", "definições de texto: sítio mais recente primeiro")
        check(reloaded.recentTargets.count == 30, "definições de texto: no máximo 30 sítios")
        check(
            reloaded.recentTargets.contains { $0.key == "site:example.com" },
            "definições de texto: sítio com tipo escolhido fica na lista"
        )
        check(reloaded.effectiveStyle(for: .messages) == .unchanged, "definições de texto: IA desligada = Sem alterações")
        reloaded.setCategory(nil, forKey: "site:example.com")
        check(reloaded.category(forKey: "site:example.com") == .other, "definições de texto: Automático volta ao catálogo")
    }

    private static func checkWordOverlap() {
        let variant = "Olá, isto é um texto do Whisper Pro, editado ao vivo está a funcionar."
        check(wordOverlap(spokenSentence, spokenSentence) == 1, "comparação: frase igual = 100%")
        check(wordOverlap(variant, spokenSentence) >= minimumOverlap, "comparação: palavras trocadas passam")
        check(wordOverlap("Olá, isto é", spokenSentence) < minimumOverlap, "comparação: texto cortado falha")
        check(wordOverlap("", spokenSentence) == 0, "comparação: texto vazio = 0%")
    }

    /// Share of the expected words (lowercased, letters only) that appear in `text`.
    private static func wordOverlap(_ text: String, _ expected: String) -> Double {
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        }
        let expectedWords = words(expected)
        guard !expectedWords.isEmpty else { return 0 }
        return Double(expectedWords.intersection(words(text)).count) / Double(expectedWords.count)
    }

    private static func checkTranscript(_ text: String, _ label: String) {
        let overlap = wordOverlap(text, spokenSentence)
        check(overlap >= minimumOverlap, "\(label) (\(Int((overlap * 100).rounded()))% das palavras)")
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static func sineBuffer(format: AVAudioFormat, frames: Int, startFrame: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            samples[index] = Float(0.1 * sin(2 * Double.pi * 440 * Double(startFrame + index) / format.sampleRate))
        }
        return buffer
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
