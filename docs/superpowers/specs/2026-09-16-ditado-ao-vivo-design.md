# Ditado ao vivo + bolha nova + interface nativa — design (parte 1 de 3)

Data: 2026-09-16
Branch: `worktree-ditado-ao-vivo` (worktree `.claude/worktrees/ditado-ao-vivo`)

## Contexto

Hoje a app grava um m4a (`AVAudioRecorder`), envia-o no fim para `gpt-4o-mini-transcribe`, traduz opcionalmente com
`gpt-4o-mini` e cola com Cmd+V. Problemas:

- o texto só aparece depois de parar;
- a bolha flutuante é antiga (retângulo preto 150×50 no canto, ponto vermelho);
- o atalho só alterna (carregar/carregar);
- o auto-paste apaga o clipboard e nunca o repõe;
- a janela principal usa um estilo próprio, sempre escuro, fora das convenções do macOS.

Desde 28 jul 2026 a OpenAI tem `gpt-live-transcribe` (texto enquanto se fala) e `gpt-transcribe` (ficheiros);
os `gpt-4o-*-transcribe` passaram a legado.

## Objetivos

1. Ver o texto enquanto se fala e ter o texto final pronto quase no instante em que se para.
2. Bolha moderna e discreta, com modos e posições à escolha.
3. Atalho moderno: manter premido para falar, toque para mãos-livres.
4. Não perder o que estava no clipboard.
5. Interface 100% nativa do macOS (HIG) e fiel à marca Wishper Pro.

Critério para todas as escolhas de interface: a predefinição é a opção mais moderna e menos intrusiva; as
alternativas ficam disponíveis nas Definições.

## Fora de âmbito (próximas partes)

- **Parte 2:** deteção da app/site ativo → estilo; limpeza por IA; dicionário pessoal (`keywords`); tradução e
  limpeza com `gpt-5.6-luna`.
- **Parte 3 (se fizer falta):** histórico, comandos de voz sobre texto selecionado, snippets, tecla Fn, ícone da
  app no novo formato do macOS 26.

## Modelos e API

### Ao vivo — `gpt-live-transcribe` ($0,017/min)

- WebSocket `wss://api.openai.com/v1/realtime?intent=transcription`, header `Authorization: Bearer <key>`.
  Sem header `OpenAI-Beta` (esse header ativa a interface beta, com outro formato de sessão).
