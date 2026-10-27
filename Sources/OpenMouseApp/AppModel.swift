import SwiftUI
import OpenMouseKit

@MainActor
final class AppModel: ObservableObject {
    @Published var interfaces: [HIDInterfaceInfo] = []
    @Published var selectedID: UInt64?
    @Published var isOpen = false
    @Published var log: [String] = []

    private let transport = HIDTransport()
    private lazy var device = MouseDevice(transport: transport)

    init() {
        transport.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        device.onEvent = { [weak self] _ in
            // The mouse changed something itself (DPI or report-rate button): follow along.
            Task { @MainActor in self?.refreshSettings() }
        }
        device.onTraffic = { [weak self] direction, bytes in
            let arrow = direction == .sent ? "->" : "<-"
            self?.append("\(arrow) \(Self.hex(bytes))")
        }
        transport.start()
        refresh()
    }

    private func refresh() {
        interfaces = transport.interfaces
        if selectedID == nil || !interfaces.contains(where: { $0.id == selectedID }) {
            selectedID = interfaces.first(where: \.looksLikeVendorChannel)?.id
            isOpen = false
            settings = nil; stages = []; battery = nil
            status = selectedID == nil ? "No mouse found. Plug in the dongle." : "Connecting…"
        }
        // Connect on its own once the control channel shows up.
        if !isOpen, let id = selectedID, interfaces.first(where: { $0.id == id })?.looksLikeVendorChannel == true {
            openSelected()
        }
    }

    func openSelected() {
        guard let id = selectedID else { return }
        do {
            try transport.open(id)
            isOpen = true
            status = "Connecting…"
            append("opened interface \(id)")
            initialSettings = nil
            refreshSettings()
        } catch {
            append("open failed: \(error)")
            status = "Could not open the mouse. Allow Input Monitoring in System Settings."
        }
    }

    // Read-only probes.
    func readVersion() { run("read version") { try await $0.readVersionRaw() } }
    func readDPI() {
        Task {
            do {
                let index = try await device.readCurrentDPI()
                if let s = try await device.readSettings() {
                    append("DPI index \(index) of \(s.dpiStageCount) stages")
                } else {
                    append("DPI index \(index) (settings block failed checksum)")
                }
            } catch { append("read current DPI failed: \(error)") }
        }
    }

    // MARK: settings (the only writes in the app; each is echo- and read-back-checked)

    struct SettingsSnapshot: Equatable {
        var reportRate: UInt8
        var dpiStage: UInt8
        var lod: UInt8
        var motionSync: UInt8
        var angleSnapping: UInt8
        var rippleControl: UInt8
        var sensorMode: UInt8   // 0 = LP; HP value unconfirmed, so read-only
    }

    @Published var settings: SettingsSnapshot?
    @Published var busy = false
    @Published var battery: BatteryStatus?
    @Published var stages: [MouseDevice.Stage] = []
    @Published var status = "No mouse found. Plug in the dongle."
    /// Values at the first successful load after opening, for "Restore initial values".
    private var initialSettings: SettingsSnapshot?

    private func loadSettings() async throws -> SettingsSnapshot? {
        var v: [MouseSetting: UInt8] = [:]
        for s in [MouseSetting.reportRate, .currentDPIIndex, .lod, .motionSync, .angleSnapping, .rippleControl, .sensorMode] {
            guard let value = try await device.readValue(s) else {
                append("\(s) read failed its checksum"); return nil
            }
            v[s] = value
        }
        return SettingsSnapshot(reportRate: v[.reportRate]!, dpiStage: v[.currentDPIIndex]!, lod: v[.lod]!,
                                motionSync: v[.motionSync]!, angleSnapping: v[.angleSnapping]!,
                                rippleControl: v[.rippleControl]!, sensorMode: v[.sensorMode]!)
    }

