# Tradução da gravação — design (vídeo traduzido, parte 2 de 2)

Data: 2026-09-19
Branch: `worktree-gravacao` (worktree `.claude/worktrees/gravacao`), por cima da parte 1 (`08c391e`).

## Contexto

A parte 1 grava o ecrã e guarda a voz numa faixa mono própria e o som do Mac noutra, todas no mesmo relógio que o
vídeo (ver `2026-09-19-gravacao-de-ecra-design.md`). Esta parte acrescenta a tradução. Escolhe-se a língua antes de
gravar. Enquanto a pessoa fala, cada frase é transcrita, traduzida e lida por uma voz da GPT-Live. Quando a gravação
para, aparece um segundo vídeo com a voz traduzida e legendas, e cada frase começa no segundo em que foi dita.

Decidido com o utilizador em 2026-09-19:
- a voz é a da GPT-Live, com todas as vozes dela como opção;
- o resultado final tem voz e legendas;
- o fluxo desta spec foi aprovado ("sim, está bem, avança").

## O que as amostras mostraram

Os testes foram feitos com uma gravação real de 37 s em português, traduzida para inglês, em scripts descartáveis.

| Abordagem | Resultado |
|---|---|
| Frase a frase: `gpt-transcribe` → `gpt-5.6-luna` → `gpt-4o-mini-tts` | Texto certo e sincronização exata. Todas as frases couberam no seu tempo sem acelerar. A voz é boa, mas não é a mais natural. |
| `gpt-realtime-translate` numa só sessão | Segue o tom da pessoa, mas chega 2,6 s atrasada no início e 11 s numa frase de 15 s. Não aceita o Dicionário. Posta de parte. |
| `gpt-realtime-translate` com uma sessão por frase | Sem contexto inventa frases e deixa frases curtas em silêncio. Posta de parte. |
| Frase a frase, com a leitura feita pela GPT-Live (`gpt-live-1`) | Leu 6 textos em 6 palavra por palavra, sem mudar nada. O primeiro som chega 0,8 a 0,95 s depois do pedido. É a voz que o utilizador escolheu. |

As vozes novas da GPT-Live não funcionam no `gpt-4o-mini-tts`: a API responde 400 com "Invalid value".

## Objetivos

1. A voz traduzida é natural e a pessoa escolhe-a entre as vozes da GPT-Live.
2. Cada frase traduzida começa no instante em que a original começou. A única exceção é quando a frase anterior
   ainda não acabou (ver "Encaixe").
3. As legendas podem ficar no leitor (é a predefinição), na imagem, ou desligadas.
4. A gravação original nunca se perde. Uma falha de rede não estraga o original, e as frases que falharam voltam a ser
   tentadas no fim.
5. O vídeo traduzido fica pronto poucos segundos depois de parar, porque as frases são tratadas durante a gravação.

Critério para as escolhas de interface (igual às partes anteriores): a predefinição é a opção mais moderna e menos
intrusiva, e as alternativas ficam nas Definições.

## Fora de âmbito

- Traduzir gravações já feitas ("Traduzir gravação…").
- Voz clonada ou vozes personalizadas.
- Rever ou editar as frases e as legendas antes de exportar.
- Um ficheiro `.srt` à parte.
- Ouvir a tradução durante a gravação.
- Continuar uma tradução depois de sair da app. Sair durante a tradução cancela-a, e o original fica guardado.

## Modelos e custo

| Passo | Modelo ou API | Custo |
|---|---|---|
| Frases | local, pelo nível do som em relação ao ruído da sala | — |
| Transcrição | `gpt-transcribe` (`/v1/audio/transcriptions`, `languages[]`, `keywords[]` do Dicionário) | $0,0045/min |
| Tradução | `gpt-5.6-luna` (`/v1/chat/completions`, resposta JSON `{"text"}`) | cêntimos por hora |
| Voz | `gpt-live-1` (`wss://api.openai.com/v1/live/sessions`) | $0,05 por minuto de sessão, ao segundo |
| Vídeo | AVFoundation | — |

