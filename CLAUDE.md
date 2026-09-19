# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Compilar (debug)
swift build

# Verificações offline (sem rede nem bundle)
.build/debug/WishperPro --selftest

# Bundle dev em /tmp + verificações online (ao vivo, plano B e limpeza) com a API key do Keychain
./scripts/run-dev-app.sh --selftest

# Compilar e correr em modo dev (cria app bundle em /tmp)
./scripts/run-dev-app.sh

# Compilar e instalar release (~/Applications/Wishper Pro.app)
./scripts/install-local-release.sh
```

Não há target de testes: as verificações vivem em `SelfTest.swift` (`--selftest`). Ao mudar lógica (atalho, áudio, protocolo, clipboard, estilos, limpeza), acrescentar lá uma verificação. A interface verifica-se à mão com `./scripts/run-dev-app.sh`. Se as verificações online disserem que não há key, abrir a app dev, guardar a key nas Definições e repetir.

## Architecture

App macOS de barra de menus em Swift 6.2 / SwiftUI, compilada com Swift Package Manager (sem dependências externas). Target: macOS 13+ (APIs do macOS 14/26 atrás de `#available`).

- `SelfTest.swift` — ponto de entrada (`@main`): `--selftest` corre as verificações; senão arranca `WishperProApp`.
- `WishperProApp.swift` — `MenuBarExtra` (menu nativo) + janela das Definições (`WindowGroup` aberto por valor, uma só janela; ⌘, via `CommandGroup`); `AppDelegate` (política de ativação, bolha, primeiro arranque); `SettingsOpener`.
- `SettingsView.swift` — Definições com barra lateral estilo Finder (`NavigationSplitView`): Geral, Ditado, Bolha, Gravação (macOS 15+: voz da tradução com amostra, legendas); Texto: Estilos, Dicionário, Tradução (`Form` `.grouped`). No macOS 26 só um `WindowGroup` com barra de ferramentas dá a barra lateral até ao topo com cantos concêntricos (`Settings` e `Window` não).
- `VoicePasteViewModel.swift` — fonte de verdade: `DictationPhase`, definições (`DefaultsKey`), atalho, entrega do texto.
- `RecordingController.swift` — gravação de ecrã a partir do menu (macOS 15+): seletor do sistema → contagem 3-2-1 → gravação → Finder; `RecordingPhase`, microfone, som do Mac, língua, voz e legendas da tradução em UserDefaults; guarda a gravação antes de sair (e cancela uma tradução a meio).
- `TextStyles.swift` — tipos de app (`AppCategory`), estilos (`TextStyle`), catálogo de apps e sites (`StyleCatalog`), dicionário (`PersonalDictionary`) e `TextSettings` (definições de texto em UserDefaults).
- `DictationSession.swift` — um ditado: microfone → `gpt-live-transcribe` → texto final; plano B `gpt-transcribe` com o áudio em memória.
- `VoiceBubbleView.swift` + `Services/FloatingBubbleController.swift` — bolha (Texto ao vivo / Compacta / Oculta; 3 posições; Liquid Glass no macOS 26).
- `BrandMark.swift` — símbolo da marca (`BrandMark.svg`, copiado de `logo.svg` pelos scripts) como imagem template.

Pipeline: atalho → `FocusDetector` (app ou site → tipo → estilo) + `DictationSession.start()` (microfone + WebSocket com as `keywords` do dicionário) → texto ao vivo na bolha → `finish()` (commit) → `OpenAITextProcessor` (limpeza, estilo e tradução numa chamada, quando preciso) → colar (repõe o clipboard) → "Colado · App". Se a limpeza falhar, cola o texto transcrito com um aviso.

Gravação: menu → `SCContentSharingPicker` (sem permissão de Gravação de Ecrã; a app exclui-se, por isso a bolha não aparece no vídeo) → `ScreenRecorder` arranca o stream (o microfone aquece durante a contagem de 3 s) → `RecordingWriter` escreve a partir do fim da contagem → `~/Movies/Wishper Pro/Gravação … .mov` → Finder. Voz e som do Mac em faixas separadas, no relógio do vídeo.

Tradução (menu "Traduzir para ▸"): cada bloco de voz escrito no ficheiro, com o seu tempo → `RecordingTranslator` (`PhraseDetector` → `gpt-transcribe` com o dicionário → `gpt-5.6-luna` em modo narração → a GPT-Live lê a tradução palavra por palavra), durante a gravação → ao parar, as últimas frases e uma nova tentativa das que falharam → `TranslatedVideoExporter`: cada leitura no início da sua frase (acelera até 1,25×), mistura com o som do Mac, legendas no leitor (`tx3g`), na imagem ou nenhumas → `Gravação … (Inglês).mp4` ao lado do original → Finder. O original nunca é tocado.

### Services (Sources/WishperPro/Services/)

