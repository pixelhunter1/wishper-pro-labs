import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingBubbleController: ObservableObject {
    private let viewModel: VoicePasteViewModel
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    init(viewModel: VoicePasteViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        guard !started else { return }
        started = true

        createPanelIfNeeded()
        bindState()
        updateVisibility()
    }

    private func bindState() {
        Publishers.CombineLatest(viewModel.$isRecording, viewModel.$isTranscribing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateVisibility()
            }
            .store(in: &cancellables)
    }

    private func updateVisibility() {
        guard let panel else { return }
        let shouldShow = viewModel.isRecording || viewModel.isTranscribing
        if shouldShow {
            positionPanel(panel)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        let frame = Self.initialFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        panel.contentView = NSHostingView(
            rootView: FloatingBubbleView(viewModel: viewModel)
        )
        panel.orderOut(nil)

        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let width = panel.frame.width
        let height = panel.frame.height
        let x = visibleFrame.maxX - width - 18
        let y = visibleFrame.minY + 92
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    private static func initialFrame() -> NSRect {
        NSRect(x: 0, y: 0, width: 172, height: 70)
    }
}

private struct FloatingBubbleView: View {
    @ObservedObject var viewModel: VoicePasteViewModel

    var body: some View {
        ZStack {
            Color.clear
            VoiceBubbleView(
                title: viewModel.bubbleStateTitle,
                subtitle: viewModel.bubbleStateSubtitle,
                isRecording: viewModel.isRecording,
                isTranscribing: viewModel.isTranscribing,
                audioLevel: viewModel.audioLevel
            )
        }
        .frame(width: 172, height: 70)
    }
}
