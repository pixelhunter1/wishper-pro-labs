import AppKit
import Combine
import SwiftUI

enum BubbleMode: String, CaseIterable, Identifiable {
    case liveText
    case compact
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveText: return "Texto ao vivo"
        case .compact: return "Compacta"
        case .hidden: return "Oculta"
        }
    }
}

enum BubblePosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: return "Em baixo ao centro"
        case .topCenter: return "Em cima ao centro"
        case .bottomRight: return "Canto inferior direito"
        }
    }
}

/// Floating, click-through panel that shows the dictation or the screen recording. It never takes focus.
@MainActor
final class FloatingBubbleController {
    private static let panelSize = NSSize(width: 520, height: 140)

    private let viewModel: VoicePasteViewModel
    private let recording: RecordingController
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var announcedDictation = DictationPhase.idle
    private var announcedRecording = RecordingPhase.idle

    init(viewModel: VoicePasteViewModel, recording: RecordingController) {
        self.viewModel = viewModel
        self.recording = recording
    }

    /// The bubble's window, which the screen recording picker leaves out.
    var windowNumber: Int? {
        panel?.windowNumber
    }

    func start() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingBubbleContent(viewModel: viewModel, recording: recording))
        self.panel = panel

        // @Published sends the new value before the property changes, so both phases come from the publishers.
        viewModel.$phase
            .removeDuplicates()
            .combineLatest(recording.$phase.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] dictation, recording in
                self?.show(dictation, recording)
            }
            .store(in: &cancellables)
    }

    /// A dictation takes the bubble; otherwise it shows the recording.
    private func show(_ dictation: DictationPhase, _ recordingPhase: RecordingPhase) {
        if dictation != announcedDictation {
            announcedDictation = dictation
            announce(dictation)
        }
        if recordingPhase != announcedRecording {
            announcedRecording = recordingPhase
            announce(recordingPhase)
        }
        guard let panel else { return }
        let isVisible: Bool
        switch dictation {
        case .failed:
            isVisible = true
        case .listening, .finalizing, .done:
            isVisible = viewModel.bubbleMode != .hidden
        case .idle:
            switch recordingPhase {
            case .idle, .choosing:
                isVisible = false
            case .failed:
                isVisible = true
            case .countdown, .recording, .saving, .saved, .translating, .translated:
                isVisible = viewModel.bubbleMode != .hidden
            }
        }
        guard isVisible else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            position(panel)
        }
        panel.orderFrontRegardless()
    }

    /// The panel has a fixed size; the pill aligns inside it, so the window never needs resizing.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = Self.panelSize
        let origin: NSPoint
        switch viewModel.bubblePosition {
        case .bottomCenter:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
        case .topCenter:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 8)
        case .bottomRight:
            origin = NSPoint(x: area.maxX - size.width - 18, y: area.minY + 92)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The panel never takes focus, so VoiceOver users hear state changes as announcements.
    private func announce(_ phase: DictationPhase) {
        switch phase {
        case .listening:
            post("A ouvir")
        case .done(let text), .failed(let text):
            post(text)
        case .idle, .finalizing:
            return
        }
    }

    private func announce(_ phase: RecordingPhase) {
        switch phase {
        case .recording:
            post("A gravar")
        case .saved:
            post("Gravação guardada")
        case .translating(nil):
            post("A preparar o vídeo traduzido")
        case .translated:
            post("Vídeo traduzido guardado")
        case .failed(let text):
            post(text)
        case .idle, .choosing, .countdown, .saving, .translating:
            return
        }
    }

    private func post(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

private struct FloatingBubbleContent: View {
    @ObservedObject var viewModel: VoicePasteViewModel
    @ObservedObject var recording: RecordingController

    var body: some View {
        Group {
            if viewModel.phase == .idle, recording.phase.showsBubble {
                RecordingBubbleView(
                    phase: recording.phase,
                    level: recording.level,
                    elapsed: recording.elapsed,
                    notice: recording.notice
                )
            } else {
                VoiceBubbleView(
                    phase: viewModel.phase,
                    mode: viewModel.bubbleMode,
                    level: viewModel.audioLevel,
                    liveText: viewModel.liveTranscript,
                    appName: viewModel.targetAppName,
                    appIcon: viewModel.targetAppIcon
                )
            }
        }
        .padding(12)
        .frame(width: 520, height: 140, alignment: alignment)
    }

    private var alignment: Alignment {
        switch viewModel.bubblePosition {
        case .bottomCenter: return .bottom
        case .topCenter: return .top
        case .bottomRight: return .bottomTrailing
        }
    }
}