A sessão da GPT-Live fica aberta enquanto se grava, por isso o total dá cerca de $0,055 por minuto de gravação.

### GPT-Live, como foi usada no teste

1. Ligar com `Authorization: Bearer <key>` e enviar `session.start`, com:
   - `model: "gpt-live-1"`;
   - `instructions` de narrador: "read it aloud exactly as written, word for word… Then stay silent.";
   - `audio: {format: {type: "audio/pcm", rate: 24000}, output: {voice}}`.

   A seguir esperar por `session.started`.
2. A GPT-Live está sempre a ouvir, por isso recebe silêncio em blocos de 100 ms com `session.input_audio.append`.
3. Cada texto segue num `session.commentary.append` com `delegation_id: null` e `content: <texto>`.
4. Chegam de volta:
   - `session.output_audio.delta`, em PCM16 24 kHz. O áudio vem sempre, com silêncio incluído.
   - `session.output_transcript.delta`, com o texto dito.
5. No fim, `session.close`, e a sessão responde `session.closed`.
6. As vozes são `marin` (a predefinição) e mais 12 com sotaque próprio:

   | Voz | Nome na API | Sotaque |
   |---|---|---|
   | Quartz | `quartz` | inglês australiano, feminina |
   | Ripple | `ripple` | inglês australiano, masculina |
   | Vesper | `vesper` | inglês britânico, masculina |
   | Willow | `willow` | inglês irlandês, feminina |
   | Stone | `stone` | inglês irlandês, masculina |
   | Gleam | `gleam` | inglês norte-americano, feminina |
   | Meridian | `meridian` | inglês norte-americano, masculina |
   | Bossa | `bossa` | português do Brasil, feminina |
   | Tempo | `tempo` | português do Brasil, masculina |
   | Beacon | `beacon` | inglês filipino, masculina |
   | Delta | `delta` | inglês do sul dos EUA, feminina |
   | Cinder | `cinder` | inglês do sul dos EUA, masculina |

## O que o utilizador vê

### Menu da barra (macOS 15+)

No bloco da gravação, entre "Som do Mac" e "Mostrar gravações":

```
Traduzir para        ▸  ✓ Não traduzir
                          Português (Portugal)
                          Português (Brasil)
                          Inglês
                          Espanhol
                          Francês
                          Alemão
                          Italiano
```

- As línguas são as mesmas de `SupportedLanguage.targetLanguages`. A escolha fica guardada e vale para as gravações
  seguintes.
- O submenu fica desativado durante uma gravação, tal como Microfone e Som do Mac, e também com "Sem microfone",
  porque não há voz para traduzir.
- Durante a tradução, o item "Gravar ecrã…" diz "Cancelar tradução": para a tradução, mostra o original no Finder e
  volta ao início.
- A língua de origem é a língua do ditado (Definições › Ditado). Em Auto, a transcrição deteta a língua.

### Bolha

- A contagem e a gravação ficam como na parte 1. Se a tradução não puder arrancar, a linha de aviso por baixo do
  tempo diz porquê (ver "Erros").
- Depois de "A guardar…", com a tradução ligada, a bolha mostra "A preparar o vídeo traduzido…" com indicador. Com
  as legendas na imagem, mostra também a percentagem da exportação.
- No fim mostra "Vídeo traduzido guardado", com visto verde, e o Finder mostra o vídeo traduzido selecionado.
  - Fica 3 s.
  - Se faltarem frases, fica 4 s, com uma segunda linha: "1 frase ficou por traduzir." ou "N frases ficaram por
    traduzir."
- Numa falha mostra a mensagem a vermelho durante 4 s, e o original continua guardado.
- O VoiceOver anuncia "A preparar o vídeo traduzido" e "Vídeo traduzido guardado".

### Definições › Gravação (nova, macOS 15+)

Entra na barra lateral a seguir a "Bolha", com o símbolo `record.circle`.

