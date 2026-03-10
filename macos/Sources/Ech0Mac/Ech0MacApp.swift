import SwiftUI

@main
struct Ech0MacApp: App {
    @StateObject private var model = ReceiverViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
    }
}

