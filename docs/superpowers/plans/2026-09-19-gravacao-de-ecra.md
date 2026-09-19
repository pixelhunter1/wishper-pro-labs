# Gravação de ecrã — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gravar o ecrã inteiro, uma janela ou uma app, escolhidos no seletor do sistema, com o microfone escolhido e o som do Mac
opcional. O resultado é um `.mov` com a voz e o som do Mac em faixas separadas, no mesmo relógio que o vídeo — a base da parte 2
(tradução com voz sincronizada).

**Architecture:** O `RecordingController` (`@MainActor`) conduz o fluxo a partir do menu da barra: seletor do sistema
(`SCContentSharingPicker`, sem a permissão de Gravação de Ecrã) → contagem de 3 s → gravação → Finder. O `ScreenRecorder`
(macOS 15) junta ecrã, som do Mac e microfone num `SCStream` e passa as amostras, numa fila série, ao `RecordingWriter`, que só
usa AVFoundation: H.264, voz AAC mono e som AAC estéreo, instante zero no fim da contagem, fragmentos de 10 s. A bolha e o ícone
da barra de menus mostram as fases; a app exclui-se do seletor, por isso nunca aparece no vídeo.

**Tech Stack:** Swift 6.2 (modo Swift 6), SwiftUI + AppKit, ScreenCaptureKit (macOS 15), AVFoundation (`AVAssetWriter`,
`AVAudioConverter`), Combine. Sem dependências externas.

**Spec:** `docs/superpowers/specs/2026-09-19-gravacao-de-ecra-design.md`

## Global Constraints

- Swift 6.2 em modo Swift 6 (concorrência estrita): `swift build` sem erros nem avisos novos.
- Deployment target macOS 13. A gravação só existe no macOS 15 ou posterior (`@available(macOS 15, *)` e
  `RecordingController.isSupported`); no 13 e no 14 o menu não mostra o bloco de gravação.
- Sem dependências externas. Sem alterações a `Package.swift`, aos scripts nem ao `Info.plist`.
- Texto de interface e mensagens em pt-PT; erros como enums `LocalizedError` (`ScreenRecordingError`).
- Chaves novas de UserDefaults: `wishper.recording_microphone` (String: `""` = predefinido do sistema, `"none"` = sem
  microfone, senão o `uniqueID` do `AVCaptureDevice`; predefinição `""`) e `wishper.recording_system_audio` (Bool; `false`).
- Ficheiros em `~/Movies/Wishper Pro/`, com o nome `Gravação AAAA-MM-DD às HH.MM.SS.mov` (hora local) e o sufixo " 2", " 3"…
  quando o nome já existe.
- Vídeo H.264, no máximo 30 fps, lado maior ≤ 3840 e menor ≤ 2160, medidas pares. Voz AAC 48 kHz mono 128 kbit/s; som do Mac
  AAC 48 kHz estéreo 192 kbit/s; `.mov` com fragmentos de 10 s.
- Nunca perder uma gravação: uma falha a meio fecha o ficheiro com o que já foi gravado, e sair da app fecha-o antes.
- Correr os comandos a partir da raiz da worktree `.claude/worktrees/gravacao` (branch `worktree-gravacao`). Nunca usar
  `git stash` sem etiqueta (a pilha é partilhada com outras worktrees).
- Commits em inglês, a terminar com `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- O código de cada tarefa foi compilado num protótipo (Swift 6.2, modo Swift 6, macOS 26.6.2): as 153 verificações offline
  passaram (122 antes deste plano). Se algo não compilar, corrigir o mínimo e anotar no commit.
- O motor das tarefas 1–3 também gravou de verdade num teste descartável (2026-09-19, Studio Display, ecrã inteiro).
  - **Parada normalmente:** 3840×2160 a 29 fps; a voz mono e o som do Mac estéreo (com um som de outra app) começam em
    0,00 s.
  - **Morta com `SIGKILL` aos 25 s:** o ficheiro abriu com 20,08 s.
- `./scripts/run-dev-app.sh` assina a app dev ad-hoc e fecha todos os processos `WishperPro` (também a release instalada).
  Depois de cada build, o macOS pode deixar de reconhecer a permissão de microfone da app dev: quem testa corre
  `tccutil reset Microphone com.wishper.pro.dev` e volta a dá-la. A gravação **não** precisa da permissão de Gravação de Ecrã.

## Acertos à spec (vindos do protótipo; a spec foi atualizada no mesmo commit que este plano)

1. Dois ficheiros em vez de um: `Services/RecordingWriter.swift` (`RecordingSize`, `RecordingFile`, `RecordingWriter`, só
   AVFoundation e testável) e `Services/ScreenRecorder.swift` (`RecordingMicrophone`, `ScreenRecordingError`,
   `ScreenRecorder`).
2. O `PCMConverter` ganha um formato de saída (PCM16 por omissão) e `convertBuffer(_:)`, para a voz a 48 kHz usar a mesma
   conversão que o ditado.
3. Voz: um bloco mais de 50 ms atrás da contagem de amostras (o relógio do microfone adiantou-se) é descartado, para nunca haver
   sobreposições; depois de uma falha de mais de 50 ms, a contagem recomeça no tempo do bloco.
4. `onFailure` passa a `onEnded(Error?)`: `nil` quando a pessoa para a captura no menu do sistema, que conta como gravação
   guardada.
5. `allowsChangingSelectedContent = false` no seletor (mudar o que se grava a meio fica fora de âmbito).
6. Sair da app durante uma gravação fecha primeiro o ficheiro (`applicationShouldTerminate`).
7. A bolha mostra "Sem acesso ao microfone: a gravar sem voz." como segunda linha (`notice`).
8. `RecordingWriter.finish(at:)` é `nonisolated(nonsending)` (Swift 6.2): corre no ator de quem chama, sem enviar o escritor
   para outro domínio de isolamento.
9. O caso "sem microfone" chama-se `.off` (e não `.none`, que se confunde com `Optional.none`).

## Estrutura de ficheiros

| Ficheiro | Responsabilidade | Tarefa |
|---|---|---|
| `Sources/WishperPro/Services/RecordingWriter.swift` | `RecordingSize`, `RecordingFile` (1); `RecordingWriter` (2) | 1, 2 |
| `Sources/WishperPro/Services/MicrophoneStream.swift` | `PCMConverter` com formato de saída e `convertBuffer` | 2 |
| `Sources/WishperPro/Services/ScreenRecorder.swift` | `RecordingMicrophone`, `ScreenRecordingError`, `ScreenRecorder` | 3 |
| `Sources/WishperPro/RecordingController.swift` | `RecordingPhase`, `RecordingClock`, `RecordingInput`, `RecordingController` | 4 |
| `Sources/WishperPro/VoiceBubbleView.swift` | `RecordingBubbleView` | 5 |
| `Sources/WishperPro/Services/FloatingBubbleController.swift` | bolha do ditado ou da gravação; número da janela | 5 |
| `Sources/WishperPro/WishperProApp.swift` | bloco de gravação no menu; ícone com o tempo; `AppDelegate` | 5 |
| `Sources/WishperPro/SelfTest.swift` | verificações novas; offline numa `Task` | 1–4 |
| `CLAUDE.md`, `README.md` | documentação | 6 |

Contagem de verificações offline (`.build/debug/WishperPro --selftest | grep -c "^  ok"`): hoje 122; depois da tarefa 1, 129;
2, 135; 3, 148; 4, 153 (a 5 e a 6 não acrescentam).

---

### Task 1: Tamanho do vídeo e nome do ficheiro

**Files:**
- Create: `Sources/WishperPro/Services/RecordingWriter.swift`
- Modify: `Sources/WishperPro/SelfTest.swift` (`runOfflineChecks()`; funções novas antes de
  `private static func checkWordOverlap() {`)

**Interfaces:**
- Produces:
  - `enum RecordingSize` — `static func output(points: CGSize, scale: CGFloat) -> CGSize`.
  - `enum RecordingFile` — `static var folder: URL` (`~/Movies/Wishper Pro`);
    `static func url(for date: Date, in folder: URL) -> URL`.

- [ ] **Step 1: Escrever as verificações**

Em `Sources/WishperPro/SelfTest.swift`, no fim de `runOfflineChecks()`, depois de `checkTextProcessorRequest()`, acrescentar:

```swift
        checkRecordingSize()
        checkRecordingFile()
```

E acrescentar estas funções imediatamente antes de `private static func checkWordOverlap() {`:

```swift
    private static func checkRecordingSize() {
        func size(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) -> CGSize {
            RecordingSize.output(points: CGSize(width: width, height: height), scale: scale)
        }
        check(size(2_560, 1_440, 2) == CGSize(width: 3_840, height: 2_160), "gravação: Studio Display 5K → 3840×2160")
        check(size(1_470, 956, 2) == CGSize(width: 2_940, height: 1_912), "gravação: MacBook Air 13\" fica em 2940×1912")
        let window = size(1_281, 1_346, 2)
        check(
            max(window.width, window.height) <= 3_840 && min(window.width, window.height) <= 2_160
                && Int(window.width) % 2 == 0 && Int(window.height) % 2 == 0
                && abs(window.width / window.height - 1_281.0 / 1_346.0) < 0.01,
            "gravação: janela alta reduzida, pares e na mesma proporção (\(Int(window.width))×\(Int(window.height)))"
        )
        check(size(1_001, 601, 1) == CGSize(width: 1_000, height: 600), "gravação: medidas ímpares descem para pares")
    }

    private static func checkRecordingFile() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wishper-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let components = DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 32, second: 10)
        let date = Calendar.current.date(from: components)!
        let first = RecordingFile.url(for: date, in: folder)
        check(first.lastPathComponent == "Gravação 2026-09-19 às 14.32.10.mov", "gravação: nome com a data e a hora locais")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        check(
            RecordingFile.url(for: date, in: folder).lastPathComponent == "Gravação 2026-09-19 às 14.32.10 2.mov",
            "gravação: nome ocupado ganha \" 2\""
        )
        check(RecordingFile.folder.path.hasSuffix("/Movies/Wishper Pro"), "gravação: pasta Filmes/Wishper Pro")
    }

