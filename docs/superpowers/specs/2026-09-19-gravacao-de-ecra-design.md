# Gravação de ecrã — design (vídeo traduzido, parte 1 de 2)

Data: 2026-09-19
Branch: `worktree-gravacao` (worktree `.claude/worktrees/gravacao`)

## Contexto

O Wishper Pro dita e cola texto (partes 1 e 2 na `main`, v1.0.0). O utilizador quer uma funcionalidade nova: gravar
o ecrã a falar na sua língua e ter a IA a traduzir, com a voz traduzida alinhada com o vídeo. Ficou dividida em
duas partes, cada uma com spec, plano e aprovação próprios:

1. **Gravação** (esta spec): escolher o que gravar e o microfone, e gravar para um ficheiro.
2. **Tradução**: voz traduzida e legendas, com cada frase no instante em que foi dita. Terá spec própria, depois de
   o utilizador ouvir amostras das duas vozes possíveis.

Esta parte já grava o que a parte 2 precisa: a voz numa faixa própria, todas as faixas no mesmo relógio, e o áudio
do microfone convertido para o formato da transcrição ao vivo.

## Objetivos

1. Gravar o ecrã inteiro, uma janela ou uma app, escolhidos no seletor do sistema, sem a permissão de Gravação de
   Ecrã.
2. Escolher o microfone; gravar o som do Mac quando se quer.
3. A bolha e os menus da app nunca aparecem no vídeo.
4. Nunca perder uma gravação: se algo falhar a meio, ou a app fechar, o ficheiro fica com o que já foi gravado.
5. Voz e som do Mac em faixas separadas, no mesmo relógio que o vídeo.

Critério para as escolhas de interface (igual às partes anteriores): a predefinição é a opção mais moderna e menos
intrusiva.

## Fora de âmbito

- Tradução, voz traduzida e legendas (parte 2).
- Câmara, vários ecrãs ao mesmo tempo, pausa, cortar ou editar.
- Atalho global para gravar, escolher a pasta, escolher codec, fps ou qualidade.
- Misturar a voz e o som do Mac numa só faixa (a exportação da parte 2 faz a mistura).
- macOS 13 e 14: a gravação não aparece, porque precisa do microfone do ScreenCaptureKit (macOS 15).

## Plataforma e API

| API | macOS | Para quê |
|---|---|---|
| `SCContentSharingPicker` | 14 | seletor do sistema (ecrã, janela, app) |
| `SCStreamConfiguration.captureMicrophone`, `microphoneCaptureDeviceID`, saída `.microphone` | 15 | microfone no mesmo stream que o ecrã |
| `capturesAudio`, `excludesCurrentProcessAudio` | 13 | som do Mac, sem os sons da própria app |
| `AVAssetWriter` (`.mov`, `movieFragmentInterval`) | — | escrita do ficheiro |

Os tipos que usam o ScreenCaptureKit são `@available(macOS 15, *)`; o menu só mostra a gravação nesse caso.

Confirmado num protótipo descartável (2026-09-19, macOS 26.6.2, Studio Display):

- **Permissão.** O seletor funciona sem a permissão de Gravação de Ecrã: `CGPreflightScreenCaptureAccess()` ficou
  `false` antes e depois de gravar um ecrã e uma janela.
- **Bolha fora do vídeo.** Com `excludedBundleIDs` e `excludedWindowIDs` na configuração do seletor, a bolha sai da
  captura do ecrã inteiro (píxeis vermelhos da bolha de teste: 23 052 → 767).
- **O que não serve para a bolha.** O macOS 26 ignora `NSWindow.sharingType = .none`. Um filtro construído pela app
  (`SCContentFilter(display:excludingApplications:…)`) falha sem a permissão (erro -3801).
- **Formatos de áudio.**
  - Som do sistema: 48 kHz, 2 canais, float 32 bits não intercalado.
  - Microfone do Studio Display: 48 kHz, 1 canal, inteiro 24 bits. A lógica do `PCMConverter` converte-o para
    PCM16 24 kHz sem falhas.
- **Relógio.** Ecrã, som e microfone usam o relógio do sistema (host time). O microfone começa cerca de 0,7–0,8 s
  depois do primeiro fotograma.
