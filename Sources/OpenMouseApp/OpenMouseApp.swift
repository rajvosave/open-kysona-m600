import SwiftUI
import OpenMouseKit

/// Closing the window leaves the menu bar item running; Quit in its menu ends the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar label, which stays alive after the window is closed.
    static var openMainWindow: (() -> Void)?

    /// Dock icon and window come and go together; the menu bar item stays.
    func applicationDidFinishLaunching(_ note: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            let closing = n.object as? NSWindow
            DispatchQueue.main.async {
                let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if !others { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showMainWindow() }
        return true
    }
}

@main
struct OpenMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenMouse", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
                .task { renderPreviewIfRequested() }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
    }
}

/// Mouse symbol plus the battery level; a bolt while charging.
private struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "computermouse")
            if let text = batteryText { Text(text) }
        }
        .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }

    private var batteryText: String? {
        guard let b = model.battery else { return nil }
        guard b.isCharging else { return "\(b.percent)%" }
        let level = model.fullWhileCharging ? 100 : model.lastLevelOnBattery.map(Int.init)
        return level.map { "\u{26A1}\($0)%" } ?? "\u{26A1}"
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let s = model.settings {
            if let b = model.battery {
                Text("Battery: " + b.summary(lastLevelOnBattery: model.lastLevelOnBattery, fullWhileCharging: model.fullWhileCharging))
            }
            Divider()
            ForEach(Array(model.stages.enumerated()), id: \.offset) { i, stage in
                Toggle(isOn: Binding(get: { s.dpiStage == UInt8(i) },
                                     set: { _ in model.change(.currentDPIIndex, to: UInt8(i), name: "DPI stage") })) {
                    Text("\(stage.dpi.map { String($0.x) } ?? "?") DPI")
                }
            }
            Divider()
            ForEach(ReportRate.allCases.sorted { $0.hertz < $1.hertz }, id: \.rawValue) { rate in
                Toggle(isOn: Binding(get: { s.reportRate == rate.rawValue },
                                     set: { _ in model.change(.reportRate, to: rate.rawValue, name: "report rate") })) {
                    Text("\(rate.hertz) Hz")
                }
            }
        } else {
            Text(model.isOpen ? "Move your mouse to connect" : "No mouse found")
        }
        Divider()
        Button("Open Settings…") {
            AppDelegate.showMainWindow()
        }
        Button("Quit OpenMouse") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// `OpenMouse --render-preview out.png [buttons]` saves the main view (or its Buttons tab) with
/// fixed demo values and quits.
/// Used to look at the layout without a mouse attached.
@MainActor
private func renderPreviewIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count else { return }
    let buttons = args.count > i + 2 && args[i + 2] == "buttons"
    let renderer = ImageRenderer(content: MouseView(scrollable: false, tab: buttons ? .buttons : .settings)
        .environmentObject(AppModel.demo())
        .frame(width: 820, height: buttons ? 640 : 840))
    renderer.scale = 2
    if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}