```

- [ ] **Step 2: Confirmar que falha**

Run: `swift build 2>&1 | grep error | head -3`
Expected: `error: cannot find 'RecordingSize' in scope` (e o mesmo para `RecordingFile`).

- [ ] **Step 3: Implementar**

Criar `Sources/WishperPro/Services/RecordingWriter.swift`:

```swift
import AVFoundation
import CoreMedia
import Foundation

/// Output video size: the content in pixels, scaled down (same aspect) until the longer side is at most 3840 and the
/// shorter at most 2160, rounded down to even numbers (H.264 needs even sizes).
enum RecordingSize {
    static func output(points: CGSize, scale: CGFloat) -> CGSize {
        let width = max(points.width * scale, 2)
        let height = max(points.height * scale, 2)
        let factor = min(1, 3_840 / max(width, height), 2_160 / min(width, height))
        return CGSize(width: even(width * factor), height: even(height * factor))
    }

    /// The small margin keeps 2159.9999… (floating point) at 2160.
    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(Int(value + 0.001) & ~1)
    }
}

/// Where recordings go and what they are called.
enum RecordingFile {
    /// `~/Movies/Wishper Pro`. Movies is not behind a privacy permission; Desktop is, and ad-hoc reinstalls lose it.
    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wishper Pro", isDirectory: true)
    }

    /// "Gravação 2026-09-19 às 14.32.10.mov" in local time, with " 2", " 3"… when the name is taken.
    static func url(for date: Date, in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let base = "Gravação \(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(base).mov")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).mov")
            number += 1
        }
        return url
    }
}
```

- [ ] **Step 4: Confirmar que passa**

Run: `swift build 2>&1 | grep -E "warning|error" ; .build/debug/WishperPro --selftest | grep -E "gravação:|FALHOU|Tudo OK" ; .build/debug/WishperPro --selftest | grep -c "^  ok"`
Expected: sem avisos nem erros; 7 linhas `ok      gravação: …` (a janela sai como 2160×2268); `== Tudo OK ==`; `129`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WishperPro/Services/RecordingWriter.swift Sources/WishperPro/SelfTest.swift
git commit -m "$(cat <<'EOF'
Add the recording size rule and file naming

Scale the captured content to at most 3840 on the long side and 2160 on
the short one, in even pixels, and name recordings by local date and time
in ~/Movies/Wishper Pro, adding " 2", " 3"… when the name is taken.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Escritor do ficheiro (`RecordingWriter`)

**Files:**
- Modify: `Sources/WishperPro/Services/MicrophoneStream.swift` (classe `PCMConverter`, linhas 53–85)
- Modify: `Sources/WishperPro/Services/RecordingWriter.swift` (acrescentar `RecordingWriter` no fim)
- Modify: `Sources/WishperPro/SelfTest.swift` (`run(audioPath:)`; `runAsyncOfflineChecks()` nova; funções novas antes de
  `private static func checkWordOverlap() {`)

**Interfaces:**
- Consumes: `PCM16.format` (existente).
- Produces:
  - `PCMConverter` — `init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat = PCM16.format)`,
    `var inputFormat: AVAudioFormat`, `func convert(_ buffer: AVAudioPCMBuffer) -> Data` (igual a hoje),
    `func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer?`.
  - `final class RecordingWriter` — `static let voiceFormat: AVAudioFormat` (48 kHz mono float);
    `init(url: URL, videoSize: CGSize, voice: Bool, systemAudio: Bool) throws`; `var failure: Error?`;
    `func begin(at time: CMTime)`; `func appendVideo(_ frame: CVPixelBuffer, at time: CMTime)`;
    `func appendVoice(_ buffer: AVAudioPCMBuffer, at time: CMTime)`; `func appendSystemAudio(_ sample: CMSampleBuffer)`;
    `nonisolated(nonsending) func finish(at end: CMTime) async throws`; `func cancel()`;
    `static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer?`.

- [ ] **Step 1: Escrever as verificações**

Em `Sources/WishperPro/SelfTest.swift`, substituir `run(audioPath:)` inteiro (as verificações offline passam a correr numa
`Task`, porque a do ficheiro é assíncrona):

```swift
    static func run(audioPath: String?) -> Never {
        Task {
            print("== Verificações offline ==")
            runOfflineChecks()
            await runAsyncOfflineChecks()
            if let audioPath {
                print("== Verificações online (\(audioPath)) ==")
                await runOnlineChecks(audioURL: URL(fileURLWithPath: audioPath))
            }
            finish()
        }
        dispatchMain()
    }
```

Acrescentar logo a seguir ao fim de `runOfflineChecks()`:

```swift
    private static func runAsyncOfflineChecks() async {
        await checkRecordingWriter()
    }
```

E acrescentar estas funções imediatamente antes de `private static func checkWordOverlap() {`:

```swift
    /// 2 s written like a real recording: a frame before time zero and a still screen, voice that drops from 48 to
    /// 16 kHz mid-way (a Bluetooth headset), the Mac's sound in ScreenCaptureKit's format, and audio before time zero.
    private static func checkRecordingWriter() async {
        do {
            let full = try await writeRecording(voice: true, systemAudio: true)
            defer { try? FileManager.default.removeItem(at: full) }
            let tracks = try await recordingTracks(full)
            check(tracks.video == 1 && tracks.audioChannels == [1, 2], "gravação: vídeo, voz mono e som do Mac estéreo")
            check(abs(tracks.duration - 2) <= 0.1, "gravação: dura 2 s (obtido \(format(tracks.duration)))")
            check(abs(tracks.videoDuration - 2) <= 0.1, "gravação: ecrã parado mantém o vídeo até ao fim")
            check(
                tracks.voiceStart < 0.05 && abs(tracks.voiceDuration - 2) <= 0.1,
                "gravação: voz do zero aos 2 s com troca de formato (\(format(tracks.voiceStart))–\(format(tracks.voiceDuration)))"
            )
            let noVoice = try await writeRecording(voice: false, systemAudio: true)
            defer { try? FileManager.default.removeItem(at: noVoice) }
            check(try await recordingTracks(noVoice).audioChannels == [2], "gravação: sem microfone só grava o som do Mac")
            let noSound = try await writeRecording(voice: true, systemAudio: false)
            defer { try? FileManager.default.removeItem(at: noSound) }
            check(try await recordingTracks(noSound).audioChannels == [1], "gravação: sem som do Mac só grava a voz")
        } catch {
            check(false, "gravação: escrever o ficheiro (\(error.localizedDescription))")
        }
    }

    private static func writeRecording(voice: Bool, systemAudio: Bool) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wishper-selftest-\(UUID().uuidString).mov")
        let writer = try RecordingWriter(url: url, videoSize: CGSize(width: 320, height: 180), voice: voice, systemAudio: systemAudio)
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: 1_000 + seconds, preferredTimescale: 48_000) }
        let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let mono16 = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        // Before time zero: kept as the first frame, or dropped.
        writer.appendVideo(try pixelBuffer(), at: time(-0.5))
        writer.appendVoice(sineBuffer(format: mono48, frames: 4_800, startFrame: 0), at: time(-0.4))
        if let early = RecordingWriter.sampleBuffer(sineBuffer(format: stereo48, frames: 4_800, startFrame: 0), at: time(-0.4)) {
            writer.appendSystemAudio(early)
        }
        writer.begin(at: time(0))
        writer.appendVideo(try pixelBuffer(), at: time(0.5))
        for part in 0..<20 {
            let seconds = Double(part) / 10
            if part < 10 {
                writer.appendVoice(sineBuffer(format: mono48, frames: 4_800, startFrame: part * 4_800), at: time(seconds))
            } else {
                writer.appendVoice(sineBuffer(format: mono16, frames: 1_600, startFrame: part * 1_600), at: time(seconds))
            }
            let sound = sineBuffer(format: stereo48, frames: 4_800, startFrame: part * 4_800)
            if let sample = RecordingWriter.sampleBuffer(sound, at: time(seconds)) {
                writer.appendSystemAudio(sample)
            }
        }
        try await writer.finish(at: time(2))
        return url
    }

    private static func recordingTracks(
        _ url: URL
    ) async throws -> (video: Int, audioChannels: [Int], duration: Double, videoDuration: Double, voiceStart: Double, voiceDuration: Double) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var channels: [Int] = []
        for track in audio {
            let description = try await track.load(.formatDescriptions).first
            channels.append(Int(description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0))
        }
        let videoRange = try await video.first?.load(.timeRange)
        let voiceRange = try await audio.first?.load(.timeRange)
        return (
            video.count,
            channels,
            try await asset.load(.duration).seconds,
            videoRange?.duration.seconds ?? 0,
            voiceRange?.start.seconds ?? -1,
            voiceRange?.duration.seconds ?? 0
        )
    }

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.featureUnsupported) }
        return buffer
    }