- `MicrophoneStream` — `AVAudioEngine` → PCM16 24 kHz mono em pedaços de 100 ms (`PCM16`, `PCMConverter` com qualquer formato de saída, `WAV`); reinicia com o formato novo quando o dispositivo muda (Bluetooth)
- `OpenAIRealtimeTranscriber` — actor; `wss://api.openai.com/v1/realtime?intent=transcription`, `turn_detection: null`, commit manual, `keywords`
- `OpenAITranscriptionClient` — plano B: POST /v1/audio/transcriptions com `gpt-transcribe`, `languages[]` e `keywords[]`
- `OpenAITextProcessor` — POST /v1/chat/completions com `gpt-5.6-luna` (`reasoning_effort: "none"`, resposta JSON `{"text"}`); recusa respostas vazias ou muito maiores do que o ditado
- `FocusDetector` — app da frente e, em browsers, o domínio da página pela Acessibilidade (0,25 s por pedido); só o domínio fica no Mac
- `GlobalHotkeyMonitor` — Carbon (premir/largar) + NSEvent (só-modificador); Esc registado só durante o ditado e ⌃⌘Esc só durante a gravação (o `RecordingController` tem o seu monitor; cada handler passa os atalhos que não são seus); `HotkeyDecider`
- `AutoPaster` — Accessibility + Cmd+V; guarda e repõe o clipboard
- `KeychainService` — API key no Keychain (service: com.wishperpro.desktop)
- `SoundCuePlayer` — sons de início/fim
- `Permissions` — pedido de acesso ao microfone
- `ScreenRecorder` — um `SCStream` (ecrã, som do Mac, microfone) numa fila série → `RecordingWriter`; `onMicrophone` (PCM16 24 kHz + nível), `onVoice` (cada bloco escrito, em PCM16 24 kHz, com o seu tempo no ficheiro), `onEnded` (`nil` quando se para no menu do sistema; também quando a janela ou a app gravada fecha); quem fecha o ficheiro é o `RecordingController`; macOS 15+
- `RecordingWriter` — `AVAssetWriter` `.mov` com fragmentos de 10 s: H.264 (≤ 3840×2160, 30 fps), voz AAC mono 48 kHz (convertida e cronometrada por amostras, `voiceTime`), som do Mac AAC estéreo; `RecordingSize`, `RecordingFile`
- `PhraseDetector` — frases pela pausa (600 ms), com o limiar 12 dB acima do ruído da sala (percentil 10 dos últimos 10 s); corta frases de mais de 15 s no ponto mais baixo
- `GPTLiveReader` — actor; `wss://api.openai.com/v1/live/sessions` (`gpt-live-1`): narrador que lê cada texto palavra por palavra (`session.commentary.append`), confirma pela transcrição; `LiveVoice` (22 vozes), `VoicePreview` (amostras em Caches)
- `RecordingTranslator` — actor: frases em ordem, transcrever e traduzir (com as 3 anteriores como contexto) sobreposto com ler; 3 tentativas por chamada, mais uma volta no fim; uma key recusada para tudo
- `TranslatedVideoExporter` — `VoicePlacement`, `SubtitleCues`, áudio misturado (AAC estéreo), faixa `tx3g` ou legendas desenhadas (imagem por legenda + `AVVideoCompositionCoreAnimationTool`), `AVAssetExportSession`; macOS 15+

### Persistência

- **Keychain**: API key OpenAI (único segredo)
- **UserDefaults** (`DefaultsKey`, `TextSettings` e `RecordingController`, prefixo `wishper.`): atalho e comportamento, tradução e línguas, colar, repor clipboard, estilo e posição da bolha, ícone na Dock, limpeza por IA, estilo por tipo, tipo por app ou site, sítios recentes, dicionário, microfone, som do Mac, língua, voz e legendas da gravação
- Áudio do ditado só em memória; gravações de ecrã e vídeos traduzidos em `~/Movies/Wishper Pro`; amostras das vozes em `~/Library/Caches/<bundle>/Vozes`; sem base de dados, sem backend

### Concorrência

- `@MainActor`: ViewModel, `TextSettings`, `DictationSession`, `GlobalHotkeyMonitor`, `FloatingBubbleController`, `RecordingController`
- `OpenAIRealtimeTranscriber` é um actor; áudio e deltas passam por `AsyncStream` para manter a ordem
- `MicrophoneStream` é `@unchecked Sendable` com `NSLock` (o tap corre numa thread de áudio)
- `FocusDetector` lê a Acessibilidade numa tarefa separada (`Task.detached`); o ViewModel espera pelo resultado no fim do ditado
- `ScreenRecorder` é `@unchecked Sendable`: as amostras do ScreenCaptureKit chegam numa fila série, a única que usa o `RecordingWriter`; o `finish(at:)` do escritor é `nonisolated(nonsending)`
- `GPTLiveReader` e `RecordingTranslator` são actors; a voz entra no tradutor por `AsyncStream` (mantém a ordem) e as frases traduzidas passam à leitura por outro

## Key Conventions

- UI e erros em Português (pt-PT); interface nativa (HIG), segue claro/escuro do sistema
- Marca monocromática; cores do sistema só com significado (vermelho erro, verde sucesso)
- Erros dos serviços como enums `LocalizedError`
- Modelos: `gpt-live-transcribe` (ao vivo), `gpt-transcribe` (plano B e frases da gravação), `gpt-5.6-luna` (limpeza e tradução), `gpt-live-1` (voz da gravação traduzida)
- `Data`: para cortar o início usar `removeSubrange(0..<n)`; `removeFirst(n)` desloca os índices e `subdata(in: 0..<n)` rebenta
- Sem .env — configuração via Keychain + UserDefaults
- Trabalho em paralelo com outras sessões: usar worktrees (`.claude/worktrees/`, ignorado em `.git/info/exclude`)