- Primeira mensagem depois de ligar:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": {
          "model": "gpt-live-transcribe",
          "prompt": "Transcrição em português europeu de Portugal. …",
          "languages": ["pt"],
          "delay": "low"
        },
        "turn_detection": null
      }
    }
  }
}
```

- `languages` é omitido quando a língua do ditado é Auto; `prompt` é omitido quando não há (hoje só existe para
  pt-PT e pt-BR — os textos atuais de `transcriptionPrompt()` mantêm-se).
- `turn_detection: null` é obrigatório: este modelo recusa VAD. Encaixa no push-to-talk.
- Áudio: `{"type":"input_audio_buffer.append","audio":"<base64>"}`, PCM16 little-endian, 24 kHz, mono, em
  pedaços de 100 ms (2400 amostras = 4800 bytes).
- Fim: `{"type":"input_audio_buffer.commit"}`. Nunca enviar commit com o buffer vazio (a API devolve erro).
- Eventos lidos (os restantes são ignorados):
  - `session.updated` → sessão pronta;
  - `conversation.item.input_audio_transcription.delta` → campo `delta` (texto parcial);
  - `conversation.item.input_audio_transcription.completed` → campo `transcript` (texto final);
  - `error` → campo `error.message`.
- `delay: "low"` (~1,2 s até ao primeiro texto). É uma constante; depois de medir pode passar a `minimal`
  (~0,7 s) se a qualidade se mantiver.
- Texto final = `transcript` do primeiro `completed` recebido depois do commit. Os `delta` servem só para a
  pré-visualização.

### Plano B — `gpt-transcribe` ($0,0045/min)

- `POST /v1/audio/transcriptions`, multipart: `model=gpt-transcribe`, `response_format=json`, `prompt`,
  `languages[]` (substitui `language`; nunca enviar os dois) e `file` = WAV (PCM16 24 kHz mono) com o áudio
  guardado em memória.
- Limite de 25 MB ≈ 8 min de áudio.

### Custo

Com o uso atual (~47 min/mês): cerca de $0,80/mês (antes ~$0,14/mês).

## Estrutura da app (macOS)

- **App de barra de menus.** `LSUIElement = true` no `Info.plist` (scripts dev e release), por isso sem ícone na
  Dock por predefinição. A definição "Mostrar ícone na Dock" muda a política de ativação para `.regular`
  (e volta a `.accessory` quando desligada).
- **Cenas SwiftUI:** `MenuBarExtra` (estilo `.menu`, menu nativo) + `Settings`. Deixa de haver `WindowGroup`:
  a janela Início/Opções (`ContentView.swift`) é removida.
- **Menu da barra de menus:**

  | Item | Notas |
  |---|---|
  | Estado (desativado) | ex.: "Pronto · Option + Space", "A ouvir…", última mensagem de erro |
  | Iniciar ditado / Parar ditado | alterna, como o botão atual |
  | Copiar última transcrição | desativado se não houver |
  | — | |
  | Definições… | `SettingsLink` (macOS 14+; no 13, ação `showSettingsWindow:`), ⌘, |
  | Sobre o Wishper Pro | painel "Sobre" padrão |
  | — | |
  | Sair do Wishper Pro | ⌘Q |

- **Ícone da barra de menus:** símbolo da marca como imagem template (ver "Marca"); durante o ditado passa para o
  SF Symbol `waveform` (com efeito `variableColor` no macOS 14+).
- **Primeiro arranque:** se faltar a API key, a permissão de microfone ou a de Acessibilidade, abre as Definições
  no separador Geral e traz a janela para a frente.
- **Clique no ícone da Dock** (quando visível): abre as Definições.
- Abrir as Definições a partir de uma app de barra de menus exige ativar a app (`NSApp.activate`) depois de abrir,
  senão a janela fica atrás das outras.

## Definições (janela nativa, ⌘,)

`TabView` com 4 separadores; cada um é um `Form` com `.formStyle(.grouped)`. Segue o modo claro/escuro do sistema
(deixa de forçar escuro). Controlos com a cor de destaque do sistema.

**Geral**
- Cabeçalho: símbolo da marca + "Wishper Pro" + versão.
- *Conta OpenAI:* campo seguro "API key", botões "Guardar" e "Remover", estado ("Guardada no Keychain" / "Sem
  key").
- *Permissões:* linhas Microfone e Acessibilidade com estado (concedida / em falta) e botão "Abrir Definições do
  Sistema" (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` e
  `?Privacy_Accessibility`). O microfone pede acesso diretamente enquanto o estado for "não determinado".
- *Arranque:* "Abrir ao iniciar sessão" (`SMAppService.mainApp`) e "Mostrar ícone na Dock".

**Ditado**
- *Atalho:* combinação atual + botão "Alterar…" (captura atual, sem mudanças) e "Comportamento" (Automático /
  Manter premido / Alternar) com nota explicativa.
- *Língua:* "Língua do ditado" (Auto, pt-PT, pt-BR, en, es, fr, de, it). É o `selectedSourceLanguage` atual, que
  sai do cartão de tradução: serve para a transcrição e como origem da tradução.
- *Texto:* "Colar automaticamente" e "Repor o clipboard depois de colar".

**Bolha**
- Pré-visualização da bolha (a própria vista, com dados de exemplo).
- "Estilo": Texto ao vivo / Compacta / Oculta.
- "Posição": Em baixo ao centro / Em cima ao centro / Canto inferior direito.

**Tradução**
- "Traduzir depois de transcrever" e "Traduzir para" (línguas de destino atuais).
- Nota: "A língua de origem é a língua do ditado."

### Definições novas (UserDefaults)

| Chave | Valores | Predefinição |
|---|---|---|
| `wishper.bubble_mode` | `liveText`, `compact`, `hidden` | `liveText` |
| `wishper.bubble_position` | `bottomCenter`, `topCenter`, `bottomRight` | `bottomCenter` |
| `wishper.hotkey_behavior` | `auto`, `hold`, `toggle` | `auto` |
| `wishper.auto_paste` | Bool | `true` (hoje não é guardado) |
| `wishper.restore_clipboard` | Bool | `true` |
| `wishper.show_in_dock` | Bool | `false` |

As chaves existentes (atalho, tradução, línguas) mantêm-se. "Abrir ao iniciar sessão" não usa UserDefaults: o
estado vem de `SMAppService.mainApp.status`.

## Marca

