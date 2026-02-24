import SwiftUI

@main
struct WishperProApp: App {
    @StateObject private var viewModel: VoicePasteViewModel
    @StateObject private var floatingBubbleController: FloatingBubbleController

    init() {
        let viewModel = VoicePasteViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _floatingBubbleController = StateObject(
            wrappedValue: FloatingBubbleController(viewModel: viewModel)
        )
    }

    var body: some Scene {
        WindowGroup("Wishper Pro") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 540, minHeight: 620)
                .onAppear {
                    floatingBubbleController.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
