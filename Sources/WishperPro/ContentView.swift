import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        TabView {
            HomePage(viewModel: viewModel)
                .tabItem {
                    Label("Início", systemImage: "waveform.and.mic")
                }

            OptionsPage(viewModel: viewModel)
                .tabItem {
                    Label("Opções", systemImage: "slider.horizontal.3")
                }
        }
        .padding(20)
    }
}

private struct HomePage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wishper Pro")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Transcrição em tempo real com auto-paste.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                VoiceBubbleView(
                    title: viewModel.bubbleStateTitle,
                    subtitle: viewModel.bubbleStateSubtitle,
                    isRecording: viewModel.isRecording,
                    isTranscribing: viewModel.isTranscribing,
                    audioLevel: viewModel.audioLevel
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Atalho ativo: \(viewModel.hotkeyLabel)")
                        .font(.caption.weight(.semibold))
                    Text(
                        viewModel.isHotkeyReady
                            ? "Usa o atalho para iniciar/parar."
                            : "Atalho indisponível. Usa o botão abaixo."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                viewModel.toggleRecordingFromButton()
            } label: {
                HStack {
                    Spacer()
                    Label(
                        viewModel.isRecording ? "Parar Ditado" : "Iniciar Ditado",
                        systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill"
                    )
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isActionDisabled)

            if viewModel.isTranscribing {
                Button("Cancelar Transcrição") {
                    viewModel.cancelTranscription()
                }
                .buttonStyle(.bordered)
            }

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(viewModel.isStatusError ? Color.red : Color.secondary)
                .textSelection(.enabled)

            GroupBox("Última transcrição") {
                ScrollView {
                    Text(viewModel.lastTranscript.isEmpty ? "Ainda sem conteúdo." : viewModel.lastTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 260)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct OptionsPage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("API OpenAI") {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("sk-...", text: $viewModel.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            Button("Colar") {
                                viewModel.pasteAPIKeyFromClipboard()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Guardar Key") {
                                viewModel.saveAPIKey()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Remover") {
                                viewModel.clearAPIKey()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text(viewModel.keyStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                GroupBox("Comportamento") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto-paste após transcrição", isOn: $viewModel.autoPasteEnabled)

                        HStack {
                            Text("Atalho global")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.hotkeyLabel)
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Permissões") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(viewModel.accessibilityStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Ativar Accessibilidade") {
                                viewModel.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Concede microfone quando o macOS pedir no primeiro uso.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.bottom, 8)
        }
    }
}
