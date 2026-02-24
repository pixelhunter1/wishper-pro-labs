import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = VoicePasteViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wishper Pro")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Ditado macOS com OpenAI e auto-paste global.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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

                    Text("No macOS, o atalho de colar é Command + V.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            GroupBox("Atalho Global") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(viewModel.hotkeyLabel, systemImage: "keyboard")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isRecording ? Color.red : Color.green)
                                .frame(width: 8, height: 8)
                            Text(viewModel.isRecording ? "A gravar" : "Pronto")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Toggle("Auto-paste após transcrição", isOn: $viewModel.autoPasteEnabled)

                    if !viewModel.isHotkeyReady {
                        Text("Atalho global indisponível. Usa o botão Iniciar Ditado.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

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
                }
                .padding(.top, 4)
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
                .controlSize(.regular)
            }

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(viewModel.isStatusError ? Color.red : Color.secondary)
                .textSelection(.enabled)

            GroupBox("Última transcrição") {
                ScrollView {
                    Text(viewModel.lastTranscript.isEmpty ? "Ainda sem conteúdo." : viewModel.lastTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}
