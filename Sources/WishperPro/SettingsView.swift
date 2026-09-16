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

    var body: some View {
        TabView {
            GeneralSettingsTab(viewModel: viewModel)
                .tabItem { Label("Geral", systemImage: "gearshape") }
            DictationSettingsTab(viewModel: viewModel)
                .tabItem { Label("Ditado", systemImage: "mic") }
            TranslationSettingsTab(viewModel: viewModel)
                .tabItem { Label("Tradução", systemImage: "globe") }
        }
        .frame(width: 540, height: 500)
        .onAppear { viewModel.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }
}

private struct GeneralSettingsTab: View {
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

private struct DictationSettingsTab: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        Form {
            Section("Atalho") {
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
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettingsTab: View {
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
                Text("A língua de origem é a língua do ditado (separador Ditado).")
            }
        }
        .formStyle(.grouped)
    }
}