```

- [ ] **Step 2: Confirmar que falha**

Run: `swift build 2>&1 | grep error | head -3`
Expected: `error: cannot find 'RecordingWriter' in scope`.

- [ ] **Step 3: Generalizar o `PCMConverter`**

Em `Sources/WishperPro/Services/MicrophoneStream.swift`, substituir a classe `PCMConverter` inteira (do comentário
`/// Converts microphone or file buffers…` até ao `}` que a fecha, antes de `/// Hands one buffer to AVAudioConverter's…`) por:

```swift
/// Converts microphone or file buffers (to PCM16 24 kHz mono by default), keeping resampler state between chunks.
final class PCMConverter {
    private let converter: AVAudioConverter

    var inputFormat: AVAudioFormat { converter.inputFormat }

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat = PCM16.format) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    /// The converted samples as PCM16 bytes (the default output format).
    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let output = convertBuffer(buffer), let samples = output.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }

    /// A buffer in another format (a late one from before a device switch) makes the converter fail: it is dropped.
    func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let pending = PendingBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        return status == .error ? nil : output
    }
}
```

- [ ] **Step 4: Implementar o `RecordingWriter`**

Acrescentar no fim de `Sources/WishperPro/Services/RecordingWriter.swift`:

```swift

/// Writes a recording: H.264 video, then the voice (AAC mono) and the Mac's sound (AAC stereo) when present, all on
/// the capture clock and starting at `begin(at:)`. Not thread-safe: its owner calls it on one queue.
final class RecordingWriter {
    /// The voice is written as 48 kHz mono whatever the microphone gives (Bluetooth headsets change format mid-way).
    static let voiceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    /// Voice timestamps count samples; a block further than this from its own timestamp is handled apart.
    static let voiceDrift = CMTime(value: 50, timescale: 1_000)

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let frames: AVAssetWriterInputPixelBufferAdaptor
    private let voice: AVAssetWriterInput?
    private let systemAudio: AVAssetWriterInput?
    private var start: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.negativeInfinity
    private var voiceConverter: PCMConverter?
    private var nextVoiceTime: CMTime?

    /// The writer's error once it can no longer write (e.g. the disk is full).
    var failure: Error? {
        writer.status == .failed ? writer.error ?? CocoaError(.fileWriteUnknown) : nil
    }

    init(url: URL, videoSize: CGSize, voice hasVoice: Bool, systemAudio hasSystemAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // A fragment every 10 s: if the app dies mid-recording, the file still opens up to the last fragment.
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
        ])
        frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        voice = hasVoice ? Self.audioInput(channels: 1, bitRate: 128_000) : nil
        systemAudio = hasSystemAudio ? Self.audioInput(channels: 2, bitRate: 192_000) : nil
        for input in [video, voice, systemAudio].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Time zero. The latest frame so far enters at that time: ScreenCaptureKit only sends frames when the screen
    /// changes.
    func begin(at time: CMTime) {
        writer.startSession(atSourceTime: time)
        start = time
        if let lastFrame {
            appendFrame(lastFrame, at: time)
        }
    }

    /// Before time zero only the latest frame is kept.
    func appendVideo(_ frame: CVPixelBuffer, at time: CMTime) {
        guard let start, time >= start else {
            lastFrame = frame
            return
        }
        appendFrame(frame, at: time)
    }

    /// Converts to 48 kHz mono (a new converter when the format changes) and times the voice by counting samples, so
    /// blocks never overlap or leave holes. After a gap of more than 50 ms the count restarts at the block's time; a
    /// block more than 50 ms behind the count is dropped (the microphone's clock ran fast).
    func appendVoice(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let voice, let start, time >= start else { return }
        if voiceConverter?.inputFormat != buffer.format {
            voiceConverter = PCMConverter(from: buffer.format, to: Self.voiceFormat)
        }
        guard let converted = voiceConverter?.convertBuffer(buffer), converted.frameLength > 0 else { return }
        var presentation = nextVoiceTime ?? time
        if presentation < time - Self.voiceDrift {
            presentation = time
        } else if presentation > time + Self.voiceDrift {
            return
        }
        guard voice.isReadyForMoreMediaData,
              let sample = Self.sampleBuffer(converted, at: presentation),
              voice.append(sample)
        else { return }
        nextVoiceTime = presentation + CMTime(value: CMTimeValue(converted.frameLength), timescale: 48_000)
    }

    /// ScreenCaptureKit's blocks go in as they come: the stream is asked for a fixed 48 kHz stereo format.
    func appendSystemAudio(_ sample: CMSampleBuffer) {
        guard let systemAudio, let start, sample.presentationTimeStamp >= start,
              systemAudio.isReadyForMoreMediaData
        else { return }
        systemAudio.append(sample)
    }

    /// Holds the last frame until `end` (so the video lasts as long as the audio) and closes the file.
    nonisolated(nonsending) func finish(at end: CMTime) async throws {
        guard start != nil else {
            cancel()
            throw CocoaError(.fileWriteUnknown)
        }
        if let lastFrame, end > lastFrameTime {
            appendFrame(lastFrame, at: end)
        }
        writer.endSession(atSourceTime: end)
        for input in [video, voice, systemAudio].compactMap({ $0 }) {
            input.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Stops without keeping a file (cancelled before time zero).
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    /// A CMSampleBuffer holding `buffer`'s samples at `time`.
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: buffer.audioBufferList
            ) == noErr
        else { return nil }
        return sample
    }

    private func appendFrame(_ frame: CVPixelBuffer, at time: CMTime) {
        guard time > lastFrameTime, video.isReadyForMoreMediaData,
              frames.append(frame, withPresentationTime: time)
        else { return }
        lastFrame = frame
        lastFrameTime = time
    }

    private static func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
    }
}
```

Nota: sem `nonisolated(nonsending)` em `finish(at:)`, o Swift 6 recusa a chamada a partir do `SelfTest` (`@MainActor`) com
"sending 'writer' risks causing data races".

- [ ] **Step 5: Confirmar que passa**

Run: `swift build 2>&1 | grep -E "warning|error" ; .build/debug/WishperPro --selftest | grep -E "gravação: (vídeo|dura|ecrã|voz|sem)|conversor|troca de formato|FALHOU|Tudo OK" ; .build/debug/WishperPro --selftest | grep -c "^  ok"`
Expected: sem avisos nem erros; as 5 verificações do conversor e da troca de formato continuam `ok`; 6 linhas novas
`ok      gravação: …` (dura 2.00; voz 0.00–1.99); `== Tudo OK ==`; `135`.

- [ ] **Step 6: Commit**

```bash
git add Sources/WishperPro/Services/MicrophoneStream.swift Sources/WishperPro/Services/RecordingWriter.swift Sources/WishperPro/SelfTest.swift
git commit -m "$(cat <<'EOF'
Write recordings with AVAssetWriter on one clock

RecordingWriter writes H.264 video, the voice as AAC mono and the Mac's
sound as AAC stereo into a fragmented .mov, all timed on the capture
clock from time zero. The last frame is repeated at both ends because
ScreenCaptureKit only sends frames when the screen changes, and the voice
is converted to 48 kHz mono and timed by counting samples, so a Bluetooth
format change mid-way leaves no gap or overlap. PCMConverter now takes an
output format so the voice reuses the dictation's conversion.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Captura com o ScreenCaptureKit (`ScreenRecorder`)

**Files:**
- Create: `Sources/WishperPro/Services/ScreenRecorder.swift`
- Modify: `Sources/WishperPro/SelfTest.swift` (`runOfflineChecks()`; funções novas antes de
  `/// 2 s written like a real recording…`)

**Interfaces:**
- Consumes: `RecordingSize.output(points:scale:)`, `RecordingWriter` (Task 2), `PCMConverter`, `PCM16.chunkBytes`,
  `PCM16.level(of:)`.
- Produces:
  - `enum RecordingMicrophone: Equatable, Sendable` — `off`, `systemDefault`, `device(String)`;
    `init(storedValue: String, connected: [String])`; `var storedValue: String`.
  - `enum ScreenRecordingError: LocalizedError` — `folderUnavailable`, `startFailed(String)`, `interrupted(String)`;
    `static func reason(_ error: Error) -> String`.
  - `@available(macOS 15, *) final class ScreenRecorder` —
    `init(filter: SCContentFilter, microphone: RecordingMicrophone, systemAudio: Bool, url: URL) throws`; `let url: URL`;
    `var onMicrophone: (@Sendable (Data, Double) -> Void)?`; `var onEnded: (@Sendable (Error?) -> Void)?`;
    `func start() async throws`; `func beginWriting()`; `func stop() async throws -> URL`; `func cancel() async`;
    `static func configuration(size: CGSize, microphone: RecordingMicrophone, systemAudio: Bool) -> SCStreamConfiguration`.

