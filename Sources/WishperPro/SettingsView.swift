import AppKit
import AVFoundation
import SwiftUI

/// Deep links to the Privacy panes of System Settings.
enum SystemSettings {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @State private var pane = SettingsPane.general
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            // Ignores nil so a click can't leave the sidebar without a selection.
            List(selection: Binding(get: { pane }, set: { if let new = $0 { pane = new } })) {
                row(.general)
                row(.dictation)
                row(.bubble)
                Section("Texto") {
                    row(.styles)
                    row(.dictionary)
                    row(.translation)
                }
            }
            .hidingSidebarToggle()
            // After hidingSidebarToggle: set before it, the width is ignored and the sidebar opens at 140.
            .navigationSplitViewColumnWidth(220)
            // The window opens with the sidebar focused, not the API key field. Async: on appear the
            // window isn't key yet.
            .focused($sidebarFocused)
            .onAppear { DispatchQueue.main.async { sidebarFocused = true } }
        } detail: {
            detail
                .navigationTitle(pane.title)
        }
        .toolbar {
            // With no items there is no toolbar, and without a toolbar the sidebar stops below
            // the title bar instead of running to the top like Finder's. This empty item keeps it.
            if #available(macOS 26.0, *) {
                ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            }
        }
        // The detail column keeps the 540 points of the old tabbed window: the bubble preview needs them.
        // 570 high fits all of Geral without scrolling.
        .frame(width: 760, height: 570)
        .onAppear { viewModel.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        // Finder's selection: a faint pill 10 points in from the sidebar's edges, with the icon and
        // text in the accent colour.
        let isSelected = pane == self.pane
        let tint = isSelected ? Color.accentColor : Color.primary
        return Label {
            Text(pane.title).foregroundStyle(tint)
        } icon: {
            Image(systemName: pane.systemImage).foregroundStyle(tint)
        }
        .background(NoSystemSelectionHighlight())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .padding(.horizontal, 10)
                .opacity(isSelected ? 1 : 0)
        )
        .tag(pane)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralPane(viewModel: viewModel)
        case .dictation: DictationPane(viewModel: viewModel)
        case .bubble: BubblePane(viewModel: viewModel)
        case .styles: StylesPane(settings: viewModel.textSettings)
        case .dictionary: DictionaryPane(settings: viewModel.textSettings)
        case .translation: TranslationPane(viewModel: viewModel)
        }
    }
}

private enum SettingsPane {
    case general, dictation, bubble, styles, dictionary, translation

    var title: String {
        switch self {
        case .general: return "Geral"
        case .dictation: return "Ditado"
        case .bubble: return "Bolha"
        case .styles: return "Estilos"
        case .dictionary: return "Dicionário"
        case .translation: return "Tradução"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .bubble: return "text.bubble"
        case .styles: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .translation: return "translate"
        }
    }
}

private extension View {
    /// Keeps the sidebar always visible, like System Settings. macOS 13 keeps the toggle.
    @ViewBuilder
    func hidingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

/// Turns off the list's own selection highlight (a solid grey or accent pill) so the row can draw
/// Finder's faint one. Selection itself, arrow keys and VoiceOver work as before.
private struct NoSystemSelectionHighlight: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) {
                view = current.superview
            }
            (view as? NSTableView)?.selectionHighlightStyle = .none
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

