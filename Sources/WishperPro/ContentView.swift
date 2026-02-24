import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case home
    case options

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Início"
        case .options: return "Opções"
        }
    }

    var icon: String {
        switch self {
        case .home: return "waveform.and.mic"
        case .options: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @State private var selectedSection: AppSection = .home

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sectionSwitcher

            Group {
                switch selectedSection {
                case .home:
                    HomePage(viewModel: viewModel)
                case .options:
                    OptionsPage(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.09, blue: 0.12),
                    Color(red: 0.05, green: 0.05, blue: 0.07),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wishper Pro")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Ditado profissional com OpenAI")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            Spacer()

            VoiceBubbleView(
                title: viewModel.bubbleStateTitle,
                subtitle: viewModel.bubbleStateSubtitle,
                isRecording: viewModel.isRecording,
                isTranscribing: viewModel.isTranscribing,
                audioLevel: viewModel.audioLevel
            )
        }
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 10) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                        Text(section.title)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedSection == section ? Color.black : Color.white.opacity(0.84))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedSection == section ? Color.white : Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}


private struct HomePage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DarkCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Push-to-Talk", systemImage: "keyboard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(viewModel.hotkeyLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.88))
                    }

                    Text(
                        viewModel.isHotkeyReady
                            ? "Usa o atalho para iniciar/parar gravação."
                            : "Atalho indisponível. Usa o botão abaixo."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.68))
                }
            }

            Button {
                viewModel.toggleRecordingFromButton()
            } label: {
                HStack {
                    Spacer()
                    Label(
                        viewModel.isRecording ? "Parar Ditado" : "Iniciar Ditado",
                        systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    Spacer()
                }
                .font(.headline)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRecording ? .red : .blue)
            .disabled(viewModel.isActionDisabled)

            if viewModel.isTranscribing {
                Button("Cancelar Transcrição") {
                    viewModel.cancelTranscription()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(viewModel.isStatusError ? Color.red.opacity(0.95) : Color.white.opacity(0.76))
                .textSelection(.enabled)

            DarkCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcrição Atual")
                        .font(.headline)
                        .foregroundStyle(.white)
                    ScrollView {
                        Text(viewModel.lastTranscript.isEmpty ? "Sem texto no momento." : viewModel.lastTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                    .frame(minHeight: 260)
                }
            }
        }
    }
}

private struct OptionsPage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("API OpenAI")
                            .font(.headline)
                            .foregroundStyle(.white)

                        SecureField("sk-...", text: $viewModel.apiKeyDraft)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .foregroundStyle(.white)

                        HStack(spacing: 10) {
                            Button("Colar") {
                                viewModel.pasteAPIKeyFromClipboard()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)

                            Button("Guardar Key") {
                                viewModel.saveAPIKey()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Remover") {
                                viewModel.clearAPIKey()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }

                        Text(viewModel.keyStatusText)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                    }
                }

                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Push-to-Talk")
                            .font(.headline)
                            .foregroundStyle(.white)

                        HStack {
                            Text("Atalho atual")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.66))
                            Spacer()
                            Text(viewModel.hotkeyLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }

                        HStack(spacing: 10) {
                            Button(viewModel.isCapturingHotkey ? "A Capturar..." : "Capturar Novo Atalho") {
                                viewModel.beginHotkeyCapture()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isCapturingHotkey)

                            if viewModel.isCapturingHotkey {
                                Button("Cancelar") {
                                    viewModel.cancelHotkeyCapture()
                                }
                                .buttonStyle(.bordered)
                                .tint(.white)
                            }
                        }

                        Text(viewModel.hotkeyCaptureHint)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                    }
                }

                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Modelo de Transcrição")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Picker("Modelo", selection: $viewModel.selectedTranscriptionModel) {
                            ForEach(TranscriptionModel.allCases) { model in
                                Text("\(model.displayName) — \(model.subtitle)")
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .onChange(of: viewModel.selectedTranscriptionModel) { _ in
                            viewModel.onTranscriptionModelChanged()
                        }
                    }
                }

                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tradução")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Toggle("Traduzir automaticamente após transcrição", isOn: $viewModel.translationEnabled)
                            .toggleStyle(.switch)
                            .onChange(of: viewModel.translationEnabled) { _ in
                                viewModel.onTranslationSettingsChanged()
                            }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Língua de origem")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.66))
                                Picker("Origem", selection: $viewModel.selectedSourceLanguage) {
                                    ForEach(SupportedLanguage.allCases) { lang in
                                        Text(lang.displayName).tag(lang)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white)
                                .onChange(of: viewModel.selectedSourceLanguage) { _ in
                                    viewModel.onTranslationSettingsChanged()
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Língua de destino")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.66))
                                Picker("Destino", selection: $viewModel.selectedTargetLanguage) {
                                    ForEach(SupportedLanguage.targetLanguages) { lang in
                                        Text(lang.displayName).tag(lang)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.white)
                                .onChange(of: viewModel.selectedTargetLanguage) { _ in
                                    viewModel.onTranslationSettingsChanged()
                                }
                            }
                        }

                        Text(viewModel.translationStatusText)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }

                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Comportamento")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Toggle("Auto-paste após transcrição", isOn: $viewModel.autoPasteEnabled)
                            .toggleStyle(.switch)

                        HStack {
                            Text(viewModel.accessibilityStatusText)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.7))
                            Spacer()
                            Button("Ativar Accessibilidade") {
                                viewModel.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct DarkCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}
