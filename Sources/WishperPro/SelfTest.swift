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
    }

    private static func runOnlineChecks(audioURL: URL) async {
        check(FileManager.default.fileExists(atPath: audioURL.path), "ficheiro de áudio existe")
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