- [ ] **Step 1: Escrever as verificações**

Em `Sources/WishperPro/SelfTest.swift`, no fim de `runOfflineChecks()`, depois de `checkRecordingFile()`, acrescentar:

```swift
        checkRecordingMicrophone()
        checkRecordingConfiguration()
        checkRecordingErrors()
```

E acrescentar estas funções imediatamente antes de
`/// 2 s written like a real recording: a frame before time zero and a still screen, voice that drops from 48 to`:

```swift
    private static func checkRecordingMicrophone() {
        let connected = ["Studio", "iPhone"]
        check(RecordingMicrophone(storedValue: "", connected: connected) == .systemDefault, "microfone: vazio é o predefinido")
        check(RecordingMicrophone(storedValue: "none", connected: connected) == .off, "microfone: \"none\" é sem microfone")
        check(RecordingMicrophone(storedValue: "iPhone", connected: connected) == .device("iPhone"), "microfone: dispositivo ligado")
        check(
            RecordingMicrophone(storedValue: "Buds", connected: connected) == .systemDefault,
            "microfone: dispositivo desligado passa ao predefinido"
        )
        check(
            [RecordingMicrophone.off, .systemDefault, .device("iPhone")].map(\.storedValue) == ["none", "", "iPhone"],
            "microfone: valores guardados"
        )
    }

    private static func checkRecordingConfiguration() {
        guard #available(macOS 15, *) else {
            print("  info    macOS anterior ao 15: a gravação de ecrã não existe")
            return
        }
        let size = CGSize(width: 3_840, height: 2_160)
        let chosen = ScreenRecorder.configuration(size: size, microphone: .device("Studio"), systemAudio: true)
        check(chosen.width == 3_840 && chosen.height == 2_160, "gravação: stream no tamanho de saída")
        check(chosen.minimumFrameInterval == CMTime(value: 1, timescale: 30), "gravação: no máximo 30 fps")
        check(
            chosen.capturesAudio && chosen.excludesCurrentProcessAudio && chosen.sampleRate == 48_000
                && chosen.channelCount == 2,
            "gravação: som do Mac a 48 kHz estéreo, sem os sons da app"
        )
        check(chosen.captureMicrophone && chosen.microphoneCaptureDeviceID == "Studio", "gravação: microfone escolhido")
        let standard = ScreenRecorder.configuration(size: size, microphone: .systemDefault, systemAudio: false)
        check(
            standard.captureMicrophone && standard.microphoneCaptureDeviceID == nil && !standard.capturesAudio,
            "gravação: microfone predefinido e sem som do Mac"
        )
        check(!ScreenRecorder.configuration(size: size, microphone: .off, systemAudio: false).captureMicrophone, "gravação: sem microfone")
    }

    private static func checkRecordingErrors() {
        let failure = NSError(domain: "teste", code: 1, userInfo: [NSLocalizedDescriptionKey: "A operação não pôde ser concluída."])
        check(ScreenRecordingError.reason(failure) == "a operação não pôde ser concluída", "gravação: motivo em minúscula e sem ponto")
        check(
            ScreenRecordingError.interrupted("o ecrã foi desligado").localizedDescription
                == "Gravação interrompida: o ecrã foi desligado. O que foi gravado ficou guardado.",
            "gravação: mensagem de interrupção"
        )
    }

```

- [ ] **Step 2: Confirmar que falha**

Run: `swift build 2>&1 | grep error | head -3`
Expected: `error: cannot find 'RecordingMicrophone' in scope`.

- [ ] **Step 3: Implementar**

Criar `Sources/WishperPro/Services/ScreenRecorder.swift`:

```swift
import AVFoundation
import ScreenCaptureKit

/// Which microphone a recording uses. Stored as `""` (system default), `"none"` or an `AVCaptureDevice.uniqueID`.
enum RecordingMicrophone: Equatable, Sendable {
    case off
    case systemDefault
    case device(String)

    /// A saved device that is not connected falls back to the system default.
    init(storedValue: String, connected: [String]) {
        switch storedValue {
        case "none": self = .off
        case "": self = .systemDefault
        default: self = connected.contains(storedValue) ? .device(storedValue) : .systemDefault
        }
    }

    var storedValue: String {
        switch self {
        case .off: return "none"
        case .systemDefault: return ""
        case .device(let id): return id
        }
    }
}

enum ScreenRecordingError: LocalizedError {
    case folderUnavailable
    case startFailed(String)
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            return "Não foi possível criar a pasta Filmes/Wishper Pro."
        case .startFailed(let reason):
            return "Não foi possível começar a gravar: \(reason)"
        case .interrupted(let reason):
            return "Gravação interrompida: \(reason). O que foi gravado ficou guardado."
        }
    }

    /// A system error as a clause for the messages above: lowercase first letter, no final full stop.
    static func reason(_ error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}

/// One recording: a ScreenCaptureKit stream (screen, the Mac's sound, microphone) written by a `RecordingWriter`.
/// The stream starts at once so the microphone warms up, but nothing is written until `beginWriting()`.
@available(macOS 15, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Microphone audio as 100 ms PCM16 24 kHz chunks and their level: the bubble now, live translation in part 2.
    var onMicrophone: (@Sendable (Data, Double) -> Void)?
    /// The stream ended by itself, with the file already closed: `nil` when the person stopped it from the system's
    /// menu, otherwise the reason (window closed, display gone, disk full…).
    var onEnded: (@Sendable (Error?) -> Void)?

    let url: URL
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let writer: RecordingWriter
    private var stream: SCStream?
    // Touched only on `queue`, where every sample arrives in order.
    private let queue = DispatchQueue(label: "com.wishper.pro.screen-recorder")
    private var levelConverter: PCMConverter?
    private var pendingLevel = Data()
    private var isClosed = false
    private var reportedFailure = false

    init(filter: SCContentFilter, microphone: RecordingMicrophone, systemAudio: Bool, url: URL) throws {
        let size = RecordingSize.output(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        self.url = url
        self.filter = filter
        configuration = Self.configuration(size: size, microphone: microphone, systemAudio: systemAudio)
        writer = try RecordingWriter(url: url, videoSize: size, voice: microphone != .off, systemAudio: systemAudio)
        super.init()
    }

    static func configuration(size: CGSize, microphone: RecordingMicrophone, systemAudio: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone != .off
        if case .device(let id) = microphone {
            configuration.microphoneCaptureDeviceID = id
        }
        return configuration
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Time zero is now, on the capture clock.
    func beginWriting() {
        queue.async { [self] in
            writer.begin(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    /// Stops the stream and closes the file.
    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        try await close()
        return url
    }

    /// Cancelled before time zero: nothing is kept.
    func cancel() async {
        try? await stream?.stopCapture()
        guard await markClosed() != nil else { return }
        writer.cancel()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isClosed, sample.isValid else { return }
        switch type {
        case .screen:
            guard let frame = Self.completeFrame(sample) else { return }
            writer.appendVideo(frame, at: sample.presentationTimeStamp)
            if let failure = writer.failure, !reportedFailure {
                reportedFailure = true
                end(with: failure)
            }
        case .audio:
            writer.appendSystemAudio(sample)
        case .microphone:
            guard let buffer = Self.pcmBuffer(sample) else { return }
            writer.appendVoice(buffer, at: sample.presentationTimeStamp)
            reportLevel(buffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedByPerson = (error as? SCStreamError)?.code == .userStopped
        end(with: stoppedByPerson ? nil : error)
    }

    private func end(with error: Error?) {
        Task { [self] in
            try? await stream?.stopCapture()
            try? await close()
            onEnded?(error)
        }
    }

    /// Closes the file once, whoever gets there first: `stop()` or the stream ending by itself.
    private func close() async throws {
        guard let end = await markClosed() else { return }
        try await writer.finish(at: end)
    }

    /// After the samples already queued, stops writing; returns the end time, or nil if already closed.
    private func markClosed() async -> CMTime? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume(returning: nil)
                    return
                }
                isClosed = true
                continuation.resume(returning: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    /// Same 100 ms PCM16 24 kHz chunks as the dictation microphone; a new converter when the format changes.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        if levelConverter?.inputFormat != buffer.format {
            levelConverter = PCMConverter(from: buffer.format)
        }
        guard let levelConverter else { return }
        pendingLevel.append(levelConverter.convert(buffer))
        while pendingLevel.count >= PCM16.chunkBytes {
            let chunk = Data(pendingLevel.prefix(PCM16.chunkBytes))
            pendingLevel = Data(pendingLevel.dropFirst(PCM16.chunkBytes))
            onMicrophone?(chunk, PCM16.level(of: chunk))
        }
    }

    /// Only complete frames carry a new image; idle ones mean the screen did not change.
    private static func completeFrame(_ sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else { return nil }
        return sample.imageBuffer
    }

    private static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        ) == noErr else { return nil }
        return buffer
    }
}
```

