import SwiftUI

@main
struct WishperProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel: VoicePasteViewModel
    @StateObject private var floatingBubbleController: FloatingBubbleController

    init() {
        NSApplication.shared.setActivationPolicy(.regular)

        let viewModel = VoicePasteViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _floatingBubbleController = StateObject(
            wrappedValue: FloatingBubbleController(viewModel: viewModel)
        )
    }

    var body: some Scene {
        WindowGroup("Wishper Pro") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 540, minHeight: 480)
                .onAppear {
                    floatingBubbleController.start()
                }
        }
        .defaultSize(width: 760, height: 700)
        .windowResizability(.automatic)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}
