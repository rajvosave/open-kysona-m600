import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDiagnostics = false

    var body: some View {
        MouseView(onDiagnostics: { showDiagnostics = true })
            .overlay { if model.settings == nil { waitingOverlay } }
            .animation(.easeInOut(duration: 0.2), value: model.settings == nil)
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
                    .frame(minWidth: 760, minHeight: 520)
                    .overlay(alignment: .topTrailing) {
                        Button("Done") { showDiagnostics = false }.padding(12)
                    }
            }
    }

    /// Covers the controls until the mouse has answered, so nothing looks usable while disconnected.
    private var waitingOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.82))
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).colorScheme(.dark)
                Text(model.status).font(.headline).foregroundStyle(.white)
                Text(model.isOpen ? "Move your mouse to wake it and connect." : "Plug in the dongle and switch the mouse on.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 10) {
                    Button("Refresh") { model.refreshSettings() }.disabled(!model.isOpen || model.busy)
                    Button("Diagnostics") { showDiagnostics = true }
                }
            }
        }
        .transition(.opacity)
    }
}