- **Voz do utilizador no Studio Display.** Fica a -42 a -49 dBFS, com o ruído da sala a -62 a -75 dBFS. Isto conta
  para a parte 2: a deteção de pausas tem de ser relativa ao ruído da sala.

## O que o utilizador vê

### Menu da barra (macOS 15+)

Bloco novo entre "Copiar última transcrição" e "Definições…":

```
Gravar ecrã…
Microfone            ▸  ✓ Predefinido do sistema
                          Microfone do Studio Display
                          Microfone de iPhone
                          Sem microfone
Som do Mac              (com visto quando ligado)
Mostrar gravações
```

- **Gravar ecrã…** abre o seletor do sistema com os três modos (ecrã, janela, app). A app exclui-se do seletor
  pelo bundle ID e pela janela da bolha.
- **O item muda com a fase.** Com o seletor aberto fica desativado; durante a contagem diz "Cancelar gravação"; a
  gravar diz "Parar gravação"; a guardar diz "A guardar…" e fica desativado.
- **Microfone e Som do Mac** ficam desativados durante uma gravação e valem para a seguinte.
- **A lista de microfones** mostra os dispositivos ligados e atualiza-se quando se liga ou desliga um. Se o microfone
  guardado não estiver ligado, grava com o predefinido do sistema, e o menu mostra "Predefinido do sistema" como
  escolhido.
- **Mostrar gravações** abre `Filmes/Wishper Pro` no Finder e cria a pasta se ainda não existir.

### Bolha

Segue o modo escolhido em Bolha (Texto ao vivo e Compacta mostram, Oculta não) e a posição escolhida:

- **Contagem:** "A gravar em 3", "2", "1", com as barras de nível, que servem de teste ao microfone.
- **A gravar:** ponto vermelho, o tempo (01:23) e as barras de nível.
- **A guardar:** "A guardar…" com indicador.
- **Guardada:** "Gravação guardada" com visto verde, durante 2 s.
- **Falha:** a mensagem a vermelho, durante 4 s.

Se começar um ditado durante uma gravação, a bolha mostra o ditado e volta à gravação quando o ditado acaba.

A bolha continua a deixar passar os cliques e não recebe foco. O VoiceOver anuncia "A gravar", "Gravação
guardada" e as falhas, como já anuncia o ditado.

### Barra de menus

Durante a contagem e a gravação, o ícone passa a `record.circle` com o tempo ao lado, monocromático como o resto
da marca.

### Sons

- **Início (Pop):** toca quando a contagem começa, antes do instante zero, por isso não fica no ficheiro.
- **Fim (Tink):** toca quando a gravação para.
- O som do Mac exclui sempre os sons da própria app (`excludesCurrentProcessAudio`).

### Ficheiro

`~/Movies/Wishper Pro/Gravação 2026-09-19 às 14.32.10.mov`, com a hora local. Se o nome já existir, acrescenta
" 2", " 3", e assim por diante. Ao guardar, o Finder mostra o ficheiro selecionado.

A pasta é Filmes e não a Secretária porque a Secretária está protegida por uma permissão do macOS que se perde a
cada reinstalação ad-hoc. Filmes não tem essa proteção.

## Definições novas (UserDefaults)

| Chave | Tipo | Predefinição |
|---|---|---|
| `wishper.recording_microphone` | String: `""` = predefinido do sistema, `"none"` = sem microfone, senão o `uniqueID` do `AVCaptureDevice` | `""` |
| `wishper.recording_system_audio` | Bool | `false` |

## Fluxo de uma gravação

1. **Escolher.** "Gravar ecrã…" abre o seletor e a fase passa a `.choosing`. Se o utilizador cancelar, volta a
   `.idle`.
2. **Preparar.** Depois da escolha, a app cria a pasta, escolhe o nome do ficheiro e chama
   `ScreenRecorder.start(filter:options:)`. O stream (ecrã, microfone, som do Mac) arranca logo, mas ainda nada é
   escrito.
3. **Contar.** Contagem de 3 s (`.countdown(3)` até `.countdown(1)`) com o som de início. Entretanto o microfone
   aquece e a bolha mostra o nível.
