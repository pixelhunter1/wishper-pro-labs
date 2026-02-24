# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Compilar (debug)
swift build

# Compilar e correr em modo dev (cria app bundle em /tmp)
./scripts/run-dev-app.sh

# Compilar e instalar release (~/Applications/Wishper Pro.app)
./scripts/install-local-release.sh
```

Não existem testes unitários no projeto. Verificar alterações compilando com `swift build` e testando manualmente via `./scripts/run-dev-app.sh`.

## Architecture

Aplicação macOS nativa em Swift 6.2 / SwiftUI, compilada com Swift Package Manager (sem dependências externas). Target: macOS 13+.

### MVVM com ViewModel central

`VoicePasteViewModel` é o single source of truth — orquestra todo o pipeline de voz, gere estado publicado (@Published) e persiste configurações. Todos os serviços são invocados a partir deste ViewModel.

Pipeline: gravar áudio → transcrever (OpenAI) → traduzir (opcional) → auto-paste → TTS (opcional).

### Services (Sources/WishperPro/Services/)

Cada serviço é stateless e focado numa responsabilidade:

- `AudioRecorder` — AVAudioRecorder wrapper (AAC 16kHz mono), metering para nível áudio
- `GlobalHotkeyMonitor` — Carbon EventManager para hotkeys globais + fallback NSEvent
- `OpenAITranscriptionClient` — POST /v1/audio/transcriptions, multipart upload, métricas e retries
- `OpenAITranslationClient` — POST /v1/chat/completions (gpt-4o-mini) para tradução
- `OpenAITTSClient` — POST /v1/audio/speech (13 vozes, 4 modelos)
- `AutoPaster` — Accessibility API (AXUIElement) para verificar campo editável e simular Cmd+V
- `FloatingBubbleController` — NSPanel flutuante com estado visual
- `KeychainService` — CRUD da API key no Keychain (service: com.wishperpro.desktop)
- `SoundCuePlayer` — sons de sistema para feedback de gravação

### UI (Sources/WishperPro/)

- `WishperProApp.swift` — Entry point, AppDelegate, menu bar
- `ContentView.swift` — Layout principal com 2 tabs (Home/Opções), componentes inline (HomePage, OptionsPage, DarkCard)
- `VoiceBubbleView.swift` — Vista do indicador flutuante

### Persistência

- **Keychain**: API key OpenAI (único segredo)
- **UserDefaults**: todas as preferências (hotkey, modelo, tradução, voz TTS, sons)
- **FileManager**: ficheiros áudio temporários em /var/tmp/ (removidos após transcrição)
- Sem base de dados, sem backend

### Concorrência

- `@MainActor` no ViewModel e FloatingBubbleController
- Swift structured concurrency (async/await, Task) para chamadas API
- Audio metering via Task.sleep polling a cada 120ms

## Key Conventions

- UI e mensagens de erro em Português (pt-PT)
- Erros dos serviços usam enums `LocalizedError` com mensagens descritivas em português
- Hotkey debounce de 600ms para evitar triggers duplos
- Ficheiros áudio temporários com prefixo `wishper-` e UUID
- Sem .env — configuração toda via Keychain + UserDefaults