    func refreshSettings() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                settings = try await loadSettings()
                stages = try await device.readStages()
                battery = try await device.readBattery()
                if initialSettings == nil { initialSettings = settings }
                status = settings == nil ? "Unexpected reply. Try Refresh." : "Connected"
            } catch {
                append("settings read failed: \(error)")
                status = "Mouse not responding. Move it, then Refresh."
            }
        }
    }

    /// Writes one setting, then checks the echo and reads it back.
    func change(_ setting: MouseSetting, to value: UInt8, name: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await writeAndVerify(setting, value, name: name)
                settings = try await loadSettings()
            } catch { append("\(name) write failed: \(error) (is the mouse awake? move it)") }
        }
    }

    /// Writes back every setting that differs from the values first read after opening.
    func restoreInitial() {
        guard !busy, let target = initialSettings, let now = settings else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let pairs: [(MouseSetting, String, UInt8, UInt8)] = [
                    (.reportRate, "report rate", now.reportRate, target.reportRate),
                    (.currentDPIIndex, "DPI stage", now.dpiStage, target.dpiStage),
                    (.lod, "LOD", now.lod, target.lod),
                    (.motionSync, "motion sync", now.motionSync, target.motionSync),
                    (.angleSnapping, "angle snapping", now.angleSnapping, target.angleSnapping),
                    (.rippleControl, "ripple control", now.rippleControl, target.rippleControl)]
                for (setting, name, current, wanted) in pairs where current != wanted {
                    try await writeAndVerify(setting, wanted, name: name)
                }
                settings = try await loadSettings()
            } catch { append("restore failed: \(error)") }
        }
    }

    private func writeAndVerify(_ setting: MouseSetting, _ value: UInt8, name: String) async throws {
        append("WRITE \(name) = \(value)")
        let echoed = try await device.writeValue(setting, value)
        let back = try await device.readValue(setting)
        append("\(name): echo \(echoed ? "ok" : "MISMATCH"), read back \(back.map(String.init) ?? "bad checksum")"
               + (echoed && back == value ? "  -> verified" : "  -> NOT verified"))
    }

    /// Reads everything we can decode, one request at a time. Read-only.
    func readAll() {
        Task {
            do {
                if let v = try await device.readVersionRaw() as [UInt8]? {
                    append("version bytes (meaning unconfirmed): \(Self.hex(Array(v[5...7])))")
                }
                let rate = try await device.readReportRate()
                append("report rate: \(rate.map { "\($0.hertz) Hz" } ?? "unknown value")")
                let index = try await device.readCurrentDPI()
                append("current DPI stage: \(index + 1) of \(StageTable.stageCount)")
                for (n, stage) in try await device.readStages().enumerated() {
                    let dpi = stage.dpi.map { "\($0.x) DPI" } ?? "bad checksum"
                    let c = stage.color
                    append(String(format: "  stage %d: %@  RGB %02X%02X%02X", n + 1, dpi, c.r, c.g, c.b))
                }
                for (name, setting) in [("LOD (1=1mm, 2=2mm)", MouseSetting.lod),
                                        ("motion sync", .motionSync), ("angle snapping", .angleSnapping),
                                        ("ripple control", .rippleControl), ("sensor mode (0=LP)", .sensorMode)] {
                    let v = try await device.readValue(setting)
                    append("\(name): \(v.map(String.init) ?? "bad checksum")")
                }
            } catch { append("read all failed: \(error)") }
        }
    }

    private func run(_ name: String, _ op: @escaping (MouseDevice) async throws -> [UInt8]) {
        Task {
            do { _ = try await op(device) } catch { append("\(name) failed: \(error)") }
        }
    }

    private func append(_ line: String) { log.append(line) }

    func clearLog() { log.removeAll() }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension AppModel {
    /// Fixed values for the preview image (`--render-preview`).
    static func demo() -> AppModel {
        let m = AppModel()
        m.isOpen = true
        m.status = "Connected"
        m.settings = SettingsSnapshot(reportRate: 0x01, dpiStage: 2, lod: 1, motionSync: 1,
                                      angleSnapping: 0, rippleControl: 0, sensorMode: 0)
        let table: [(Int, UInt8, UInt8, UInt8)] = [(400, 0x80, 0x80, 0), (800, 0, 0xFF, 0), (1600, 0x80, 0, 0xFF),
                                                   (3200, 0xFF, 0x80, 0xFF), (6400, 0xFF, 0, 0), (26000, 0x80, 0, 0xFF)]
        m.stages = table.map { MouseDevice.Stage(dpi: DPIEntry(x: $0.0, y: $0.0), color: DPIColor(r: $0.1, g: $0.2, b: $0.3)) }
        m.battery = BatteryStatus(percent: 80, flag: 0, millivolts: 4011)
        return m
    }
}
