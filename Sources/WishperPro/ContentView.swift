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

    var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .home: return "1"
        case .options: return ","
        }
    }

    var keyboardShortcutModifiers: EventModifiers {
        [.command]
    }

    var keyboardShortcutHint: String {
        switch self {
        case .home: return "Command+1"
        case .options: return "Command+,"
        }
    }
}

private enum UIStyle {
    static let pagePadding: CGFloat = 20
    static let contentSpacing: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let compactSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 14
    static let subgroupPadding: CGFloat = 10
    static let cardCornerRadius: CGFloat = 14
    static let subgroupCornerRadius: CGFloat = 10
    static let mutedTextOpacity: Double = 0.66
    static let secondaryTextOpacity: Double = 0.68
    static let tertiaryTextOpacity: Double = 0.55
    static let cardFillOpacity: Double = 0.08
    static let cardStrokeOpacity: Double = 0.12
    static let subgroupFillOpacity: Double = 0.05
    static let subgroupStrokeOpacity: Double = 0.08
}

struct ContentView: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @State private var selectedSection: AppSection = .home

    var body: some View {
        VStack(alignment: .leading, spacing: UIStyle.contentSpacing) {
            topBar

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
        .padding(UIStyle.pagePadding)
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

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            sectionSwitcher
            Spacer(minLength: 12)

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
                    HStack(spacing: UIStyle.compactSpacing) {
                        Image(systemName: section.icon)
                        Text(section.title)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedSection == section ? Color.black : Color.white.opacity(0.84))
                    .padding(.horizontal, UIStyle.cardPadding)
                    .padding(.vertical, UIStyle.compactSpacing)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedSection == section ? Color.white : Color.white.opacity(UIStyle.cardStrokeOpacity))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(section.keyboardShortcutKey, modifiers: section.keyboardShortcutModifiers)
                .accessibilityLabel("Abrir \(section.title)")
                .accessibilityHint("Atalho \(section.keyboardShortcutHint).")
            }
        }
    }
}

private struct HomePage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: UIStyle.cardSpacing) {
                HomeHeroCard(viewModel: viewModel)
                HomeTranscriptCard(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct HomeHeroCard: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
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
                .foregroundStyle(Color.white.opacity(UIStyle.secondaryTextOpacity))

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
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint("Alterna gravação. Atalho: Command+Return.")

                if viewModel.isTranscribing {
                    Button("Cancelar Transcrição") {
                        viewModel.cancelTranscription()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundStyle(
                        viewModel.isStatusError
                            ? Color.red.opacity(0.95)
                            : Color.white.opacity(0.76)
                    )
                    .textSelection(.enabled)
            }
        }
    }
}

private struct HomeTranscriptCard: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
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
                .frame(minHeight: 180, maxHeight: 260)
            }
        }
    }
}

private struct OptionsPage: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                apiSettingsCard
                hotkeySettingsCard
                translationSettingsCard
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
                    subtitle: "Gerir credenciais de acesso para transcrição e tradução."
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
                        .onSubmit {
                            viewModel.saveAPIKey()
                        }
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
                        .keyboardShortcut(.defaultAction)

                        Button("Remover") {
                            viewModel.clearAPIKey()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }

                SettingsInfoText(viewModel.keyStatusText)

                Text(viewModel.statusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        viewModel.isStatusError
                            ? Color.red.opacity(0.95)
                            : Color(red: 0.45, green: 0.85, blue: 0.55)
                    )
                    .textSelection(.enabled)
                    .lineLimit(2)
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
                                .foregroundStyle(Color.white.opacity(viewModel.translationEnabled ? 0.66 : 0.33))
                            Picker("Origem", selection: $viewModel.selectedSourceLanguage) {
                                ForEach(SupportedLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                            .disabled(!viewModel.translationEnabled)
                            .opacity(viewModel.translationEnabled ? 1.0 : 0.45)
                            .onChange(of: viewModel.selectedSourceLanguage) { _ in
                                viewModel.onTranslationSettingsChanged()
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Língua de destino")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(viewModel.translationEnabled ? 0.66 : 0.33))
                            Picker("Destino", selection: $viewModel.selectedTargetLanguage) {
                                ForEach(SupportedLanguage.targetLanguages) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                            .disabled(!viewModel.translationEnabled)
                            .opacity(viewModel.translationEnabled ? 1.0 : 0.45)
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
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(UIStyle.mutedTextOpacity))
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
        VStack(alignment: .leading, spacing: UIStyle.compactSpacing) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(UIStyle.tertiaryTextOpacity))
            content
        }
        .padding(UIStyle.subgroupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UIStyle.subgroupCornerRadius, style: .continuous)
                .fill(Color.white.opacity(UIStyle.subgroupFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIStyle.subgroupCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(UIStyle.subgroupStrokeOpacity), lineWidth: 1)
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
            .foregroundStyle(Color.white.opacity(UIStyle.mutedTextOpacity))
            .lineLimit(3)
    }
}

private struct DarkCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(UIStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UIStyle.cardCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(UIStyle.cardFillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIStyle.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(UIStyle.cardStrokeOpacity), lineWidth: 1)
            )
    }
}
