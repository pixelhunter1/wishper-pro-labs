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

/// Floating, click-through panel that shows the dictation state. It never takes focus.
@MainActor
final class FloatingBubbleController {
    private static let panelSize = NSSize(width: 520, height: 140)

    private let viewModel: VoicePasteViewModel
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: VoicePasteViewModel) {
        self.viewModel = viewModel
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
        panel.contentView = NSHostingView(rootView: FloatingBubbleContent(viewModel: viewModel))
        self.panel = panel

        viewModel.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.show(phase)
            }
            .store(in: &cancellables)
    }

    private func show(_ phase: DictationPhase) {
        announce(phase)
        guard let panel else { return }
        let isVisible: Bool
        switch phase {
        case .idle:
            isVisible = false
        case .failed:
            isVisible = true
        case .listening, .finalizing, .done:
            isVisible = viewModel.bubbleMode != .hidden
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
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let message: String
        switch phase {
        case .listening:
            message = "A ouvir"
        case .done(let text), .failed(let text):
            message = text
        case .idle, .finalizing:
            return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

private struct FloatingBubbleContent: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        VoiceBubbleView(
            phase: viewModel.phase,
            mode: viewModel.bubbleMode,
            level: viewModel.audioLevel,
            liveText: viewModel.liveTranscript,
            appName: viewModel.targetAppName,
            appIcon: viewModel.targetAppIcon
        )
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