- [ ] **Step 4: Confirmar que passa**

Run: `swift build 2>&1 | grep -E "warning|error" ; .build/debug/WishperPro --selftest | grep -E "microfone:|gravação: (stream|no máximo|som do Mac a|microfone|sem microfone$|motivo|mensagem)|FALHOU|Tudo OK" ; .build/debug/WishperPro --selftest | grep -c "^  ok"`
Expected: sem avisos nem erros; 13 linhas novas `ok`; `== Tudo OK ==`; `148`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WishperPro/Services/ScreenRecorder.swift Sources/WishperPro/SelfTest.swift
git commit -m "$(cat <<'EOF'
Capture the screen, the Mac's sound and the microphone in one stream

ScreenRecorder runs one SCStream for the picked display, window or app
and hands every sample to RecordingWriter on a serial queue. The stream
starts right away so the microphone warms up, but writing only begins at
beginWriting(). A stream that ends by itself closes the file first; the
system's own stop button counts as a normal save.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Controlador da gravação (`RecordingController`)

**Files:**
- Create: `Sources/WishperPro/RecordingController.swift`
- Modify: `Sources/WishperPro/SelfTest.swift` (`runOfflineChecks()`; função nova antes de
  `/// 2 s written like a real recording…`)

**Interfaces:**
- Consumes: `RecordingFile`, `RecordingMicrophone`, `ScreenRecordingError`, `ScreenRecorder` (Tasks 1–3), `SoundCuePlayer`
  (existente).
- Produces:
  - `enum RecordingPhase: Equatable` — `idle`, `choosing`, `countdown(Int)`, `recording(since: Date)`, `saving`,
    `saved(URL)`, `failed(String)`; `menuTitle: String`, `acceptsMenuAction: Bool`, `isBusy: Bool`, `showsBubble: Bool`.
  - `enum RecordingClock` — `static func text(_ seconds: TimeInterval) -> String`.
  - `struct RecordingInput: Identifiable, Equatable` — `id: String`, `name: String`.
  - `@MainActor final class RecordingController: ObservableObject` — `static var isSupported: Bool`;
    `@Published private(set) var phase: RecordingPhase`, `level: Double`, `elapsed: TimeInterval`, `notice: String?`,
    `microphones: [RecordingInput]`; `@Published var microphoneID: String`, `recordsSystemAudio: Bool`;
    `var excludedWindowIDs: @MainActor () -> [Int]`; `var menuMicrophone: String`; `func toggle()`;
    `func showRecordings()`; `func finishBeforeQuit() async`.

- [ ] **Step 1: Escrever as verificações**

Em `Sources/WishperPro/SelfTest.swift`, no fim de `runOfflineChecks()`, depois de `checkRecordingErrors()`, acrescentar:

```swift
        checkRecordingPhases()
```

E acrescentar esta função imediatamente antes de
`/// 2 s written like a real recording: a frame before time zero and a still screen, voice that drops from 48 to`:

```swift
    private static func checkRecordingPhases() {
        let phases: [RecordingPhase] = [
            .idle, .choosing, .countdown(3), .recording(since: Date()), .saving,
            .saved(URL(fileURLWithPath: "/tmp/gravação.mov")), .failed("x"),
        ]
        check(
            phases.map(\.menuTitle) == [
                "Gravar ecrã…", "Gravar ecrã…", "Cancelar gravação", "Parar gravação", "A guardar…",
                "Gravar ecrã…", "Gravar ecrã…",
            ],
            "gravação: títulos do menu em cada fase"
        )
        check(
            phases.map(\.acceptsMenuAction) == [true, false, true, true, false, true, true],
            "gravação: o menu não faz nada a escolher nem a guardar"
        )
        check(
            phases.map(\.isBusy) == [false, true, true, true, true, false, false],
            "gravação: microfone e som do Mac bloqueados durante uma gravação"
        )
        check(
            phases.map(\.showsBubble) == [false, false, true, true, true, true, true],
            "gravação: bolha em todas as fases menos repouso e escolha"
        )
        check(
            RecordingClock.text(0) == "00:00" && RecordingClock.text(83) == "01:23"
                && RecordingClock.text(3_723) == "1:02:03",
            "gravação: relógio 00:00, 01:23 e 1:02:03"
        )
    }

```

- [ ] **Step 2: Confirmar que falha**

Run: `swift build 2>&1 | grep error | head -3`
Expected: `error: cannot find type 'RecordingPhase' in scope`.

- [ ] **Step 3: Implementar**

Criar `Sources/WishperPro/RecordingController.swift`:

```swift
import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingPhase: Equatable {
    case idle
    case choosing
    case countdown(Int)
    case recording(since: Date)
    case saving
    case saved(URL)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .countdown: return "Cancelar gravação"
        case .recording: return "Parar gravação"
        case .saving: return "A guardar…"
        case .idle, .choosing, .saved, .failed: return "Gravar ecrã…"
        }
    }

    /// The menu item does nothing while the picker is open or the file is being saved.
    var acceptsMenuAction: Bool {
        switch self {
        case .choosing, .saving: return false
        case .idle, .countdown, .recording, .saved, .failed: return true
        }
    }

    /// A recording is being prepared, made or saved: the microphone and sound settings wait for the next one.
    var isBusy: Bool {
        switch self {
        case .choosing, .countdown, .recording, .saving: return true
        case .idle, .saved, .failed: return false
        }
    }

    /// The bubble shows every phase except idle and choosing (the system picker is up then).
    var showsBubble: Bool {
        switch self {
        case .idle, .choosing: return false
        case .countdown, .recording, .saving, .saved, .failed: return true
        }
    }
}

/// "01:23", or "1:02:03" from an hour on.
enum RecordingClock {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}

struct RecordingInput: Identifiable, Equatable {
    let id: String
    let name: String
}

private enum RecordingDefaultsKey {
    static let microphone = "wishper.recording_microphone"
    static let systemAudio = "wishper.recording_system_audio"
}

/// Screen recording from the menu: picker → countdown → recording → the file in Finder. Kept apart from
/// VoicePasteViewModel, which stays the source of truth for dictation. ScreenCaptureKit needs macOS 15, so the
/// recorder is kept as `AnyObject` and everything that touches it is behind `#available`.
@MainActor
final class RecordingController: ObservableObject {
    static var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// Shown under the recording in the bubble (e.g. no microphone access).
    @Published private(set) var notice: String?
    @Published private(set) var microphones: [RecordingInput] = []
    @Published var microphoneID = UserDefaults.standard.string(forKey: RecordingDefaultsKey.microphone) ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: RecordingDefaultsKey.microphone) }
    }
    @Published var recordsSystemAudio = UserDefaults.standard.bool(forKey: RecordingDefaultsKey.systemAudio) {
        didSet { UserDefaults.standard.set(recordsSystemAudio, forKey: RecordingDefaultsKey.systemAudio) }
    }

    /// Windows the picker leaves out besides the app's own: the bubble. Set by the AppDelegate.
    var excludedWindowIDs: @MainActor () -> [Int] = { [] }

    /// The menu's choice: a saved microphone that is not connected shows as the system default.
    var menuMicrophone: String {
        RecordingMicrophone(storedValue: microphoneID, connected: microphones.map(\.id)).storedValue
    }

    private let soundCuePlayer = SoundCuePlayer()
    private var recorder: AnyObject?
    private var pickerObserver: AnyObject?
    private var countdown: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var clock: Timer?
    private var resetTask: Task<Void, Never>?
    private var deviceObservers: [NSObjectProtocol] = []

    init() {
        guard Self.isSupported else { return }
        refreshMicrophones()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
            deviceObservers.append(observer)
        }
    }

    /// The menu item: record, cancel the countdown or stop, depending on the phase.
    func toggle() {
        switch phase {
        case .idle, .saved, .failed: choose()
        case .countdown: cancel()
        case .recording: stop()
        case .choosing, .saving: break
        }
    }

    func showRecordings() {
        let folder = RecordingFile.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Quitting: a recording in progress is saved, and a countdown cancelled, before the app goes.
    func finishBeforeQuit() async {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else {
            await stopTask?.value
            return
        }
        switch phase {
        case .countdown:
            clearRecording()
            await recorder.cancel()
        case .recording:
            stop()
            await stopTask?.value
        default:
            await stopTask?.value
        }
    }

    private func refreshMicrophones() {
        guard #available(macOS 14, *) else { return }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { RecordingInput(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func choose() {
        guard #available(macOS 15, *) else { return }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        // The app leaves itself out, so the bubble never shows in the video (checked on macOS 26).
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        configuration.excludedWindowIDs = excludedWindowIDs()
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        let observer = PickerObserver(
            onPick: { [weak self] filter in self?.picked(filter) },
            onCancel: { [weak self] in
                self?.pickerClosed()
                self?.setPhase(.idle)
            },
            onFailure: { [weak self] error in
                self?.pickerClosed()
                self?.fail(.startFailed(ScreenRecordingError.reason(error)))
            }
        )
        picker.add(observer)
        pickerObserver = observer
        picker.isActive = true
        setPhase(.choosing)
        picker.present()
    }

    @available(macOS 15, *)
    private func picked(_ filter: SCContentFilter) {
        guard phase == .choosing else { return }
        Task { await begin(filter) }
    }

    /// Starts the stream (the microphone warms up during the countdown), then writes from the end of the countdown.
    @available(macOS 15, *)
    private func begin(_ filter: SCContentFilter) async {
        let folder = RecordingFile.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            pickerClosed()
            fail(.folderUnavailable)
            return
        }
        var microphone = RecordingMicrophone(storedValue: microphoneID, connected: microphones.map(\.id))
        var notice: String?
        if microphone != .off, !(await microphoneAllowed()) {
            microphone = .off
            notice = "Sem acesso ao microfone: a gravar sem voz."
        }
        let recorder: ScreenRecorder
        do {
            recorder = try ScreenRecorder(
                filter: filter,
                microphone: microphone,
                systemAudio: recordsSystemAudio,
                url: RecordingFile.url(for: Date(), in: folder)
            )
        } catch {
            pickerClosed()
            fail(.startFailed(ScreenRecordingError.reason(error)))
            return
        }
        recorder.onMicrophone = { [weak self] _, level in
            Task { @MainActor in self?.level = level }
        }
        recorder.onEnded = { [weak self] error in
            Task { @MainActor in self?.ended(error) }
        }
        do {
            try await recorder.start()
        } catch {
            await recorder.cancel()
            pickerClosed()
            fail(.startFailed(ScreenRecordingError.reason(error)))
            return
        }
        self.recorder = recorder
        soundCuePlayer.playStartCue()
        countdown = Task { [weak self] in
            for second in [3, 2, 1] {
                self?.setPhase(.countdown(second))
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.startWriting(notice: notice)
        }
    }

    private func startWriting(notice: String?) {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        recorder.beginWriting()
        self.notice = notice
        let since = Date()
        elapsed = 0
        setPhase(.recording(since: since))
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = Date().timeIntervalSince(since) }
        }
        // The common modes keep the time running while the menu is open.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    private func stop() {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        setPhase(.saving)
        clock?.invalidate()
        stopTask = Task { [weak self] in
            do {
                let url = try await recorder.stop()
                self?.finish(url, failure: nil)
            } catch {
                self?.finish(recorder.url, failure: error)
            }
        }
    }

    /// Cancelled during the countdown: nothing is kept.
    private func cancel() {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        clearRecording()
        setPhase(.idle)
        Task { await recorder.cancel() }
    }

    /// The stream ended by itself (the person stopped it from the system's menu, or it failed).
    private func ended(_ error: Error?) {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        switch phase {
        case .countdown:
            // Nothing was written yet.
            clearRecording()
            if let error {
                fail(.startFailed(ScreenRecordingError.reason(error)))
            } else {
                setPhase(.idle)
            }
        case .recording:
            finish(recorder.url, failure: error)
        default:
            break
        }
    }

    /// The file is closed: shown in Finder, then "Gravação guardada" or why the recording stopped.
    private func finish(_ url: URL, failure: Error?) {
        clearRecording()
        soundCuePlayer.playStopCue()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if let failure {
            fail(.interrupted(ScreenRecordingError.reason(failure)))
        } else {
            setPhase(.saved(url))
        }
    }

    private func clearRecording() {
        recorder = nil
        stopTask = nil
        countdown?.cancel()
        countdown = nil
        clock?.invalidate()
        clock = nil
        level = 0
        elapsed = 0
        notice = nil
        pickerClosed()
    }

    private func pickerClosed() {
        guard #available(macOS 15, *), let observer = pickerObserver as? PickerObserver else { return }
        SCContentSharingPicker.shared.remove(observer)
        SCContentSharingPicker.shared.isActive = false
        pickerObserver = nil
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func fail(_ error: ScreenRecordingError) {
        setPhase(.failed(error.localizedDescription))
    }

    /// `saved` stays visible for 2 s and `failed` for 4 s, then the phase returns to idle.
    private func setPhase(_ newPhase: RecordingPhase) {
        phase = newPhase
        resetTask?.cancel()
        let visibleFor: Duration
        switch newPhase {
        case .saved: visibleFor = .seconds(2)
        case .failed: visibleFor = .seconds(4)
        default: return
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: visibleFor)
            guard !Task.isCancelled, let self, self.phase == newPhase else { return }
            self.phase = .idle
        }
    }
}

