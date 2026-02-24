import SwiftUI

@main
struct WishperProApp: App {
    var body: some Scene {
        WindowGroup("Wishper Pro") {
            ContentView()
                .frame(minWidth: 540, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}