- **Voz traduzida**
  - Um seletor com duas secções:
    - "GPT-Live": as 12 vozes novas, cada uma com o sotaque. Exemplo: "Meridian — inglês norte-americano, masculina".
    - "Outras vozes da OpenAI": as 10 que a GPT-Live também aceita (marin, cedar, alloy, ash, ballad, coral, echo,
      sage, shimmer, verse).

    A predefinição é Meridian, a que o utilizador ouviu e aprovou. A GPT-Live recusa fable, onyx e nova.
  - Um botão "Ouvir" que lê uma frase curta na língua escolhida no menu, ou em inglês se estiver em "Não traduzir".
    - A frase fica em cache em `~/Library/Caches/<bundle>/Vozes/<voz>-<língua>.wav`, por isso só a primeira
      vez gasta a API.
    - Sem API key, o botão fica desativado e aparece "Precisa da API key (Geral)".
  - Texto de rodapé: "Vozes da OpenAI (GPT-Live). A língua escolhe-se no menu, em Traduzir para."
- **Legendas**, com três opções:
  - "No leitor": podem ligar-se e desligar-se. É a predefinição.
  - "Na imagem": ficam sempre visíveis, mas o vídeo demora mais a ficar pronto.
  - "Sem legendas".
- Durante uma gravação ou tradução, o painel fica desativado.

### Ficheiro traduzido

`~/Movies/Wishper Pro/Gravação 2026-09-19 às 14.32.10 (Inglês).mp4`, ao lado do original `.mov`.

- **Vídeo:** copiado do original sem voltar a codificar. Com as legendas na imagem, é recodificado em H.264, com o
  mesmo tamanho, a 30 imagens por segundo (um ecrã parado tem poucas imagens, e cada legenda tem de aparecer e sair a
  tempo).
- **Áudio:** uma faixa AAC de 48 kHz em estéreo, com a voz traduzida ao centro misturada com o som do Mac, quando foi
  gravado. A voz original não entra, porque fica no `.mov`.
- **Legendas "No leitor":** uma faixa de legendas (`tx3g`) ativa.
- **Duração:** a mesma do original.

## Definições novas (UserDefaults)

| Chave | Tipo | Predefinição |
|---|---|---|
| `wishper.recording_translation` | String: `""` = não traduzir, senão `SupportedLanguage.rawValue` | `""` |
| `wishper.recording_voice` | String: o nome da voz na API | `"meridian"` |
| `wishper.recording_subtitles` | String: `"player"`, `"image"` ou `"off"` | `"player"` |

## Fluxo

1. **Arranque.** Quando a gravação começa com uma língua escolhida, microfone e API key, o `RecordingController` cria
   um `RecordingTranslator` com a língua de origem, a língua de destino, o Dicionário, a voz e a key.
2. **Contagem.** O som do microfone durante a contagem ensina ao detetor o ruído da sala. Nessa altura a pessoa
   costuma estar calada.
3. **Gravação.** Cada bloco de voz escrito no ficheiro vai para o detetor de frases com o seu tempo no ficheiro.
   Cada frase fechada entra na fila:
   1. transcrever;
   2. traduzir;
   3. ler com a GPT-Live.

   A transcrição e a tradução seguem a ordem das frases, uma de cada vez, e a leitura segue a mesma ordem, numa só
   sessão; ler uma frase acontece ao mesmo tempo que traduzir a seguinte.
4. **Parar.**
   1. O original fecha como na parte 1, com "A guardar…".
   2. O detetor fecha a última frase e a fase passa a `.translating`.
   3. A app espera pelas frases pendentes e volta a tentar as que falharam, uma vez.
   4. Monta a voz e as legendas, e exporta o vídeo.
   5. A fase passa a `.saved(url)` do vídeo traduzido.
5. **Cancelar na contagem.** Nada é guardado e o tradutor é descartado.
6. **Gravação interrompida a meio** (janela fechada, disco cheio). O original fica guardado como na parte 1, e a
   tradução continua com o que foi gravado.

## Frases (`PhraseDetector`)

