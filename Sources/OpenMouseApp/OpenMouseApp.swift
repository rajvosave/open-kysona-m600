import SwiftUI

@main
struct OpenMouseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenMouse") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