- A marca é monocromática (preto, branco e cinzentos em gradiente, símbolo em espiral — `logo.svg`).
- **Símbolo:** os scripts copiam `logo.svg` para `Contents/Resources/BrandMark.svg`. `BrandMark.swift` carrega-o
  com `NSImage` (suporta SVG) e cria uma imagem template: rasteriza o SVG (`cgImage(forProposedRect:)`), converte
  para tons de cinzento e usa a luminância como alfa (fundo preto → transparente, branco → opaco, cinzentos →
  semitransparentes). Uma constante de gama reforça os cinzentos em tamanhos pequenos. Validado num teste
  descartável no macOS 26 (18, 36 e 128 pt, fundos claro e escuro).
- Se o SVG não carregar (ex.: `swift run` sem bundle, ou macOS antigo), usa o SF Symbol `waveform`.
- Usado na barra de menus (18 pt), na bolha (16 pt) e no cabeçalho das Definições.
- **Cores:** paleta monocromática (`.primary`/`.secondary`); cores do sistema só com significado: vermelho para
  erro, verde para sucesso. Tipografia do sistema (SF Pro).

## Fluxo de um ditado

Máquina de estados `DictationPhase`: `idle → listening → finalizing → done(app) | failed(mensagem) → idle`.

1. **Início** (`idle → listening`)
   - verifica a API key e a permissão de microfone (como hoje);
   - guarda a app ativa (`NSWorkspace.shared.frontmostApplication`: nome e ícone);
   - arranca o microfone e, em paralelo, abre o WebSocket; o áudio fica em fila até chegar `session.updated`
     (máx. 5 s — senão a ligação é dada como falhada);
   - toca o som de início (como hoje) e regista o Esc.
2. **Durante** (`listening`)
   - pedaços de 100 ms vão para o WebSocket;
   - cada `delta` é acrescentado a `liveTranscript`;
   - o nível de cada pedaço atualiza `audioLevel`; `isSpeechDetected` passa a verdadeiro quando algum pedaço
     tem nível > 0,12 e fica assim até ao fim.
3. **Fim** (`listening → finalizing`)
   - para o microfone, toca o som de fim e retira o Esc;
   - **sem voz detetada:** fecha a ligação sem commit → `failed("Não ouvi nada.")`, sem custo;
   - **com voz:** envia o resto da fila e o commit, espera o `completed` (máx. 8 s) e fecha a ligação;
   - **ligação falhou** em qualquer momento (erro, fecho, timeouts): plano B com o WAV. Exceção: se o handshake
     devolveu HTTP 401, não tenta o plano B e mostra "A API key é inválida.";
   - tradução, se ativa (igual a hoje);
   - entrega do texto (ver "Colar") → `done(nome da app)`.
4. `done` fica visível 1,2 s e `failed` 2,5 s; depois volta a `idle`.
5. **Cancelar** (Esc durante `listening`): para o microfone, fecha a ligação, descarta o áudio, não cola, toca o
   som de fim → `idle`.

Notas:
- Um novo ditado durante `finalizing` é ignorado (como hoje).
- Se o dispositivo de áudio mudar a meio (`AVAudioEngineConfigurationChange`, ex.: AirPods ligam-se), trata-se
  como "Fim" com o áudio que já existe.
- O menu, a bolha e as Definições leem o mesmo estado do `VoicePasteViewModel`.

## Componentes

### `MicrophoneStream` (substitui `AudioRecorder`)
- `AVAudioEngine` com tap no `inputNode`, no formato do hardware.
- `AVAudioConverter` para PCM Int16, 24 000 Hz, 1 canal, intercalado; o conversor é reutilizado entre pedaços
  (mantém o estado da reamostragem).
- Nível: RMS do buffer de entrada → dBFS → normalizado entre -55 dB e 0 dB (mesma escala do `AudioRecorder`).
- Emite pedaços de ~100 ms, guarda todo o PCM em memória e exporta WAV (cabeçalho RIFF de 44 bytes).
- A conversão é uma função partilhada, usada também pelo autoteste para ficheiros.
- Deixa de haver ficheiros temporários de áudio.

### `OpenAIRealtimeTranscriber`
- `URLSessionWebSocketTask` (sem dependências externas).
- Faz: ligar e configurar a sessão, `append(Data)`, `commit() async throws -> String` (espera o `completed`),
  `close()`, callback de texto parcial e estado de falha (incluindo o código HTTP do handshake, quando existe).
- Guarda o áudio em fila até `session.updated`.
- Erros em pt-PT com `LocalizedError`, como os outros serviços.

### `DictationSession`
- Um objeto por ditado: junta `MicrophoneStream`, `OpenAIRealtimeTranscriber` e o plano B
  (`OpenAITranscriptionClient`).