private struct GeneralPane: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    BrandMarkView(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wishper Pro")
                            .font(.title2.weight(.semibold))
                        Text("Versão \(Bundle.main.appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                SecureField("API key", text: $viewModel.apiKeyDraft, prompt: Text("sk-…"))
                    .onSubmit { viewModel.saveAPIKey() }
                HStack {
                    Text(viewModel.keyStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remover", role: .destructive) { viewModel.clearAPIKey() }
                        .disabled(!viewModel.isAPIKeySaved)
                    Button("Guardar") { viewModel.saveAPIKey() }
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Conta OpenAI")
            } footer: {
                Text("A key fica guardada no Keychain deste Mac.")
            }

            Section("Permissões") {
                PermissionRow(
                    title: "Microfone",
                    detail: "Para ouvir o que dizes.",
                    isGranted: viewModel.microphoneStatus == .authorized,
                    actionTitle: viewModel.microphoneStatus == .notDetermined
                        ? "Permitir…"
                        : "Abrir Definições do Sistema…"
                ) {
                    if viewModel.microphoneStatus == .notDetermined {
                        viewModel.requestMicrophoneAccess()
                    } else {
                        SystemSettings.open(.microphone)
                    }
                }
                PermissionRow(
                    title: "Acessibilidade",
                    detail: "Para colar o texto na app onde estás.",
                    isGranted: viewModel.hasAccessibilityPermission,
                    actionTitle: "Abrir Definições do Sistema…"
                ) {
                    viewModel.requestAccessibilityPermission()
                }
            }

            Section("Arranque") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                Toggle("Mostrar ícone na Dock", isOn: $viewModel.showInDock)
            }

            if viewModel.isStatusError {
                Section {
                    Label(viewModel.statusMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if isGranted {
                Label("Concedida", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct DictationPane: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Combinação") {
                    HStack(spacing: 8) {
                        Text(viewModel.isCapturingHotkey ? "Prime a nova combinação…" : viewModel.hotkeyLabel)
                            .foregroundStyle(viewModel.isCapturingHotkey ? .secondary : .primary)
                        if viewModel.isCapturingHotkey {
                            Button("Cancelar") { viewModel.cancelHotkeyCapture() }
                        } else {
                            Button("Alterar…") { viewModel.beginHotkeyCapture() }
                        }
                    }
                }
                Picker("Comportamento", selection: $viewModel.hotkeyBehavior) {
                    ForEach(HotkeyBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            } header: {
                Text("Atalho")
            } footer: {
                Text("\(viewModel.hotkeyBehavior.explanation) Esc cancela o ditado.")
            }

            Section {
                Picker("Língua do ditado", selection: $viewModel.selectedSourceLanguage) {
                    ForEach(SupportedLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Text("Língua")
            } footer: {
                Text("Escolher a língua certa melhora a precisão. Em Auto, a língua é detetada.")
            }

            Section("Texto") {
                Toggle("Colar automaticamente", isOn: $viewModel.autoPasteEnabled)
                Toggle("Repor o clipboard depois de colar", isOn: $viewModel.restoreClipboard)
                    .disabled(!viewModel.autoPasteEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StylesPane: View {
    @ObservedObject var settings: TextSettings

    var body: some View {
        Form {
            Section {
                Toggle("Melhorar o texto com IA", isOn: $settings.cleanupEnabled)
            } footer: {
                Text("Tira hesitações e repetições e corrige a pontuação, mantendo as tuas palavras.")
            }

            Section("Estilo por tipo") {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.displayName, selection: Binding(
                        get: { settings.style(for: category) },
                        set: { settings.setStyle($0, for: category) }
                    )) {
                        ForEach(TextStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }
            }
            .disabled(!settings.cleanupEnabled)

            Section {
                if settings.recentTargets.isEmpty {
                    Text("Os sítios onde ditares aparecem aqui.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.recentTargets) { target in
                    TargetCategoryRow(target: target, settings: settings)
                }
            } header: {
                Text("Apps e sites")
            } footer: {
                Text("O tipo decide o estilo usado nesse sítio.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TargetCategoryRow: View {
    let target: RecentTarget
    @ObservedObject var settings: TextSettings

    var body: some View {
        Picker(selection: Binding(
            get: { settings.targetCategories[target.key] },
            set: { settings.setCategory($0, forKey: target.key) }
        )) {
            Text("Automático (\(StyleCatalog.builtInCategory(forKey: target.key).displayName))")
                .tag(AppCategory?.none)
            Divider()
            ForEach(AppCategory.allCases) { category in
                Text(category.displayName).tag(AppCategory?.some(category))
            }
        } label: {
            Label {
                Text(target.name)
            } icon: {
                TargetIcon(key: target.key)
            }
        }
    }
}

private struct TargetIcon: View {
    let key: String

    var body: some View {
        if key.hasPrefix("app:"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(key.dropFirst(4))) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe")
                .frame(width: 16, height: 16)
        }
    }
}

private struct DictionaryPane: View {
    @ObservedObject var settings: TextSettings
    @State private var newWord = ""
    @State private var rejection: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Nova palavra", text: Binding(
                        get: { newWord },
                        set: { newWord = $0; rejection = nil }
                    ))
                        .onSubmit(add)
                    Button("Adicionar", action: add)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let rejection {
                    Text(rejection)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Nomes, marcas e siglas que devem ser escritos exatamente assim. Ajuda a transcrição e a limpeza.")
            }

            Section("Palavras (\(settings.dictionary.count))") {
                if settings.dictionary.isEmpty {
                    Text("O dicionário está vazio.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.dictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            settings.removeWord(word)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remover \(word)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        if let refused = settings.addWord(newWord) {
            rejection = refused.message
        } else {
            rejection = nil
            newWord = ""
        }
    }
}

private struct TranslationPane: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Traduzir depois de transcrever", isOn: $viewModel.translationEnabled)
                Picker("Traduzir para", selection: $viewModel.selectedTargetLanguage) {
                    ForEach(SupportedLanguage.targetLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(!viewModel.translationEnabled)
            } footer: {
                Text("A língua de origem é a língua do ditado, que escolhes em Ditado.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BubblePane: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        Form {
            Section {
                VoiceBubbleView(
                    phase: .listening,
                    mode: viewModel.bubbleMode == .hidden ? .compact : viewModel.bubbleMode,
                    level: 0.45,
                    liveText: "Olá Rui, amanhã consigo passar aí por volta das dez para vermos o orçamento",
                    appName: "Mail",
                    appIcon: NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .opacity(viewModel.bubbleMode == .hidden ? 0.4 : 1)
                .accessibilityHidden(true)
            }

            Section {
                Picker("Estilo", selection: $viewModel.bubbleMode) {
                    ForEach(BubbleMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Posição", selection: $viewModel.bubblePosition) {
                    ForEach(BubblePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
            } footer: {
                Text(
                    viewModel.bubbleMode == .hidden
                        ? "A bolha só aparece quando há um erro."
                        : "A bolha nunca fica com o foco e deixa passar os cliques."
                )
            }
        }
        .formStyle(.grouped)
    }
}