- Recebe PCM16 a 24 kHz com o tempo do primeiro bloco em segundos desde o instante zero, e mede o nível em janelas
  de 20 ms (dBFS).
- **Ruído da sala:** o percentil 10 dos níveis dos últimos 10 s, começando com o som da contagem. Há fala quando o
  nível fica 12 dB acima do ruído. É um limiar relativo porque a voz do utilizador no Studio Display fica a −42 a
  −49 dBFS, com a sala a −62 a −75: um limiar fixo cairia em cima da fala.
- **Início e fim:** a frase começa na primeira janela com fala, com 100 ms de margem antes, e acaba depois de 600 ms
  sem fala, com 160 ms de margem depois.
- **Tamanho:** no mínimo 200 ms. No máximo 15 s: uma frase mais longa é cortada na janela de 100 ms mais baixa
  entre os 6 e os 15 s.
- **Saída:** cada frase tem o início e o fim, em segundos desde o instante zero, e o seu PCM16.
- **Afinação:** os 12 dB, os 600 ms e os 15 s são constantes com nome, para afinar.
- É puro e testa-se offline. No teste achou 6 frases na gravação real e 4 em 4 numa gravação sintética com pausas.

## Transcrição e tradução

- **Transcrição:**
  - `OpenAITranscriptionClient.transcribe(wav:apiKey:languages:keywords:prompt:)`, com a língua de origem (nenhuma
    em Auto) e o Dicionário como `keywords`.
  - Uma transcrição vazia (ruído ou tosse) salta a frase, sem erro.
- **Tradução:** o `OpenAITextProcessor` ganha um modo de narração:
  - traduz para "natural spoken <língua>", mais ou menos tão curto como o original, para caber no mesmo tempo;
  - recebe as 3 frases anteriores (original → tradução) só como contexto;
  - aplica a regra do Dicionário;
  - devolve texto vazio para hesitações ("hum", "ãã"). Aqui um texto vazio é válido e a frase fica sem voz. O limite
    de tamanho (`accepts`) continua a valer.
- **Repetições:** cada chamada tenta até 3 vezes, esperando 0,5 s e depois 1 s. Uma frase que falhe sai da fila e
  volta a ser tentada uma vez depois de parar. A última volta para na primeira frase que volta a falhar: as
  restantes contam como por traduzir.

## Voz (`GPTLiveReader`)

- É um actor com uma sessão por gravação, aberta quando a primeira frase está traduzida. Usa as instruções de
  narrador e a voz das Definições.
- Enquanto está aberta, envia 100 ms de silêncio a cada 100 ms.
- `read(_ text:) async throws -> Data` envia o texto e junta o áudio até a leitura acabar. Dá-se por acabada quando:
  - a transcrição da GPT-Live já tem todas as palavras do texto e passaram 300 ms sem som; ou
  - passaram 1,5 s sem som depois de haver som;
  - ou, no máximo, ao fim de 25 s (uma sessão que não diz nada nesse tempo é dada como perdida e a leitura seguinte
    volta a ligar).

  Devolve PCM16 a 24 kHz sem o silêncio do princípio e do fim.
- **Confirmação:** se a transcrição não tiver pelo menos 90% das palavras do texto, a leitura repete uma vez e fica a
  que tiver mais palavras certas.
- **Ligação perdida:** volta a ligar e segue na frase seguinte. A que estava a ser lida repete.
- O botão "Ouvir" das Definições usa o mesmo leitor, numa sessão curta.

## Encaixe (sincronização)

- Cada leitura fica no início da sua frase.
- O espaço de uma frase vai do seu início até ao início da seguinte, menos 80 ms. A última pode ir até ao fim do
  vídeo.
- Se a leitura for maior do que o espaço, é acelerada sem mudar o tom (`AVAudioUnitTimePitch`, renderizado offline),
  até 1,25×.
- Se mesmo assim não couber, a frase seguinte espera que esta acabe e começa atrasada pela diferença. O atraso
  desaparece na próxima pausa que chegue.
