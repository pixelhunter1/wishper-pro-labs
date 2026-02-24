# Wishper Pro (macOS)

App nativa em Swift para ditado com OpenAI, sem login, com auto-paste no campo ativo.

## O que faz

- Interface em duas páginas: `Início` (ditado + transcrição) e `Opções`.
- Grava áudio do microfone.
- Envia para `POST /v1/audio/transcriptions` da OpenAI.
- Recebe texto transcrito e cola automaticamente onde o cursor de texto estiver ativo.
- Atalho global: `Option + Space` para iniciar/parar.
- Bubble dinâmico `150x50` com estado de voz (`A ouvir`, `A falar`, `A transcrever`).
- Bubble flutuante no desktop durante gravação/transcrição, mesmo com janela principal minimizada.
- Bip no início e no fim da gravação.
- API key guardada localmente no macOS Keychain.
- Não há base de dados de transcrições; a transcrição anterior é limpa ao iniciar nova fala.

## Requisitos

- macOS
- Xcode Command Line Tools (Swift 6+)
- API key da OpenAI

## Instalação

```bash
swift build
swift run WishperPro
```

## Primeira configuração

1. Inserir API key e clicar `Guardar Key`.
2. Conceder acesso ao microfone quando o macOS pedir.
3. Clicar `Ativar Accessibilidade` e ativar a app/terminal em:
   `Definições do Sistema > Privacidade e Segurança > Acessibilidade`.

## Uso

1. Colocar cursor num campo de texto em qualquer app.
2. Pressionar `Option + Space` para começar a gravar.
3. Pressionar `Option + Space` novamente para terminar.
4. A transcrição será colada automaticamente no campo ativo.
