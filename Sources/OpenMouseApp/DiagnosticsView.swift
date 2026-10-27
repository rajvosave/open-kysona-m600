import SwiftUI
import OpenMouseKit

/// The developer view: HID interfaces, raw probes and the traffic log.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            deviceList.frame(minWidth: 300)
            diagnostics.frame(minWidth: 380)
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HID interfaces").font(.headline)
            if model.interfaces.isEmpty {
                Text("No matching device found. Plug in the mouse or dongle.")
                    .foregroundStyle(.secondary)
            }
            List(model.interfaces, selection: $model.selectedID) { i in
                VStack(alignment: .leading) {
                    Text("\(i.product)  \(String(format: "%04X:%04X", i.vendorID, i.productID))")
                    Text("usage \(String(format: "%04X/%04X", i.usagePage, i.usage))  in \(i.maxInputReportSize)  out \(i.maxOutputReportSize)  feat \(i.maxFeatureReportSize)")
                        .font(.caption).foregroundStyle(.secondary)
                    if i.looksLikeVendorChannel {
                        Text("probable control channel").font(.caption).foregroundStyle(.green)
                    }
                }
                .tag(i.id)
            }
            Button(model.isOpen ? "Reopen" : "Open selected") { model.openSelected() }
                .disabled(model.selectedID == nil)
        }
        .padding()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").font(.headline)
            HStack {
                Button("Read version") { model.readVersion() }
                Button("Read current DPI") { model.readDPI() }
                Button("Read all settings") { model.readAll() }
            }
            .disabled(!model.isOpen)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .onChange(of: model.log.count) { _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .background(.quaternary.opacity(0.4))
        }
        .padding()
    }
}