- A regra é uma função pura: recebe o início e a duração de cada frase e devolve o início e a velocidade de cada
  leitura. Testa-se offline.
- No teste, o inglês coube sempre sem acelerar.

## Legendas

- **Cues:** uma por frase, com o texto traduzido, do início ao fim da leitura (pelo menos 1 s).
- **Linhas:**
  - no máximo 42 caracteres por linha e 2 linhas por cue;
  - uma frase mais longa divide-se em várias cues entre palavras, e o tempo é repartido na proporção dos caracteres.
- **"No leitor":** uma faixa `tx3g`, escrita com `AVAssetWriter` num ficheiro temporário e juntada à exportação.
- **"Na imagem":** texto branco centrado em baixo, sobre uma caixa escura translúcida, com a letra do sistema.
  - A altura da letra é 4,5% da altura do vídeo.
  - Cada cue é uma imagem desenhada com `CGContext` (caixa e texto) numa `CALayer`, visível no seu tempo por uma
    animação de opacidade, e entra no vídeo com `AVVideoCompositionCoreAnimationTool`.
  - Não se usa `CATextLayer`: numa exportação desenha a caixa mas não o texto (confirmado no protótipo).

## Exportação (`TranslatedVideoExporter`)

1. **Áudio:** junta as leituras na posição e velocidade do "Encaixe", soma o som do Mac lido do original com
   `AVAssetReader` (com limite para não saturar), e escreve um `.m4a` temporário, AAC 48 kHz estéreo.
2. **Composição:** `AVMutableComposition` com o vídeo do original, esse áudio e, com "No leitor", a faixa de legendas.
3. **Exportação:**
   - "No leitor" e "Sem legendas": `AVAssetExportSession` com `AVAssetExportPresetPassthrough`, que leva segundos.
   - "Na imagem": o preset de qualidade máxima, com a composição de vídeo das legendas.
4. **Temporários:** ficam numa pasta temporária e são apagados no fim, com sucesso ou com falha.

## Componentes

### Novos

- **`Services/PhraseDetector.swift`:** `PhraseDetector` (struct pura) e `Phrase`.
  - `prime(_:)` recebe o som da contagem.
  - `append(_:at:) -> [Phrase]` e `finish() -> [Phrase]` devolvem as frases fechadas.
- **`Services/GPTLiveReader.swift`:**
  - `LiveVoice`, o catálogo de vozes (nome na API, nome, sotaque);
  - o actor `GPTLiveReader`, com `read(_:)` e `close()`;
  - `GPTLiveError`, um `LocalizedError` em pt-PT.
- **`Services/RecordingTranslator.swift`:** recebe os blocos de voz e trata cada frase (transcrever, traduzir, ler,
  com repetições).
  - `finish() async -> TranslationResult`, com as frases prontas e as que falharam.
  - `cancel()`.
- **`Services/TranslatedVideoExporter.swift`:**
  - `VoicePlacement.place(_:)`, a regra do encaixe (pura);
  - `SubtitleCues.make(_:)`, as linhas e os tempos (pura);
  - `export(original:result:subtitles:to:progress:) async throws -> URL`.

### Alterações

- **`Services/RecordingWriter.swift`:**
  - `appendVoice` devolve o tempo com que escreveu o bloco, ou `nil` se o descartou.
  - Acrescenta o teste pendente da parte 1: os ramos de acerto de tempo da voz, ou seja, recomeçar depois de uma
    falha e descartar quando o relógio do microfone se adianta.
- **`Services/ScreenRecorder.swift`:** `onVoice: (Data, TimeInterval) -> Void` dá o PCM16 24 kHz de cada bloco
  escrito e o seu tempo desde o instante zero. O `onMicrophone` continua a dar o nível e serve também para o som da
  contagem.