/// Hands the system picker's answer to the main actor.
@available(macOS 15, *)
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let onPick: @MainActor (SCContentFilter) -> Void
    private let onCancel: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(
        onPick: @escaping @MainActor (SCContentFilter) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.onPick = onPick
        self.onCancel = onCancel
        self.onFailure = onFailure
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.onPick(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.onCancel() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.onFailure(error) }
    }
}
```

- [ ] **Step 4: Confirmar que passa**

Run: `swift build 2>&1 | grep -E "warning|error" ; .build/debug/WishperPro --selftest | grep -E "títulos|o menu não|bloqueados|bolha em|relógio|FALHOU|Tudo OK" ; .build/debug/WishperPro --selftest | grep -c "^  ok"`
Expected: sem avisos nem erros; 5 linhas novas `ok`; `== Tudo OK ==`; `153`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WishperPro/RecordingController.swift Sources/WishperPro/SelfTest.swift
git commit -m "$(cat <<'EOF'
Drive screen recording from picker to Finder

RecordingController opens the system picker with the app left out, counts
down three seconds while the microphone warms up, records, and shows the
file in Finder. It keeps the microphone and Mac-sound choices in
UserDefaults, falls back to the system default when the saved microphone
is gone, records without voice when microphone access is denied, and
saves a recording in progress before the app quits.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Menu, ícone da barra de menus e bolha

**Files:**
- Modify: `Sources/WishperPro/VoiceBubbleView.swift` (`RecordingBubbleView` antes de `private struct WaveformBars: View {`)
- Modify: `Sources/WishperPro/Services/FloatingBubbleController.swift` (ficheiro inteiro)
- Modify: `Sources/WishperPro/WishperProApp.swift` (ficheiro inteiro)

**Interfaces:**
- Consumes: `RecordingController`, `RecordingPhase`, `RecordingClock` (Task 4).
- Produces:
  - `struct RecordingBubbleView: View` — `init(phase: RecordingPhase, level: Double, elapsed: TimeInterval, notice: String?)`.
  - `FloatingBubbleController.init(viewModel: VoicePasteViewModel, recording: RecordingController)`;
    `var windowNumber: Int?`.
  - `AppDelegate.recording: RecordingController`; `MenuBarContent(viewModel:recording:)`; `MenuBarLabel(viewModel:recording:)`.

- [ ] **Step 1: Bolha da gravação**

Em `Sources/WishperPro/VoiceBubbleView.swift`, acrescentar imediatamente antes de `private struct WaveformBars: View {`:

```swift
/// The bubble during a screen recording: countdown, time and level, saving, saved or why it stopped.
struct RecordingBubbleView: View {
    let phase: RecordingPhase
    let level: Double
    let elapsed: TimeInterval
    let notice: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                leading
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(BubbleBackground(reduceTransparency: reduceTransparency, highContrast: contrast == .increased))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .countdown(let seconds):
            Text("A gravar em \(seconds)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            WaveformBars(level: level, animated: !reduceMotion)
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(RecordingClock.text(elapsed))
                .font(.callout.weight(.medium))
                .monospacedDigit()
            WaveformBars(level: level, animated: !reduceMotion)
        case .saving:
            ProgressView()
                .controlSize(.small)
            Text("A guardar…")
                .font(.callout.weight(.medium))
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Gravação guardada")
                .font(.callout.weight(.medium))
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        case .idle, .choosing:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .countdown(let seconds):
            return "Wishper Pro, a gravar em \(seconds)"
        case .recording:
            return "Wishper Pro, a gravar, \(RecordingClock.text(elapsed))"
        case .saving:
            return "Wishper Pro, a guardar a gravação"
        case .saved:
            return "Wishper Pro, gravação guardada"
        case .failed(let message):
            return "Wishper Pro, \(message)"
        case .idle, .choosing:
            return "Wishper Pro"
        }
    }
}

```

- [ ] **Step 2: A bolha mostra o ditado ou a gravação**

Substituir o conteúdo de `Sources/WishperPro/Services/FloatingBubbleController.swift` por:

```swift
import AppKit
import Combine
import SwiftUI

enum BubbleMode: String, CaseIterable, Identifiable {
    case liveText
    case compact
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveText: return "Texto ao vivo"
        case .compact: return "Compacta"
        case .hidden: return "Oculta"
        }
    }
}

enum BubblePosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: return "Em baixo ao centro"
        case .topCenter: return "Em cima ao centro"
        case .bottomRight: return "Canto inferior direito"
        }
    }
}

/// Floating, click-through panel that shows the dictation or the screen recording. It never takes focus.
@MainActor
final class FloatingBubbleController {
    private static let panelSize = NSSize(width: 520, height: 140)

