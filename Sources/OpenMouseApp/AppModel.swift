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
        }
    }

    func openSelected() {
        guard let id = selectedID else { return }
        do {
            try transport.open(id)
            isOpen = true
            append("opened interface \(id)")
            initialSettings = nil
            refreshSettings()
        } catch {
            append("open failed: \(error)")
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
    }

    @Published var settings: SettingsSnapshot?
    @Published var busy = false
    @Published var battery: BatteryStatus?
    /// Values at the first successful load after opening, for "Restore initial values".
    private var initialSettings: SettingsSnapshot?

    private func loadSettings() async throws -> SettingsSnapshot? {
        var v: [MouseSetting: UInt8] = [:]
        for s in [MouseSetting.reportRate, .currentDPIIndex, .lod, .motionSync, .angleSnapping, .rippleControl] {
            guard let value = try await device.readValue(s) else {
                append("\(s) read failed its checksum"); return nil
            }
            v[s] = value
        }
        return SettingsSnapshot(reportRate: v[.reportRate]!, dpiStage: v[.currentDPIIndex]!, lod: v[.lod]!,
                                motionSync: v[.motionSync]!, angleSnapping: v[.angleSnapping]!,
                                rippleControl: v[.rippleControl]!)
    }

    func refreshSettings() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                settings = try await loadSettings()
                battery = try await device.readBattery()
                if initialSettings == nil { initialSettings = settings }
            } catch { append("settings read failed: \(error) (is the mouse awake? move it)") }
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