- `start()`, `finish() async throws -> String`, `cancel()`, callbacks de texto ao vivo e nível.
- Não conhece a interface, a tradução nem o colar — isso fica no `VoicePasteViewModel`.

### `OpenAITranscriptionClient` (plano B)
- Passa a receber o WAV em memória (`Data`), usa `gpt-transcribe` e envia `languages[]`.
- Sai o código de métricas e de retries que já ninguém usa.

### Atalho — `GlobalHotkeyMonitor`
- Carbon: trata `kEventHotKeyPressed` e `kEventHotKeyReleased`. Atalhos só-modificador: `flagsChanged` ao premir e
  ao largar (hoje só trata o premir).
- Callbacks `onPress` e `onRelease` substituem `onTrigger`. Sai o debounce de 600 ms: a máquina de estados já
  ignora eventos fora de tempo.
- Esc: segundo `RegisterEventHotKey` (Esc sem modificadores, id 2), ativo só durante `listening`, para não tirar o
  Esc às outras apps.

Comportamento (`wishper.hotkey_behavior`), decidido por uma função pura (testada no autoteste):

| Comportamento | Evento | Estado | Ação |
|---|---|---|---|
| `toggle` | premir | `idle` | iniciar |
| `toggle` | premir | `listening` | terminar |
| `hold` | premir | `idle` | iniciar |
| `hold` | largar | `listening` | terminar |
| `auto` | premir | `idle` | iniciar (guarda a hora) |
| `auto` | premir | `listening` em mãos-livres | terminar |
| `auto` | largar | `listening`, premido < 0,4 s | passar a mãos-livres |
| `auto` | largar | `listening`, premido ≥ 0,4 s, sem mãos-livres | terminar |
| qualquer | outro caso | — | ignorar |

Com `auto`, quem usa o atalho como hoje (dois toques rápidos) mantém o mesmo comportamento. O item "Iniciar
ditado" do menu alterna sempre.

### Colar — `AutoPaster`
- `paste(text:restoreClipboard:) async`.
- Antes de escrever: copia todos os itens e tipos do clipboard.
- Escreve o texto; quando vai repor, marca-o também com `org.nspasteboard.TransientType` para os gestores de
  clipboard não o guardarem. Cmd+V como hoje.
- Passados 0,5 s, se o `changeCount` ainda for o nosso, repõe os itens copiados.

Entrega do texto:
- auto-paste ligado e com permissão → cola (repõe o clipboard se a opção estiver ligada) → "Colado · <app>";
- auto-paste desligado → copia para o clipboard, sem reposição → "Copiado";
- sem permissão de Acessibilidade → copia para o clipboard, sem reposição → "Copiado" + mensagem de estado a
  explicar a permissão.

### Bolha — `FloatingBubbleController` + `VoiceBubbleView`
- `NSPanel` `.nonactivatingPanel` com `ignoresMouseEvents`: nunca rouba o foco e deixa passar os cliques. Todos os
  espaços e ecrã inteiro, no ecrã onde está o rato (como hoje).
- Painel transparente de tamanho fixo (máx. 520×140 pt); a pílula alinha-se dentro dele conforme a posição, por
  isso a janela não precisa de ser redimensionada.
  - `bottomCenter`: 24 pt acima do fundo do `visibleFrame` (acima da Dock);
  - `topCenter`: 8 pt abaixo do topo do `visibleFrame` (abaixo da barra de menus e do notch);
  - `bottomRight`: como hoje.
- Visibilidade: em `listening` e `finalizing` (exceto no estilo Oculta) e em `done`/`failed`. No estilo Oculta
  só aparecem os erros.
- Aspeto:
  - forma de pílula; macOS 26: `.glassEffect(.regular, in: .rect(cornerRadius: 18))`; versões anteriores:
    `.regularMaterial`;
  - `listening`: símbolo da marca + 5 barras de onda (altura pelo nível) e, no estilo Texto ao vivo, ícone e
    nome da app à direita e as últimas 2 linhas do texto ao vivo (corte no início, `truncationMode(.head)`),
    largura máx. 440 pt; antes do primeiro texto é igual à compacta. A indicação de "a gravar" do próprio macOS
    (ponto laranja do microfone) dispensa o ponto vermelho;
  - `finalizing`: indicador de progresso + "A finalizar";
  - `done`: ✓ verde + "Colado · <app>" ou "Copiado";
  - `failed`: ✕ vermelho + mensagem curta.