- **`Services/OpenAITextProcessor.swift`:** o modo de narração (contexto das frases anteriores, texto vazio válido).
- **`RecordingController.swift`:**
  - as três definições novas e a fase `.translating`;
  - cria e liga o tradutor e chama o exportador;
  - o `translationContext` (API key, Dicionário, língua de origem) vem de uma closure que o `AppDelegate` define,
    como o `excludedWindowIDs`.
- **`WishperProApp.swift`:** o submenu "Traduzir para" e a closure do contexto.
- **`SettingsView.swift`:** o painel "Gravação".
- **`Services/FloatingBubbleController.swift` e `VoiceBubbleView.swift`:** a fase `.translating` (texto, indicador,
  percentagem e VoiceOver).
- **`SelfTest.swift`:** as verificações abaixo.
- **`CLAUDE.md` e `README.md`:** a tradução da gravação.

## Erros (mensagens pt-PT)

| Situação | Resultado |
|---|---|
| Sem API key | Grava sem tradução, e a bolha mostra "Sem API key: a gravar sem tradução." |
| Sem microfone | "Traduzir para" desativado |
| A GPT-Live não liga no arranque | As frases continuam a ser transcritas e traduzidas, e a leitura tenta ligar outra vez à frase seguinte. |
| Algumas frases falham depois das repetições | O vídeo sai sem a voz dessas frases, mas com as legendas das que foram traduzidas: "Vídeo traduzido guardado. 1 frase ficou por traduzir." |
| Nenhuma frase traduzida (sem rede, key inválida) | "Tradução falhou: <motivo>. A gravação original ficou guardada." |
| Nenhuma fala detetada | "Não ouvi nenhuma frase para traduzir." Só o original fica. |
| Erro ao exportar | "Não foi possível criar o vídeo traduzido: <motivo>. A gravação original ficou guardada." |
| Cancelar tradução no menu | A tradução para; o original fica e aparece no Finder. |
| Sair durante a tradução | A tradução é cancelada, o original fica e não fica nenhum vídeo a meio. |

## Ficheiros

| Ficheiro | Alteração |
|---|---|
| `Services/PhraseDetector.swift` | novo |
| `Services/GPTLiveReader.swift` | novo |
| `Services/RecordingTranslator.swift` | novo |
| `Services/TranslatedVideoExporter.swift` | novo |
| `Services/RecordingWriter.swift` | `appendVoice` devolve o tempo |
| `Services/ScreenRecorder.swift` | `onVoice` |
| `Services/OpenAITextProcessor.swift` | modo de narração |
| `RecordingController.swift` | definições, fase `.translating`, tradutor, exportação |
| `WishperProApp.swift` | submenu e contexto |
| `SettingsView.swift` | painel "Gravação" |
| `Services/FloatingBubbleController.swift`, `VoiceBubbleView.swift` | fase `.translating` |
| `SelfTest.swift` | verificações novas |
| `CLAUDE.md`, `README.md` | tradução da gravação |

## Verificação

1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (Xcode 27, Swift 6.4) sem erros nem avisos.
2. `--selftest` offline:
   - **Frases:** blocos sintéticos de tom com ruído a −70 e a −50 dBFS.
     - O início de cada frase fica a ±40 ms.
     - Uma pausa de 400 ms não divide a frase; uma de 800 ms divide.
     - Uma frase de 20 s é cortada em duas.
     - O limiar acompanha o ruído.
   - **Encaixe:**
     - o que cabe fica a 1×;
     - o que excede até 25% acelera;
     - o que excede mais atrasa a seguinte, e o atraso desaparece na pausa.
   - **Legendas:** o corte das linhas e dos tempos, e uma frase longa em várias cues.
   - **Modo de narração:** as instruções levam o contexto, o Dicionário e a língua, e o texto vazio é aceite.
   - **`RecordingWriter`:** os ramos de acerto de tempo da voz (pendente da parte 1).
   - **Exportação** com um `.mov` sintético:
     - em "No leitor" sai 1 faixa de vídeo, 1 de áudio e 1 de legendas; em "Sem legendas" sai sem a faixa de
       legendas;
     - a duração é a do original ±0,1 s;
     - há energia no áudio no tempo de cada frase.