    private let viewModel: VoicePasteViewModel
    private let recording: RecordingController
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var announcedDictation = DictationPhase.idle
    private var announcedRecording = RecordingPhase.idle

    init(viewModel: VoicePasteViewModel, recording: RecordingController) {
        self.viewModel = viewModel
        self.recording = recording
    }

    /// The bubble's window, which the screen recording picker leaves out.
    var windowNumber: Int? {
        panel?.windowNumber
    }

    func start() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingBubbleContent(viewModel: viewModel, recording: recording))
        self.panel = panel

        // @Published sends the new value before the property changes, so both phases come from the publishers.
        viewModel.$phase
            .removeDuplicates()
            .combineLatest(recording.$phase.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] dictation, recording in
                self?.show(dictation, recording)
            }
            .store(in: &cancellables)
    }

    /// A dictation takes the bubble; otherwise it shows the recording.
    private func show(_ dictation: DictationPhase, _ recordingPhase: RecordingPhase) {
        if dictation != announcedDictation {
            announcedDictation = dictation
            announce(dictation)
        }
        if recordingPhase != announcedRecording {
            announcedRecording = recordingPhase
            announce(recordingPhase)
        }
        guard let panel else { return }
        let isVisible: Bool
        switch dictation {
        case .failed:
            isVisible = true
        case .listening, .finalizing, .done:
            isVisible = viewModel.bubbleMode != .hidden
        case .idle:
            switch recordingPhase {
            case .idle, .choosing:
                isVisible = false
            case .failed:
                isVisible = true
            case .countdown, .recording, .saving, .saved:
                isVisible = viewModel.bubbleMode != .hidden
            }
        }
        guard isVisible else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            position(panel)
        }
        panel.orderFrontRegardless()
    }

    /// The panel has a fixed size; the pill aligns inside it, so the window never needs resizing.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = Self.panelSize
        let origin: NSPoint
        switch viewModel.bubblePosition {
        case .bottomCenter:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
        case .topCenter:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 8)
        case .bottomRight:
            origin = NSPoint(x: area.maxX - size.width - 18, y: area.minY + 92)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The panel never takes focus, so VoiceOver users hear state changes as announcements.
    private func announce(_ phase: DictationPhase) {
        switch phase {
        case .listening:
            post("A ouvir")
        case .done(let text), .failed(let text):
            post(text)
        case .idle, .finalizing:
            return
        }
    }

    private func announce(_ phase: RecordingPhase) {
        switch phase {
        case .recording:
            post("A gravar")
        case .saved:
            post("Gravação guardada")
        case .failed(let text):
            post(text)
        case .idle, .choosing, .countdown, .saving:
            return
        }
    }

    private func post(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

private struct FloatingBubbleContent: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Group {
            if viewModel.phase == .idle, recording.phase.showsBubble {
                RecordingBubbleView(
                    phase: recording.phase,
                    level: recording.level,
                    elapsed: recording.elapsed,
                    notice: recording.notice
                )
            } else {
                VoiceBubbleView(
                    phase: viewModel.phase,
                    mode: viewModel.bubbleMode,
                    level: viewModel.audioLevel,
                    liveText: viewModel.liveTranscript,
                    appName: viewModel.targetAppName,
                    appIcon: viewModel.targetAppIcon
                )
            }
        }
        .padding(12)
        .frame(width: 520, height: 140, alignment: alignment)
    }

    private var alignment: Alignment {
        switch viewModel.bubblePosition {
        case .bottomCenter: return .bottom
        case .topCenter: return .top
        case .bottomRight: return .bottomTrailing
        }
    }
}
```

- [ ] **Step 3: Menu, ícone e `AppDelegate`**

Substituir o conteúdo de `Sources/WishperPro/WishperProApp.swift` por:

```swift
import AppKit
import SwiftUI

struct WishperProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(viewModel: appDelegate.viewModel, recording: appDelegate.recording)
        } label: {
            MenuBarLabel(viewModel: appDelegate.viewModel, recording: appDelegate.recording)
        }
        .menuBarExtraStyle(.menu)

        // A WindowGroup, not Settings or Window: on macOS 26 only a WindowGroup window gets Finder's
        // one-row toolbar and a sidebar whose corners are concentric with the window's. Opening it
        // by value keeps it to one window.
        WindowGroup("Definições", id: SettingsOpener.windowID, for: String.self) { _ in
            SettingsView(viewModel: appDelegate.viewModel)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = VoicePasteViewModel()
    let recording = RecordingController()
    private lazy var bubbleController = FloatingBubbleController(viewModel: viewModel, recording: recording)

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel.applyDockVisibility()
        bubbleController.start()
        recording.excludedWindowIDs = { [weak self] in
            [self?.bubbleController.windowNumber].compactMap { $0 }
        }
        if viewModel.needsSetup {
            DispatchQueue.main.async { SettingsOpener.open() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsOpener.open()
        return false
    }

    /// A screen recording in progress is closed properly before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording.phase.isBusy else { return .terminateNow }
        Task {
            await recording.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Opens the Settings window from anywhere (menu, first launch, Dock) and brings it to the front.
/// Triggers the app menu's ⌘, item (OpenSettingsButton), which exists even for LSUIElement apps (verified on macOS 26).
@MainActor
enum SettingsOpener {
    static let windowID = "settings"

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: index)
        }
    }
}

/// The app menu's ⌘, item, which SettingsOpener triggers from outside SwiftUI.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Definições…") { openWindow(id: SettingsOpener.windowID, value: SettingsOpener.windowID) }
            .keyboardShortcut(",", modifiers: .command)
    }
}

struct MenuBarContent: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Text(viewModel.menuStatusText)
        Button(viewModel.isRecording ? "Parar ditado" : "Iniciar ditado") {
            viewModel.toggleRecordingFromButton()
        }
        .disabled(viewModel.isTranscribing)
        Button("Copiar última transcrição") {
            viewModel.copyLastTranscript()
        }
        .disabled(viewModel.lastTranscript.isEmpty)
        if RecordingController.isSupported {
            Divider()
            Button(recording.phase.menuTitle) {
                recording.toggle()
            }
            .disabled(!recording.phase.acceptsMenuAction)
            Picker("Microfone", selection: Binding(
                get: { recording.menuMicrophone },
                set: { recording.microphoneID = $0 }
            )) {
                Text("Predefinido do sistema").tag("")
                ForEach(recording.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
                Text("Sem microfone").tag("none")
            }
            .pickerStyle(.menu)
            .disabled(recording.phase.isBusy)
            Toggle("Som do Mac", isOn: $recording.recordsSystemAudio)
                .disabled(recording.phase.isBusy)
            Button("Mostrar gravações") {
                recording.showRecordings()
            }
        }
        Divider()
        Button("Definições…") {
            SettingsOpener.open()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Sobre o Wishper Pro") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Divider()
        Button("Sair do Wishper Pro") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Group {
            switch recording.phase {
            case .countdown(let seconds):
                recordingLabel("\(seconds)")
            case .recording:
                recordingLabel(RecordingClock.text(recording.elapsed))
            default:
                if viewModel.isRecording || viewModel.isTranscribing {
                    activeIcon
                } else {
                    Image(nsImage: BrandMark.image(pointSize: 18))
                        .renderingMode(.template)
                }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    /// Like macOS's own screen recording: a record symbol and the time, in the menu bar's monochrome.
    private func recordingLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "record.circle")
            Text(text)
                .monospacedDigit()
        }
    }

    private var accessibilityText: String {
        switch recording.phase {
        case .countdown(let seconds):
            return "Wishper Pro, a gravar em \(seconds)"
        case .recording:
            return "Wishper Pro, a gravar, \(RecordingClock.text(recording.elapsed))"
        default:
            return "Wishper Pro"
        }
    }

    @ViewBuilder
    private var activeIcon: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: viewModel.isRecording)
        } else {
            Image(systemName: "waveform")
        }
    }
}
```

- [ ] **Step 4: Build e autoteste**

Run: `swift build 2>&1 | grep -E "warning|error" ; .build/debug/WishperPro --selftest | tail -1 ; .build/debug/WishperPro --selftest | grep -c "^  ok"`
Expected: sem avisos nem erros; `== Tudo OK ==`; `153`.

- [ ] **Step 5: Teste rápido na app dev**

Run: `./scripts/run-dev-app.sh` (fecha também a app instalada) e, se o macOS pedir, `tccutil reset Microphone com.wishper.pro.dev`
seguido de dar a permissão de microfone nas Definições da app dev.

Confirmar à mão:
- o menu tem "Gravar ecrã…", "Microfone ▸" (com os microfones ligados), "Som do Mac" e "Mostrar gravações";
- "Gravar ecrã…" abre o seletor do sistema e a app dev não aparece nele;
- depois de escolher o ecrã inteiro: "A gravar em 3", "2", "1" na bolha, o som de início, depois o ponto vermelho, o tempo e as
  barras; o ícone da barra de menus mostra `record.circle` e o tempo, e o tempo não para com o menu aberto;
- "Parar gravação" → "A guardar…" → "Gravação guardada", o som de fim, e o Finder mostra
  `Filmes/Wishper Pro/Gravação … .mov`; o ficheiro abre no QuickTime com a voz;
- a bolha não aparece no vídeo.

- [ ] **Step 6: Commit**

```bash
git add Sources/WishperPro/VoiceBubbleView.swift Sources/WishperPro/Services/FloatingBubbleController.swift Sources/WishperPro/WishperProApp.swift
git commit -m "$(cat <<'EOF'
Add screen recording to the menu, menu bar icon and bubble