4. **Começar.** No fim da contagem, `beginWriting()` fixa o instante zero no momento atual (host time). O último
   fotograma recebido entra com esse tempo, e a fase passa a `.recording(since:)`.
5. **Parar.** "Parar gravação" passa a fase a `.saving` e chama `stop()`. O `stop()`:
   - para o stream;
   - repete o último fotograma no instante final;
   - fecha o ficheiro.

   Depois toca o som de fim, a fase passa a `.saved(url)`, o Finder mostra o ficheiro e, 2 s depois, a fase volta
   a `.idle`.
6. **Falha a meio.** Se o stream parar com erro (janela fechada, ecrã desligado, disco cheio), acontece o mesmo que
   no passo 5, com a mensagem de falha.

Cancelar durante a contagem para o stream, apaga o ficheiro vazio e volta a `.idle`.

## Formato do ficheiro

**Contentor.** QuickTime (`.mov`) com `movieFragmentInterval` de 10 s. Se a app fechar ou o Mac desligar a meio, o
ficheiro abre até ao último fragmento.

**Vídeo.**
- H.264, no máximo 30 fps (`minimumFrameInterval` 1/30), com o cursor visível.
- Tamanho: o do conteúdo em píxeis (`contentRect` × `pointPixelScale`). Se for maior, é reduzido na mesma proporção
  até o lado maior ter no máximo 3840 e o menor no máximo 2160, com as duas medidas arredondadas para baixo a
  números pares.
- Exemplos: Studio Display (2560×1440 pontos, 5K) → 3840×2160; MacBook Air 13" (1470×956 pontos) → 2940×1912.

**Faixas de áudio.** Por esta ordem, cada uma só quando existe:

1. voz: AAC, 48 kHz, mono, 128 kbit/s;
2. som do Mac: AAC, 48 kHz, estéreo, 192 kbit/s.

A voz é a única faixa mono, e é assim que a parte 2 a encontra. O QuickTime toca as duas juntas.

**Tempos.**
- Todas as amostras usam o relógio do sistema, e o ficheiro começa no instante zero (o fim da contagem).
- As amostras de áudio anteriores ao instante zero são descartadas.
- O último fotograma anterior ao instante zero é reposto nesse instante, porque o ScreenCaptureKit só manda
  fotogramas quando o ecrã muda.
- No fim, o último fotograma é repetido no instante final, para o vídeo durar o mesmo que o áudio.
- Só entram os fotogramas completos (`SCFrameStatus.complete`).

**Voz.**
- Cada bloco do microfone passa a `AVAudioPCMBuffer` e depois por um conversor para 48 kHz mono float.
- O conversor é refeito quando o formato muda. É o que acontece com os auriculares Bluetooth, que mudam de perfil ao
  ligar o microfone.
- O tempo de cada bloco convertido conta as amostras escritas desde o primeiro bloco, para não haver sobreposições
  nem buracos.
- Se esse tempo se afastar mais de 50 ms do tempo do bloco (o microfone falhou um bocado), recomeça a contar a partir
  do tempo do bloco.

**Som do Mac.** Os blocos do ScreenCaptureKit entram tal como chegam. O formato é fixo, porque a configuração pede
48 kHz estéreo.

## Componentes

### `Services/ScreenRecorder.swift` (novo)

- **`RecordingSize.output(points:scale:) -> CGSize`:** a regra do tamanho. É pura e testável.
- **`RecordingFile`:** a pasta (`~/Movies/Wishper Pro`) e o nome (`url(for: Date, in: URL)`, com sufixo quando o
  ficheiro já existe).
- **`RecordingWriter`:** o `AVAssetWriter` e as suas entradas. Usa só AVFoundation, sem ScreenCaptureKit, e o
  autoteste usa-o com dados sintéticos.
  - Métodos: `begin(at:)`, `appendVideo(_:)`, `appendVoice(_:at:)`, `appendSystemAudio(_:)` e
    `finish(at:) async throws`.
  - `appendVoice` recebe um `AVAudioPCMBuffer` em qualquer formato e faz a conversão para 48 kHz mono descrita em
    "Voz", incluindo refazer o conversor quando o formato muda.
  - Guarda os tempos da voz e o último fotograma.
  - É sempre chamado na mesma fila.
