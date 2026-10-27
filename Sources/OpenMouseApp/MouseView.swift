import SwiftUI
import OpenMouseKit

/// Our own styling; the structure (DPI stages, report rate, sensor settings, switches)
/// follows what the mouse exposes, not any vendor artwork.
enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(white: 0.13)
    static let accent = Color(red: 0.95, green: 0.38, blue: 0.14)
    static let dim = Color.white.opacity(0.55)
    static let hairline = Color.white.opacity(0.14)
}

struct MouseView: View {
    @EnvironmentObject var model: AppModel
    var onDiagnostics: () -> Void = {}
    /// False only for the preview image: `ImageRenderer` cannot draw a ScrollView.
    var scrollable = true

    private var enabled: Bool { model.isOpen && model.settings != nil && !model.busy }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if scrollable { ScrollView { content } } else { content; Spacer(minLength: 0) }
            Divider().overlay(Theme.hairline)
            footer
        }
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 32) {
            dpiSection
            rateSection
            sensorSection
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 16) {
            Text("M600 V2").font(.title2.weight(.semibold))
            Spacer()
            if let b = model.battery {
                HStack(spacing: 6) {
                    Image(systemName: Self.batterySymbol(b.percent))
                    Text("\(b.percent)%").monospacedDigit()
                }
                .foregroundStyle(Theme.dim)
                .help("\(b.millivolts) mV. The meaning of the battery bytes is unconfirmed.")
            }
            Button(action: onDiagnostics) { Image(systemName: "wrench.and.screwdriver") }
                .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Diagnostics")
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle().fill(model.settings != nil ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(model.status).font(.callout).foregroundStyle(Theme.dim)
            Spacer()
            textButton("Refresh") { model.refreshSettings() }.disabled(!model.isOpen || model.busy)
            textButton("Restore initial values") { model.restoreInitial() }.disabled(!enabled)
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
    }

    static func batterySymbol(_ percent: UInt8) -> String {
        switch percent {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 11...: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: DPI

    private var dpiSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("DPI stages", trailing: model.stages.isEmpty ? "" : "\(model.stages.count) stages")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(currentDPIText)
                    .font(.system(size: 46, weight: .light, design: .rounded)).monospacedDigit()
                Text("DPI").foregroundStyle(Theme.dim)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(model.stages.enumerated()), id: \.offset) { i, stage in
                    stageTile(i, stage)
                }
                if model.stages.isEmpty { Text("Waiting for the mouse…").foregroundStyle(Theme.dim) }
            }
            Text("Click a stage to make it active. DPI values and colours can't be edited yet.")
                .font(.caption).foregroundStyle(Theme.dim)
        }
    }

    private var currentDPIText: String {
        guard let s = model.settings, Int(s.dpiStage) < model.stages.count,
              let dpi = model.stages[Int(s.dpiStage)].dpi else { return "–" }
        return String(dpi.x)
    }

    private func stageTile(_ index: Int, _ stage: MouseDevice.Stage) -> some View {
        let selected = model.settings?.dpiStage == UInt8(index)
        let c = stage.color
        return VStack(spacing: 8) {
            Button { model.change(.currentDPIIndex, to: UInt8(index), name: "DPI stage") } label: {
                VStack(spacing: 0) {
                    Text(verbatim: stage.dpi.map { String($0.x) } ?? "?")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 40)
                    Rectangle()
                        .fill(Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255))
                        .frame(height: 6)
                }
                .frame(width: 88)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(selected ? Color.white : Theme.hairline, lineWidth: selected ? 2 : 1))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            Image(systemName: "arrowtriangle.up.fill").font(.caption)
                .foregroundStyle(Theme.accent).opacity(selected ? 1 : 0)
        }
    }

    // MARK: report rate

    private var rateSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Report rate")
            HStack(spacing: 12) {
                ForEach(ReportRate.allCases.sorted { $0.hertz < $1.hertz }, id: \.rawValue) { rate in
                    pill("\(rate.hertz) Hz", selected: model.settings?.reportRate == rate.rawValue) {
                        model.change(.reportRate, to: rate.rawValue, name: "report rate")
                    }
                }
            }
        }
    }

    // MARK: sensor

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Sensor")
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    labelled("Lift-off distance") {
                        HStack(spacing: 12) {
                            pill("1 mm", selected: model.settings?.lod == 1) { model.change(.lod, to: 1, name: "LOD") }
                            pill("2 mm", selected: model.settings?.lod == 2) { model.change(.lod, to: 2, name: "LOD") }
                        }
                    }
                    labelled("Mode") {
                        Text(sensorModeText).padding(.horizontal, 18).padding(.vertical, 7)
                            .background(Theme.panel, in: Capsule()).foregroundStyle(Theme.dim)
                    }
                    Text("Sensor mode and Peak Performance can't be changed yet.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                VStack(alignment: .leading, spacing: 16) {
                    switchRow("Ripple control", model.settings?.rippleControl, .rippleControl)
                    switchRow("Angle snapping", model.settings?.angleSnapping, .angleSnapping)
                    switchRow("Motion sync", model.settings?.motionSync, .motionSync)
                }
            }
        }
    }

    private var sensorModeText: String {
        switch model.settings?.sensorMode {
        case 0: return "LP"
        case .some(let v): return "Mode \(v)"
        case nil: return "–"
        }
    }

    // MARK: pieces

    private func sectionTitle(_ title: String, trailing: String = "") -> some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Theme.dim)
            Spacer()
            Text(trailing).font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1).offset(y: 6) }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(Theme.dim)
            content()
        }
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).monospacedDigit()
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.panel, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func switchRow(_ title: String, _ value: UInt8?, _ setting: MouseSetting) -> some View {
        let on = value == 1
        return HStack(spacing: 14) {
            Button { model.change(setting, to: on ? 0 : 1, name: title.lowercased()) } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Theme.accent : Theme.panel).frame(width: 42, height: 24)
                        .overlay(Capsule().stroke(Theme.hairline))
                    Circle().fill(.white).frame(width: 18, height: 18).padding(.horizontal, 3)
                }
            }
            .buttonStyle(.plain).disabled(!enabled || value == nil)
            Text(title)
        }
    }
}
