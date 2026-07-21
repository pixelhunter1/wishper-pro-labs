# Wishper "essencial" — design

Data: 2026-07-21
Branch: `simplify-core-pipeline`

## Objetivo

Reduzir a app ao fluxo essencial: **ditar → transcrever → (traduzir opcional) → colar**.
Remover tudo o resto. Usar sempre os modelos de melhor preço/qualidade, fixos (sem seletor).

Nota de custo: a app já era baratíssima (~$0.14/mês). Esta limpeza é sobre **simplicidade**, não poupança.

## Mantém-se

- Guardar/remover **API key** (Keychain).
- **Atalho push-to-talk** configurável (essencial para ditar sem rato).
- **Permissão de Acessibilidade** (necessária para colar).
- **Tradução**: toggle on/off + escolha de língua origem/destino (pt-PT, pt-BR, en, es, fr, de, it).
- **Bolha flutuante** com estado (a gravar / a transcrever).
- **Auto-paste** no campo ativo.

## Remove-se

- **TTS/voz por completo**: `OpenAITTSClient.swift`, vozes, modelos de voz, botões falar/pré-ouvir,
  e a chamada extra de tradução que o TTS fazia para normalizar português.
- **Seletor de modelo de transcrição**: fica fixo em `gpt-4o-mini-transcribe`.
- **Painel de diagnósticos** de transcrição (métricas + histórico).
- **Seleção de sons** de início/fim: fica um som fixo (início = Pop, fim = Tink).
- `PortugueseVariant`, `TranscriptionModel`, `TTSVoice`, `TTSModel`, `RecordingCueSound` — enums deixam de ser necessários.

## Modelos fixos (melhor preço/qualidade)

- Transcrição: `gpt-4o-mini-transcribe`
- Tradução: `gpt-4o-mini` (já era o default do `OpenAITranslationClient`)

## Ficheiros afetados

- `Services/OpenAITTSClient.swift` — **apagado**.
- `VoicePasteViewModel.swift` — reescrito sem TTS, diagnósticos, seletor de modelo, variante PT, seleção de sons.
- `Services/SoundCuePlayer.swift` — simplificado para sons fixos.
- `Services/FloatingBubbleController.swift` — deixa de observar `isSpeaking`.
- `ContentView.swift` — remove cartões de TTS, modelo e diagnóstico, botão "Ouvir", e seleção de sons.

## Migração de definições guardadas

Valores antigos `"pt"` em origem/destino migram para `"pt-PT"` por omissão.

## Verificação

`swift build` limpo. Teste manual do fluxo ditar → colar (+ tradução on/off) via `./scripts/run-dev-app.sh`.