- **`ScreenRecorder`** (`@available(macOS 15, *)`): o `SCStream` e o seu `SCStreamOutput`/`SCStreamDelegate`.
  - Usa uma fila série para o ecrã, o som e o microfone. Assim a ordem mantém-se e o `RecordingWriter` só é usado
    nessa fila.
  - Métodos: `start(filter:options:) async throws`, `beginWriting()`, `stop() async throws -> URL`.
  - Callbacks:
    - `onMicrophone: (Data, Double) -> Void` recebe PCM16 24 kHz e o nível, via `PCMConverter` e `PCM16.level`.
      Agora serve para o nível da bolha; na parte 2 é o mesmo caminho da tradução ao vivo.
    - `onFailure: (Error) -> Void` avisa quando o stream para com erro.
  - É `@unchecked Sendable`, com o estado preso à fila série (como o `MicrophoneStream`, que usa um lock).
- **`ScreenRecordingError`:** enum `LocalizedError` com as mensagens da tabela de erros.

### `RecordingController.swift` (novo, `@MainActor`, `ObservableObject`)

- **Fases (`RecordingPhase`):** `.idle`, `.choosing`, `.countdown(Int)`, `.recording(since: Date)`, `.saving`,
  `.saved(URL)` e `.failed(String)`.
- **Estado publicado:**
  - `phase`, `level` e `elapsed`;
  - `microphoneID` e `recordsSystemAudio`, guardados em UserDefaults;
  - `microphones`, a lista de dispositivos, atualizada com `AVCaptureDevice.wasConnected` e `wasDisconnected`.
- **Seletor.** Observa o `SCContentSharingPicker`, configurado com os três modos e com o bundle ID da app e a janela
  da bolha excluídos.
- **O resto do ciclo:** a contagem, os sons, o Finder, o temporizador do tempo decorrido e a permissão do microfone.
  Pede a permissão se ainda não foi decidida; se foi recusada, grava sem voz e avisa.
- Fica fora do `VoicePasteViewModel` (770 linhas), que continua a ser a fonte de verdade do ditado.

### Alterações

- **`WishperProApp.swift`:**
  - o `AppDelegate` cria o `RecordingController` (macOS 15+);
  - o `MenuBarContent` ganha o bloco de gravação;
  - o `MenuBarLabel` mostra `record.circle` e o tempo.
- **`Services/FloatingBubbleController.swift`:**
  - observa também a gravação;
  - mostra a gravação quando o ditado está em repouso;
  - anuncia as fases da gravação ao VoiceOver;
  - dá o número da janela da bolha para o seletor a excluir.
- **`VoiceBubbleView.swift`:** `RecordingBubbleView` (contagem, a gravar, a guardar, guardada, falhou), com o mesmo
  fundo e as mesmas barras da bolha do ditado.
- **`SelfTest.swift`:** verificações novas. As offline passam a correr numa `Task`, porque a do ficheiro é
  assíncrona.
- **`CLAUDE.md` e `README.md`:** a gravação de ecrã.

## O que fica pronto para a parte 2

- A voz numa faixa mono própria, com os tempos do vídeo.
- O instante zero é o mesmo para tudo, por isso o segundo X da voz é o segundo X do vídeo.
- `ScreenRecorder.onMicrophone` já converte o microfone para PCM16 24 kHz, o formato do `gpt-live-transcribe` e do
  `gpt-realtime-translate`.

## Erros (mensagens pt-PT)

| Situação | Resultado |
|---|---|
| Seletor cancelado | nada acontece |
| Sem acesso ao microfone | grava sem voz; bolha: "Sem acesso ao microfone: a gravar sem voz." |
| Microfone escolhido desligado | grava com o predefinido do sistema, sem aviso |
| O stream não arranca | "Não foi possível começar a gravar: <motivo>" |
| Pasta impossível de criar | "Não foi possível criar a pasta Filmes/Wishper Pro." |
| Janela ou app fechada, ecrã desligado, stream parado com erro | fecha o ficheiro com o que foi gravado; "Gravação interrompida: <motivo>. O que foi gravado ficou guardado." e mostra-o no Finder |
| Erro ao escrever (ex.: disco cheio) | igual à linha anterior |
| Cancelar durante a contagem | nada é guardado |

