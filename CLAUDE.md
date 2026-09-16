# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Compilar (debug)
swift build

# Verificações offline (sem rede nem bundle)
.build/debug/WishperPro --selftest

# Bundle dev em /tmp + verificações online (ao vivo + plano B) com a API key do Keychain
./scripts/run-dev-app.sh --selftest

# Compilar e correr em modo dev (cria app bundle em /tmp)
./scripts/run-dev-app.sh

# Compilar e instalar release (~/Applications/Wishper Pro.app)
./scripts/install-local-release.sh
```

Não há target de testes: as verificações vivem em `SelfTest.swift` (`--selftest`). Ao mudar lógica (atalho, áudio, protocolo, clipboard), acrescentar lá uma verificação. A interface verifica-se à mão com `./scripts/run-dev-app.sh`. Se as verificações online disserem que não há key, abrir a app dev, guardar a key nas Definições e repetir.

## Architecture

App macOS de barra de menus em Swift 6.2 / SwiftUI, compilada com Swift Package Manager (sem dependências externas). Target: macOS 13+ (APIs do macOS 14/26 atrás de `#available`).

- `SelfTest.swift` — ponto de entrada (`@main`): `--selftest` corre as verificações; senão arranca `WishperProApp`.
- `WishperProApp.swift` — `MenuBarExtra` (menu nativo) + `Settings`; `AppDelegate` (política de ativação, bolha, primeiro arranque); `SettingsOpener`.
- `SettingsView.swift` — Definições (⌘,): Geral, Ditado, Bolha, Tradução (`Form` `.grouped`).
- `VoicePasteViewModel.swift` — fonte de verdade: `DictationPhase`, definições (`DefaultsKey`), atalho, entrega do texto.
- `DictationSession.swift` — um ditado: microfone → `gpt-live-transcribe` → texto final; plano B `gpt-transcribe` com o áudio em memória.
- `VoiceBubbleView.swift` + `Services/FloatingBubbleController.swift` — bolha (Texto ao vivo / Compacta / Oculta; 3 posições; Liquid Glass no macOS 26).
- `BrandMark.swift` — símbolo da marca (`BrandMark.svg`, copiado de `logo.svg` pelos scripts) como imagem template.

Pipeline: atalho → `DictationSession.start()` (microfone + WebSocket em paralelo) → texto ao vivo na bolha → `finish()` (commit) → tradução opcional → colar (repõe o clipboard) → "Colado · App".

### Services (Sources/WishperPro/Services/)

- `MicrophoneStream` — `AVAudioEngine` → PCM16 24 kHz mono em pedaços de 100 ms (`PCM16`, `PCMConverter`, `WAV`)
- `OpenAIRealtimeTranscriber` — actor; `wss://api.openai.com/v1/realtime?intent=transcription`, `turn_detection: null`, commit manual
- `OpenAITranscriptionClient` — plano B: POST /v1/audio/transcriptions com `gpt-transcribe` e `languages[]`
- `OpenAITranslationClient` — POST /v1/chat/completions (gpt-4o-mini)
- `GlobalHotkeyMonitor` — Carbon (premir/largar) + NSEvent (só-modificador); Esc registado só durante o ditado; `HotkeyDecider`
- `AutoPaster` — Accessibility + Cmd+V; guarda e repõe o clipboard
- `KeychainService` — API key no Keychain (service: com.wishperpro.desktop)
- `SoundCuePlayer` — sons de início/fim
- `Permissions` — pedido de acesso ao microfone

### Persistência

- **Keychain**: API key OpenAI (único segredo)
- **UserDefaults** (`DefaultsKey`, prefixo `wishper.`): atalho e comportamento, tradução e línguas, colar, repor clipboard, estilo e posição da bolha, ícone na Dock
- Áudio só em memória; sem base de dados, sem backend

### Concorrência

- `@MainActor`: ViewModel, `DictationSession`, `GlobalHotkeyMonitor`, `FloatingBubbleController`
- `OpenAIRealtimeTranscriber` é um actor; áudio e deltas passam por `AsyncStream` para manter a ordem
- `MicrophoneStream` é `@unchecked Sendable` com `NSLock` (o tap corre numa thread de áudio)

## Key Conventions

- UI e erros em Português (pt-PT); interface nativa (HIG), segue claro/escuro do sistema
- Marca monocromática; cores do sistema só com significado (vermelho erro, verde sucesso)
- Erros dos serviços como enums `LocalizedError`
- Modelos: `gpt-live-transcribe` (ao vivo), `gpt-transcribe` (plano B), `gpt-4o-mini` (tradução)
- Sem .env — configuração via Keychain + UserDefaults
- Trabalho em paralelo com outras sessões: usar worktrees (`.claude/worktrees/`, ignorado em `.git/info/exclude`)
