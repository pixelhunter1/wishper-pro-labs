# Wishper Pro (macOS)

App nativa em Swift para ditado com OpenAI, sem login, com auto-paste no campo ativo.

## O que faz

- Grava áudio do microfone.
- Envia para `POST /v1/audio/transcriptions` da OpenAI.
- Recebe texto transcrito e cola automaticamente onde o cursor de texto estiver ativo.
- Atalho global: `Option + Space` para iniciar/parar.
- API key guardada localmente no macOS Keychain.

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