## Ficheiros

| Ficheiro | Alteração |
|---|---|
| `Services/ScreenRecorder.swift` | novo (`RecordingSize`, `RecordingFile`, `RecordingWriter`, `ScreenRecorder`, `ScreenRecordingError`) |
| `RecordingController.swift` | novo |
| `WishperProApp.swift` | bloco de gravação no menu; ícone com o tempo; o `AppDelegate` cria o controlador |
| `Services/FloatingBubbleController.swift` | mostra também a gravação; número da janela da bolha |
| `VoiceBubbleView.swift` | `RecordingBubbleView` |
| `SelfTest.swift` | verificações novas; offline numa `Task` |
| `CLAUDE.md`, `README.md` | gravação de ecrã |

Sem alterações a `Package.swift` nem aos scripts. O `Info.plist` já tem `NSMicrophoneUsageDescription`, e o
seletor não precisa de chave nenhuma.

## Verificação

1. `swift build` sem erros nem avisos novos.
2. `.build/debug/WishperPro --selftest` (sem rede):
   - **tamanho:**
     - 2560×1440 pontos a 2× → 3840×2160;
     - 1470×956 a 2× → 2940×1912;
     - janela de 1281×1346 a 2× → lado maior ≤ 3840, menor ≤ 2160, medidas pares e proporção com menos de 1% de
       diferença;
     - 1001×601 a 1× → 1000×600;
   - **nome:** uma data fixa dá "Gravação 2026-09-19 às 14.32.10.mov"; se esse ficheiro já existir, dá "… 2.mov";
   - **`RecordingWriter` com dados sintéticos**, uma gravação de 2 s com:
     - fotogramas de 320×180 só no início e a meio (ecrã parado);
     - voz a 48 kHz que passa a 16 kHz a meio;
     - som do Mac em estéreo;
     - amostras anteriores ao instante zero.

     Resultado esperado: o ficheiro tem 1 faixa de vídeo e 2 de áudio (voz mono, som estéreo), o vídeo e o áudio
     duram 2,0 s ± 0,1 e a voz começa no zero;
   - **sem microfone:** só vídeo e som do Mac; **sem som do Mac:** só vídeo e voz.
3. Teste manual (`./scripts/run-dev-app.sh`, macOS 26). A app dev não tem a permissão de Gravação de Ecrã.
   - **Ecrã inteiro:** 15 s a falar → o ficheiro aparece em Filmes/Wishper Pro e abre no QuickTime com voz. A bolha
     e o menu da app não aparecem no vídeo.
   - **Janela e app:** gravar cada uma.
   - **Som do Mac** ligado, com um vídeo a tocar: ouve-se no ficheiro, mas os sons da app não.
   - **Microfones:** Studio Display, iPhone e "Sem microfone" (este sem faixa de voz).
   - **Redmi Buds:** a voz é contínua quando os auriculares mudam de perfil.
   - **Janela fechada a meio:** aparece a mensagem de interrupção e o ficheiro abre até esse ponto.
   - **`kill -9` à app dev a meio:** o ficheiro abre até ao último fragmento (perde no máximo 10 s).
   - **Cancelar na contagem:** nada é guardado.
   - **Aparência e acessibilidade:** modo claro e escuro; o VoiceOver anuncia "A gravar" e "Gravação guardada".

## A confirmar na implementação

- Os blocos do som do Mac entram diretamente na entrada AAC (vêm em formato não intercalado).
- O `movieFragmentInterval` deixa o ficheiro legível depois de um `kill -9`.
- O menu aberto da app (janelas do `NSMenu`) e o ícone da barra de menus ficam fora da captura com
  `excludedBundleIDs`.
- O `MenuBarExtra` atualiza o tempo no ícone a cada segundo.
- Os Redmi Buds pelo microfone do ScreenCaptureKit, com a mudança para o perfil de chamada a meio (não estavam
  ligados no protótipo).
