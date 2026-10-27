import SwiftUI

struct ContentView: View {
    @State private var showDiagnostics = false

    var body: some View {
        MouseView(onDiagnostics: { showDiagnostics = true })
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
                    .frame(minWidth: 760, minHeight: 520)
                    .overlay(alignment: .topTrailing) {
                        Button("Done") { showDiagnostics = false }.padding(12)
                    }
            }
    }
}
