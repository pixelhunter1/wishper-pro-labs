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
        checkRealtimeProtocol()
        checkClipboardRestore()
        checkFallbackRequest()
    }

    private static func runOnlineChecks(audioURL: URL) async {
        check(FileManager.default.fileExists(atPath: audioURL.path), "ficheiro de áudio existe")
        guard let apiKey = KeychainService().loadAPIKey(), !apiKey.isEmpty else {
            check(false, "API key no Keychain (abre a app dev, guarda a key nas Definições e repete)")
            return
        }
        await checkLiveTranscriber(audioURL: audioURL, apiKey: apiKey)
        await checkDictationSession(audioURL: audioURL, apiKey: apiKey)
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
            print("    sessão: texto ao vivo após \(format(firstLiveText ?? -1)) s; final \(format(Date().timeIntervalSince(stoppedAt))) s após parar")
            check(session.heardSpeech, "sessão: voz detetada")
            check(firstLiveText != nil, "sessão: texto ao vivo chegou antes do fim")
            check(!session.usedFallback, "sessão: texto final veio da ligação ao vivo")
            check(text.localizedCaseInsensitiveContains("teste"), "sessão: texto final contém \"teste\"")

            let fallback = try await OpenAITranscriptionClient().transcribe(
                wav: WAV.make(pcm16: microphone.recordedAudio),
                apiKey: apiKey,
                languages: ["pt"],
                prompt: nil
            )
            print("    plano B: \(fallback)")
            check(fallback.localizedCaseInsensitiveContains("teste"), "plano B: gpt-transcribe com languages[]")
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
        let transcriber = OpenAIRealtimeTranscriber(
            apiKey: apiKey,
            configuration: .init(languages: ["pt"]),
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
            check(text.localizedCaseInsensitiveContains("teste"), "ao vivo: texto final contém \"teste\"")
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
