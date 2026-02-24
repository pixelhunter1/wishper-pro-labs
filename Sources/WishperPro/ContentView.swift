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
        case .home: return "house.fill"
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        ScrollView(.vertical) {
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

                Text(viewModel.lastTranscriptionDiagnostics)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.58))
                    .textSelection(.enabled)

                if !viewModel.transcriptionDiagnosticsHistory.isEmpty {
                    DarkCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Diagnóstico (últimas transcrições)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.82))
                            ForEach(viewModel.transcriptionDiagnosticsHistory.prefix(4), id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.64))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                DarkCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Transcrição Atual")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                            if !viewModel.lastTranscript.isEmpty {
                                if viewModel.isLoadingTTS {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                } else if viewModel.isSpeaking {
                                    Button {
                                        viewModel.stopSpeaking()
                                    } label: {
                                        Label("Parar", systemImage: "stop.fill")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .controlSize(.small)
                                } else {
                                    Button {
                                        viewModel.speakText(viewModel.lastTranscript)
                                    } label: {
                                        Label("Ouvir", systemImage: "speaker.wave.2.fill")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                                    .controlSize(.small)
                                }
                            }
                        }
                        ScrollView {
                            Text(viewModel.lastTranscript.isEmpty ? "Sem texto no momento." : viewModel.lastTranscript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .padding(.vertical, 6)
                        }
                        .frame(minHeight: 180, maxHeight: 260)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct OptionsPage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                apiSettingsCard
                hotkeySettingsCard
                transcriptionSettingsCard
                translationSettingsCard
                ttsSettingsCard
                behaviorSettingsCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var apiSettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "API OpenAI",
                    subtitle: "Gerir credenciais de acesso para transcrição, tradução e voz."
                )

                SettingsSubgroup("Chave de API") {
                    SecureField("sk-...", text: $viewModel.apiKeyDraft)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .foregroundStyle(.white)
                }

                SettingsSubgroup("Ações") {
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
                }

                SettingsInfoText(viewModel.keyStatusText)
            }
        }
    }

    private var hotkeySettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "Push-to-Talk",
                    subtitle: "Define a combinação para iniciar e parar o ditado."
                )

                SettingsSubgroup("Atalho atual") {
                    HStack {
                        Text("Combinação")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                        Spacer()
                        Text(viewModel.hotkeyLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }

                SettingsSubgroup("Captura") {
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
                    SettingsInfoText(viewModel.hotkeyCaptureHint)
                }
            }
        }
    }

    private var transcriptionSettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "Modelo de Transcrição",
                    subtitle: "Escolhe o modelo usado no endpoint de transcrição."
                )

                SettingsSubgroup("Modelo") {
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
        }
    }

    private var translationSettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "Tradução",
                    subtitle: "Configura tradução automática após a transcrição."
                )

                SettingsSubgroup("Automação") {
                    Toggle("Traduzir automaticamente após transcrição", isOn: $viewModel.translationEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: viewModel.translationEnabled) { _ in
                            viewModel.onTranslationSettingsChanged()
                        }
                }

                SettingsSubgroup("Línguas") {
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
                }

                SettingsInfoText(viewModel.translationStatusText)
            }
        }
    }

    private var ttsSettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "Voz (Text-to-Speech)",
                    subtitle: "Seleciona modelo, voz e variante para reprodução."
                )

                SettingsSubgroup("Configuração de voz") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voz")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                        Picker("Voz", selection: $viewModel.selectedTTSVoice) {
                            ForEach(viewModel.availableTTSVoices) { voice in
                                Text(
                                    viewModel.selectedTTSModel.supportedVoices.contains(voice)
                                        ? "\(voice.displayName) — \(voice.description)"
                                        : "\(voice.displayName) — \(voice.description) (requer GPT-4o Mini TTS)"
                                )
                                .tag(voice)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .onChange(of: viewModel.selectedTTSVoice) { _ in
                            viewModel.onTTSVoiceChanged()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Modelo")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                        Picker("Modelo", selection: $viewModel.selectedTTSModel) {
                            ForEach(TTSModel.allCases) { model in
                                Text("\(model.displayName) — \(model.subtitle)")
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .onChange(of: viewModel.selectedTTSModel) { _ in
                            viewModel.onTTSModelChanged()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Variante do Português")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                        Picker("Variante do Português", selection: $viewModel.selectedPortugueseVariant) {
                            ForEach(PortugueseVariant.allCases) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .onChange(of: viewModel.selectedPortugueseVariant) { _ in
                            viewModel.onPortugueseVariantChanged()
                        }
                    }
                }

                SettingsSubgroup("Preview") {
                    HStack(spacing: 10) {
                        if viewModel.isLoadingTTS {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("A gerar preview...")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.66))
                        } else if viewModel.isSpeaking {
                            Button("Parar Preview") {
                                viewModel.stopSpeaking()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        } else {
                            Button {
                                viewModel.previewTTSVoice(viewModel.selectedTTSVoice)
                            } label: {
                                Label("Ouvir Preview", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(!viewModel.isAPIKeySaved)
                        }
                    }
                }

                if let ttsCompatibilityHint = viewModel.ttsCompatibilityHint {
                    SettingsInfoText(ttsCompatibilityHint)
                }

                SettingsInfoText("Segundo a OpenAI, as vozes atuais estão otimizadas para inglês.")
                SettingsInfoText(viewModel.ttsStatusText)
            }
        }
    }

    private var behaviorSettingsCard: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCardHeader(
                    title: "Comportamento",
                    subtitle: "Define como o texto é aplicado e que permissões estão ativas."
                )

                SettingsSubgroup("Fluxo de texto") {
                    Toggle("Auto-paste após transcrição", isOn: $viewModel.autoPasteEnabled)
                        .toggleStyle(.switch)
                }

                SettingsSubgroup("Acessibilidade") {
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
    }
}

private struct SettingsCardHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.66))
        }
    }
}

private struct SettingsSubgroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsInfoText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.66))
            .lineLimit(3)
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