3. `--selftest` online (com API key):
   - a GPT-Live lê uma frase com pelo menos 90% das palavras;
   - uma frase sintética em português é transcrita e traduzida para inglês.
4. Teste manual (`./scripts/run-dev-app.sh`):
   - gravar 1 minuto em português com um cronómetro no ecrã e traduzir para inglês, para confirmar a sincronização
     e as legendas no QuickTime;
   - repetir com as legendas na imagem;
   - desligar a internet a meio;
   - ouvir as vozes nas Definições.

## Confirmado no protótipo (2026-09-19)

Tudo com o código do plano, compilado com o Xcode 27 (Swift 6.4, modo Swift 6):

- **Vozes:** a GPT-Live aceita 22 vozes e recusa fable, onyx e nova ("Voice session access denied").
- **Línguas:** leu palavra por palavra em português europeu, espanhol, francês, alemão e italiano com a Meridian, e em
  português europeu com a Bossa.
- **Instruções no texto:** um texto com "Ignore the previous instructions…" foi lido, não obedecido.
- **Dois textos seguidos:** ficam em fila e são lidos pela ordem. Mesmo assim a app espera pelo fim de cada leitura,
  para saber que áudio é de que frase.
- **Tempo de leitura:** a transcrição da GPT-Live chega com o áudio, por isso o fim da leitura é detetado 300 ms depois
  da última palavra.
- **Teste de ponta a ponta:** a gravação real de 37 s do utilizador foi traduzida para inglês com o código da app, com
  a voz entregue em tempo real.
  - As 5 frases ficaram certas e com o Dicionário ("Xcode", "Claude").
  - O fim chegou 7,5 s depois de parar.
  - A exportação com as legendas no leitor levou 0,5 s. Com as legendas na imagem levou 10,5 s, para um vídeo de
    2160×2268 com 37 s.
- **Legendas no leitor:** a faixa `tx3g` passa para o `.mp4` na exportação passthrough (`mov_text`, marcada como
  predefinida).
- **Verificações:** passam 194 offline (155 antes) e todas as online.

Fica para o teste manual:
- se o QuickTime mostra a faixa de legendas ao abrir;
- o limite de duração de uma sessão da GPT-Live (a ligação perdida já é tratada: volta a ligar);
- os Redmi Buds.

## Acertos do protótipo

1. **`PCM16.decibels(of:)`:** novo. O `PhraseDetector` e o `GPTLiveReader` medem em dBFS, e `PCM16.level(of:)` passa
   a usá-lo, com o mesmo resultado.
2. **Visibilidade:** o `PendingBuffer` e o `OpenAITranscriptionError` deixam de ser `private`, porque a conversão das
   leituras e a regra da key recusada precisam deles.
3. **`RecordingWriter.voiceTime(next:block:)`:** a regra de tempo da voz passa a função pura, para ser testada.
   `appendVoice` devolve o tempo escrito, em segundos desde o instante zero.
4. **`OpenAITextProcessor.accepts(_:for:)`:** a regra que aceita o texto vazio na narração.
5. **`RecordingFile.translatedURL(for:language:)`:** o nome do vídeo traduzido.
6. **`RecordingPhase`:** ganha `.translating(Double?)` e `.translated(URL, missing: Int)`.
7. **`ScreenRecordingError`:** ganha `translationFailed`, `nothingToTranslate` e `exportFailed`.
8. **`TranslationContext`:** a API key, o Dicionário e a língua de origem. Vem de
   `VoicePasteViewModel.recordingTranslationContext`.
9. **`Data`:** `removeFirst(n)` desloca os índices, e depois `subdata(in: 0..<n)` rebenta. O detetor usa
   `removeSubrange(0..<n)`.
10. **Fala sintética dos testes:** a "fala" leva pausas de sílaba (210 ms de tom, 40 ms de pausa). Um tom contínuo de
    mais de 10 s passa a contar como ruído da sala, e isso está certo, porque uma voz real tem sempre pausas.
