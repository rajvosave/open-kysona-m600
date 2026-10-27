import SwiftUI

@main
struct OpenMouseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenMouse") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
                .task { renderPreviewIfRequested() }
        }
    }
}

/// `OpenMouse --render-preview out.png` saves the main view with fixed demo values and quits.
/// Used to look at the layout without a mouse attached.
@MainActor
private func renderPreviewIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count else { return }
    let renderer = ImageRenderer(content: MouseView(scrollable: false)
        .environmentObject(AppModel.demo())
        .frame(width: 820, height: 700))
    renderer.scale = 2
    if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}