The menu gains Gravar ecrã…, a microphone picker, a Mac sound toggle and
Mostrar gravações, on macOS 15 and later. While recording, the menu bar
shows a record symbol with the time, like macOS's own recorder, and the
bubble shows the countdown, time and level, then saved or why it stopped,
with VoiceOver announcements. A dictation still takes the bubble first.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Documentação (`CLAUDE.md`, `README.md`)

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: `CLAUDE.md`**

Em `## Architecture`, acrescentar depois da linha do `VoicePasteViewModel.swift`:

```markdown
- `RecordingController.swift` — gravação de ecrã a partir do menu (macOS 15+): seletor do sistema → contagem 3-2-1 → gravação → Finder; `RecordingPhase`, microfone e som do Mac em UserDefaults; guarda a gravação antes de sair.
```

Depois da linha `Pipeline: …`, acrescentar:

```markdown
Gravação: menu → `SCContentSharingPicker` (sem permissão de Gravação de Ecrã; a app exclui-se, por isso a bolha não aparece no vídeo) → `ScreenRecorder` arranca o stream (o microfone aquece durante a contagem de 3 s) → `RecordingWriter` escreve a partir do fim da contagem → `~/Movies/Wishper Pro/Gravação … .mov` → Finder. Voz e som do Mac em faixas separadas, no relógio do vídeo (base da tradução, parte 2).
```

Em `### Services`, substituir a linha do `MicrophoneStream` por:

```markdown
- `MicrophoneStream` — `AVAudioEngine` → PCM16 24 kHz mono em pedaços de 100 ms (`PCM16`, `PCMConverter` com qualquer formato de saída, `WAV`); reinicia com o formato novo quando o dispositivo muda (Bluetooth)
```

E acrescentar no fim da lista de serviços:

```markdown
- `ScreenRecorder` — um `SCStream` (ecrã, som do Mac, microfone) numa fila série → `RecordingWriter`; `onMicrophone` (PCM16 24 kHz + nível), `onEnded` (`nil` quando se para no menu do sistema); macOS 15+
- `RecordingWriter` — `AVAssetWriter` `.mov` com fragmentos de 10 s: H.264 (≤ 3840×2160, 30 fps), voz AAC mono 48 kHz (convertida e cronometrada por amostras), som do Mac AAC estéreo; `RecordingSize`, `RecordingFile`
```

Em `### Persistência`, substituir a linha do UserDefaults e a do áudio por:

```markdown
- **UserDefaults** (`DefaultsKey`, `TextSettings` e `RecordingController`, prefixo `wishper.`): atalho e comportamento, tradução e línguas, colar, repor clipboard, estilo e posição da bolha, ícone na Dock, limpeza por IA, estilo por tipo, tipo por app ou site, sítios recentes, dicionário, microfone e som do Mac da gravação
- Áudio do ditado só em memória; gravações de ecrã em `~/Movies/Wishper Pro`; sem base de dados, sem backend
```

Em `### Concorrência`, substituir a primeira linha e acrescentar uma no fim:

```markdown
- `@MainActor`: ViewModel, `TextSettings`, `DictationSession`, `GlobalHotkeyMonitor`, `FloatingBubbleController`, `RecordingController`
```

```markdown
- `ScreenRecorder` é `@unchecked Sendable`: as amostras do ScreenCaptureKit chegam numa fila série, a única que usa o `RecordingWriter`; o `finish(at:)` do escritor é `nonisolated(nonsending)`
```

- [ ] **Step 2: `README.md`**

Em `## Highlights`, acrescentar depois do ponto "Push-to-talk or hands-free":

```markdown
- **Screen recording (macOS 15+).** Record a display, a window or an app picked in the system picker, with the microphone you choose and, if you want, the Mac's sound. No Screen Recording permission is needed, the bubble never shows in the video, and your voice goes in its own track on the video's clock — ready for translation.
```

No ponto "No backend", substituir "Audio never touches the disk" por "Dictation audio never touches the disk".

Em `## Requirements`, substituir a primeira linha por:

```markdown
- macOS 13 or later (the bubble uses Liquid Glass on macOS 26; screen recording needs macOS 15)
```

No fim de `## Using it`, acrescentar:

```markdown
To record the screen, open the menu bar menu and choose **Gravar ecrã…**, then pick a display, a window or an app. After a 3-2-1 countdown the bubble shows the time; choose **Parar gravação** in the menu to stop. The file lands in `~/Movies/Wishper Pro` and Finder shows it. **Microfone** and **Som do Mac** in the same menu set what the next recording captures.
```

Em `## Privacy`, substituir "Audio is kept in memory for the duration of the dictation and never written to disk." por:

```markdown
- Dictation audio is kept in memory for the duration of the dictation and never written to disk. Screen recordings are saved only to `~/Movies/Wishper Pro` and never uploaded.
```

Em `## Troubleshooting`, acrescentar duas linhas à tabela:

```markdown
| No "Gravar ecrã…" in the menu | Screen recording needs macOS 15 or later |
| "Gravação interrompida: …" | The recorded window closed, the display went away or the disk filled up; what was recorded is in `~/Movies/Wishper Pro` |
```

Em `## Project layout`, acrescentar `RecordingController.swift` depois de `VoicePasteViewModel.swift`, e
`RecordingWriter.swift` e `ScreenRecorder.swift` depois de `OpenAITextProcessor.swift`:

```text
  RecordingController.swift   # screen recording: picker, countdown, file in Finder
```

```text
    RecordingWriter.swift
    ScreenRecorder.swift
```

Em `## Development`, substituir `# 122 offline checks, no network` por `# 153 offline checks, no network`.

- [ ] **Step 3: Verificar e fazer commit**

Run: `grep -c "RecordingController\|ScreenRecorder\|RecordingWriter" CLAUDE.md README.md`
Expected: `CLAUDE.md:5` ou mais e `README.md:3` ou mais.

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
Document screen recording

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Verificação final

**Files:** nenhum (só verificação; registar os resultados na spec, secção "A confirmar na implementação").

- [ ] **Step 1: Build limpo**

Run: `swift build 2>&1 | grep -E "warning|error" ; swift build -c release 2>&1 | tail -1`
Expected: nenhuma linha `warning`/`error` vinda de ficheiros alterados; o build release termina com `Build complete!`.

- [ ] **Step 2: Autoteste completo**

Run: `./scripts/run-dev-app.sh --selftest`
Expected: 153 verificações offline e as online com `ok`; `== Tudo OK ==`.

- [ ] **Step 3: Lista manual (spec, "Verificação" ponto 3)**

Com `./scripts/run-dev-app.sh` e a permissão de microfone da app dev dada, confirmar e anotar:
- **ecrã inteiro:** 15 s a falar → o ficheiro aparece em Filmes/Wishper Pro e abre no QuickTime com voz; a bolha e o menu da
  app não aparecem no vídeo (abrir o menu a meio da gravação e ver o vídeo nesse instante);
- **janela e app:** gravar cada uma;
- **Som do Mac** ligado, com um vídeo a tocar noutra app: ouve-se no ficheiro; os sons de início e de fim da app não;
- **microfones:** Studio Display, iPhone e "Sem microfone" (este sem faixa de voz: no QuickTime, Janela → Mostrar Inspetor de
  Filme);
- **Redmi Buds:** a voz é contínua quando os auriculares mudam de perfil (ouvir o início do ficheiro);
- **janela fechada a meio:** "Gravação interrompida: …" e o ficheiro abre até esse ponto;
- **parar no menu do sistema** (o ícone de captura do macOS na barra de menus): conta como "Gravação guardada";
- **`kill -9` à app dev a meio** (`pkill -9 WishperPro` depois de 25 s): o ficheiro abre até ao último fragmento (perde no
  máximo 10 s);
- **sair da app a meio** (menu → Sair): a app espera, guarda o ficheiro e só depois fecha;
- **cancelar na contagem:** nada é guardado;
- **Bolha "Oculta":** a gravação só se vê no ícone da barra de menus;
- **aparência e acessibilidade:** modo claro e escuro; o VoiceOver anuncia "A gravar" e "Gravação guardada".

- [ ] **Step 4: Rever a spec**

Confirmar que cada secção da spec tem implementação: Plataforma e API; O que o utilizador vê (menu, bolha, barra de menus,
sons, ficheiro); Definições novas; Fluxo; Formato do ficheiro; Componentes; Erros; Ficheiros. Atualizar "A confirmar na
implementação" com o que se viu (menu e ícone fora da captura; tempo no ícone; Buds; `kill -9`) e anotar desvios.

- [ ] **Step 5: Fechar o branch**

Usar a skill superpowers:finishing-a-development-branch para decidir entre merge, PR ou manter o branch.