- Acessibilidade:
  - elemento combinado com etiqueta ("Wishper Pro, a ouvir");
  - com VoiceOver ligado, anúncios (`NSAccessibility.announcementRequested`) para "A ouvir", "Colado · <app>" e
    erros;
  - "Reduzir movimento": sem animações de mola nem ondas animadas;
  - "Reduzir transparência": fundo opaco (`windowBackgroundColor`);
  - "Aumentar contraste": contorno de 1 pt.

## Erros (mensagens pt-PT)

| Situação | Resultado |
|---|---|
| Sem API key | "Guarda a API key antes de iniciar o ditado." (atual) + abre as Definições |
| Microfone negado | "Permissão de microfone negada." (atual) |
| Microfone não arranca | "Não foi possível iniciar o microfone." |
| Sem voz | "Não ouvi nada." (sem custo) |
| Ligação falha ou timeout | plano B; a bolha continua em "A finalizar" |
| Handshake 401 | "A API key é inválida." (sem plano B) |
| Plano B falha | mensagem da OpenAI ou do sistema (como hoje) |
| Sem internet | o plano B também falha e o áudio perde-se (limitação conhecida) |
| Tradução falha | entrega o texto original + aviso (atual) |
| Sem permissão de Acessibilidade | "Copiado" + aviso (ver "Colar") |

## Ficheiros

| Ficheiro | Alteração |
|---|---|
| `Services/MicrophoneStream.swift` | novo (substitui `Services/AudioRecorder.swift`, apagado) |
| `Services/OpenAIRealtimeTranscriber.swift` | novo |
| `DictationSession.swift` | novo |
| `BrandMark.swift` | novo |
| `SettingsView.swift` | novo (substitui `ContentView.swift`, apagado) |
| `SelfTest.swift` | novo — ponto de entrada (`@main`) e `--selftest` |
| `Services/OpenAITranscriptionClient.swift` | plano B com `gpt-transcribe` |
| `Services/GlobalHotkeyMonitor.swift` | premir/largar, Esc, sem debounce |
| `Services/AutoPaster.swift` | assíncrono, reposição do clipboard |
| `Services/FloatingBubbleController.swift` | posições, estilos, painel fixo |
| `VoiceBubbleView.swift` | reescrita |
| `VoicePasteViewModel.swift` | `DictationPhase`, texto ao vivo, app de destino, novas definições, usa `DictationSession` |
| `WishperProApp.swift` | `MenuBarExtra` + `Settings`, política de ativação, sem `@main` |
| `scripts/run-dev-app.sh` | `LSUIElement`, copia `BrandMark.svg`, opção `--selftest` |
| `scripts/install-local-release.sh` | `LSUIElement`, copia `BrandMark.svg` |
| `CLAUDE.md`, `README.md` | atualizados (ainda falam de TTS e da janela antiga) |

Sem alterações a `Package.swift` (mantém macOS 13+; o que é do macOS 14/26 fica atrás de `#available`).

## Verificação

1. `swift build` sem erros nem avisos novos.
2. `./scripts/run-dev-app.sh --selftest`:
   - gera um áudio com `say -v Joana` (pt-PT), cria o bundle sem abrir a app e corre
     `WishperPro --selftest <ficheiro>`;
   - verificações sem rede (`assert`): tabela do atalho, cabeçalho WAV, número de amostras da conversão;
   - envia o ficheiro pela ligação ao vivo (pedaços de 100 ms ao ritmo real) e mostra os `delta` com tempos, o
     texto final e o tempo entre o commit e o texto final;
   - envia o WAV pelo plano B e mostra o texto e o tempo;
   - sai com código diferente de 0 se algo falhar; usa a API key do Keychain (custo < $0,01).
3. Teste manual (`./scripts/run-dev-app.sh`):
   - ditar em Notas, Slack ou browser, e Terminal;
   - manter premido vs toque; Esc;
   - estilos e posições da bolha; modo claro e escuro; Reduzir movimento, transparência e contraste;
   - clipboard reposto; menu da barra de menus; Definições (⌘,); primeiro arranque sem key;
   - "Mostrar ícone na Dock" e "Abrir ao iniciar sessão";
   - Wi-Fi desligado a meio (mensagem clara).

## A confirmar na implementação

- A ligação GA funciona sem header `OpenAI-Beta`.
- O plano B aceita `languages[]` no multipart.
- `delay` `low` vs `minimal` (latência vs qualidade).
- `.glassEffect` compila com o SDK usado pelo `swift build`.
- Abrir as Definições a partir do menu traz a janela para a frente numa app sem ícone na Dock.
