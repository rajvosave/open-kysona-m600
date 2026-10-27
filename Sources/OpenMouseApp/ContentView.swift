import SwiftUI
import OpenMouseKit

struct ContentView: View {
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
            settingsPanel
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

    private var settingsPanel: some View {
        GroupBox("Settings: each change is written, echo-checked and read back") {
            if let s = model.settings {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Report rate", selection: Binding(
                        get: { s.reportRate },
                        set: { model.change(.reportRate, to: $0, name: "report rate") })) {
                        ForEach(ReportRate.allCases.sorted { $0.hertz < $1.hertz }, id: \.rawValue) {
                            Text("\($0.hertz) Hz").tag($0.rawValue)
                        }
                    }
                    Picker("DPI stage", selection: Binding(
                        get: { s.dpiStage },
                        set: { model.change(.currentDPIIndex, to: $0, name: "DPI stage") })) {
                        ForEach(0..<UInt8(StageTable.stageCount), id: \.self) { Text("Stage \($0 + 1)").tag($0) }
                    }
                    Picker("LOD", selection: Binding(
                        get: { s.lod }, set: { model.change(.lod, to: $0, name: "LOD") })) {
                        Text("1 mm").tag(UInt8(1)); Text("2 mm").tag(UInt8(2))
                    }
                    toggle("Motion sync", s.motionSync, .motionSync)
                    toggle("Angle snapping", s.angleSnapping, .angleSnapping)
                    toggle("Ripple control", s.rippleControl, .rippleControl)
                    if let b = model.battery {
                        Text("Battery: \(b.percent) %, \(b.millivolts) mV (meaning of these bytes unconfirmed)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Refresh") { model.refreshSettings() }
                        Button("Restore initial values") { model.restoreInitial() }
                        Button("Clear log") { model.clearLog() }
                    }
                }
                .disabled(model.busy || !model.isOpen)
            } else {
                HStack {
                    Text("Not loaded. Open the control channel with the mouse awake.")
                        .foregroundStyle(.secondary)
                    Button("Refresh") { model.refreshSettings() }.disabled(!model.isOpen)
                }
            }
        }
    }

    private func toggle(_ title: String, _ value: UInt8, _ setting: MouseSetting) -> some View {
        Toggle(title, isOn: Binding(
            get: { value == 1 },
            set: { model.change(setting, to: $0 ? 1 : 0, name: title.lowercased()) }))
    }
}
