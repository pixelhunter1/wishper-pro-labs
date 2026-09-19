import AppKit
import SwiftUI

struct WishperProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(viewModel: appDelegate.viewModel, recording: appDelegate.recording)
        } label: {
            MenuBarLabel(viewModel: appDelegate.viewModel, recording: appDelegate.recording)
        }
        .menuBarExtraStyle(.menu)

        // A WindowGroup, not Settings or Window: on macOS 26 only a WindowGroup window gets Finder's
        // one-row toolbar and a sidebar whose corners are concentric with the window's. Opening it
        // by value keeps it to one window.
        WindowGroup("Definições", id: SettingsOpener.windowID, for: String.self) { _ in
            SettingsView(viewModel: appDelegate.viewModel)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = VoicePasteViewModel()
    let recording = RecordingController()
    private lazy var bubbleController = FloatingBubbleController(viewModel: viewModel, recording: recording)

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel.applyDockVisibility()
        bubbleController.start()
        recording.excludedWindowIDs = { [weak self] in
            [self?.bubbleController.windowNumber].compactMap { $0 }
        }
        if viewModel.needsSetup {
            DispatchQueue.main.async { SettingsOpener.open() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsOpener.open()
        return false
    }

    /// A screen recording in progress is closed properly before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording.phase.isBusy else { return .terminateNow }
        Task {
            await recording.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Opens the Settings window from anywhere (menu, first launch, Dock) and brings it to the front.
/// Triggers the app menu's ⌘, item (OpenSettingsButton), which exists even for LSUIElement apps (verified on macOS 26).
@MainActor
enum SettingsOpener {
    static let windowID = "settings"

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: index)
        }
    }
}

/// The app menu's ⌘, item, which SettingsOpener triggers from outside SwiftUI.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Definições…") { openWindow(id: SettingsOpener.windowID, value: SettingsOpener.windowID) }
            .keyboardShortcut(",", modifiers: .command)
    }
}

struct MenuBarContent: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Text(viewModel.menuStatusText)
        Button(viewModel.isRecording ? "Parar ditado" : "Iniciar ditado") {
            viewModel.toggleRecordingFromButton()
        }
        .disabled(viewModel.isTranscribing)
        Button("Copiar última transcrição") {
            viewModel.copyLastTranscript()
        }
        .disabled(viewModel.lastTranscript.isEmpty)
        if RecordingController.isSupported {
            Divider()
            Button(recording.phase.menuTitle) {
                recording.toggle()
            }
            .disabled(!recording.phase.acceptsMenuAction)
            .keyboardShortcut(
                recording.phase.acceptsStopShortcut ? KeyboardShortcut(.escape, modifiers: [.control, .command]) : nil
            )
            Picker("Microfone", selection: Binding(
                get: { recording.menuMicrophone },
                set: { recording.microphoneID = $0 }
            )) {
                Text("Predefinido do sistema").tag("")
                ForEach(recording.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
                Text("Sem microfone").tag("none")
            }
            .pickerStyle(.menu)
            .disabled(recording.phase.isBusy)
            Toggle("Som do Mac", isOn: $recording.recordsSystemAudio)
                .disabled(recording.phase.isBusy)
            Button("Mostrar gravações") {
                recording.showRecordings()
            }
        }
        Divider()
        Button("Definições…") {
            SettingsOpener.open()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Sobre o Wishper Pro") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Divider()
        Button("Sair do Wishper Pro") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Group {
            switch recording.phase {
            case .countdown(let seconds):
                recordingLabel("\(seconds)")
            case .recording:
                recordingLabel(RecordingClock.text(recording.elapsed))
            default:
                if viewModel.isRecording || viewModel.isTranscribing {
                    activeIcon
                } else {
                    Image(nsImage: BrandMark.image(pointSize: 18))
                        .renderingMode(.template)
                }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    /// Like macOS's own screen recording: a record symbol and the time, in the menu bar's monochrome.
    private func recordingLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "record.circle")
            Text(text)
                .monospacedDigit()
        }
    }

    private var accessibilityText: String {
        switch recording.phase {
        case .countdown(let seconds):
            return "Wishper Pro, a gravar em \(seconds)"
        case .recording:
            return "Wishper Pro, a gravar, \(RecordingClock.text(recording.elapsed))"
        default:
            return "Wishper Pro"
        }
    }

    @ViewBuilder
    private var activeIcon: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: viewModel.isRecording)
        } else {
            Image(systemName: "waveform")
        }
    }
}
