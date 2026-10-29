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
        // The vendor app polls the battery every few seconds; every 30 s is plenty here.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
    }

    private func setBattery(_ b: BatteryStatus?) {
        battery = b
        guard let b else { return }
        if !b.isCharging { lastLevelOnBattery = b.percent }
        fullStreak = (b.isCharging && b.percent >= 100) ? fullStreak + 1 : 0
        fullWhileCharging = fullStreak >= 2
    }

    /// Reads just the battery, skipped while another exchange is in flight.
    func refreshBattery() {
        guard isOpen, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let b = try? await device.readBattery() {
                batteryMisses = 0
                setBattery(b)
            } else {
                // The dongle stays plugged in when the mouse sleeps or is off, and then the poll
                // just times out. Drop the old reading after two misses instead of showing it forever.
                batteryMisses += 1
                if batteryMisses >= 2 { setBattery(nil); fullStreak = 0; fullWhileCharging = false }
            }
        }
    }

    private func refresh() {
        interfaces = transport.interfaces
        if selectedID == nil || !interfaces.contains(where: { $0.id == selectedID }) {
            selectedID = interfaces.first(where: \.looksLikeVendorChannel)?.id
            isOpen = false
            settings = nil; stages = []; keys = []; battery = nil; fullStreak = 0; fullWhileCharging = false
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
        var sensorMode: UInt8   // 0 = LP, 1 = HP, 10 = corded (read-only)
        /// Nil if the mouse didn't answer these with a valid checksum.
        var peakPerformance: UInt8?
        var peakTime: UInt8?
    }

    @Published var settings: SettingsSnapshot?
    @Published var busy = false
    @Published var battery: BatteryStatus?
    /// The last level seen while not charging; the reading while charging is inflated by the charger.
    @Published var lastLevelOnBattery: UInt8?
    /// True once the mouse has reported 100 on consecutive polls while charging.
    @Published var fullWhileCharging = false
    private var fullStreak = 0
    private var batteryMisses = 0
    @Published var stages: [MouseDevice.Stage] = []
    /// The button slots from flash; nil for a slot that failed its checksum.
    @Published var keys: [KeyFunction?] = []
    @Published var status = "No mouse found. Plug in the dongle."
    /// Values at the first successful load after opening, for "Restore initial values".
    private var initialSettings: SettingsSnapshot?
    private var initialColors: [DPIColor] = []
    private var initialDPIs: [Int?] = []
    private var initialKeys: [KeyFunction?] = []

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
                                rippleControl: v[.rippleControl]!, sensorMode: v[.sensorMode]!,
                                peakPerformance: try await device.readValue(.peakPerformance),
                                peakTime: try await device.readValue(.peakPerformanceTime))
    }

    func refreshSettings() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                settings = try await loadSettings()
                stages = try await device.readStages()
                keys = try await device.readKeyMap()
                setBattery(try await device.readBattery())
                if initialSettings == nil { initialSettings = settings; initialColors = stages.map(\.color); initialDPIs = stages.map { $0.dpi?.x }; initialKeys = keys }
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

    /// Writes one stage's colour, then checks the echo and reads the stages back.
    func changeColor(stage: Int, to color: DPIColor) {
        guard !busy, stages.indices.contains(stage), stages[stage].color != color else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await writeColorAndVerify(stage, color)
                stages = try await device.readStages()
            } catch { append("stage colour write failed: \(error) (is the mouse awake? move it)") }
        }
    }

    /// Writes one button slot, then checks the echo and reads the table back. Refuses a change
    /// that would leave no left-click button, and never overwrites a macro or shortcut slot.
    func changeKey(slot: Int, to function: KeyFunction) {
        guard !busy, KeyMap.physicalSlots.contains(slot), keys.indices.contains(slot),
              let current = keys[slot], current.isEditable, current != function else { return }
        var after = keys
        after[slot] = function
        guard KeyMap.physicalSlots.contains(where: { after[$0] == .mouse(.left) }) else {
            append("refused: at least one button must stay Left click")
            status = "At least one button must stay Left click."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await writeKeyAndVerify(slot, function)
                keys = try await device.readKeyMap()
            } catch { append("button write failed: \(error) (is the mouse awake? move it)") }
        }
    }

    private func writeKeyAndVerify(_ slot: Int, _ function: KeyFunction) async throws {
        append("WRITE button \(slot + 1) = \(function.title)")
        let echoed = try await device.writeKeyFunction(slot: slot, function)
        let back = try await device.readKeyMap()[slot]
        append("button \(slot + 1): echo \(echoed ? "ok" : "MISMATCH")"
               + (echoed && back == function ? "  -> verified" : "  -> NOT verified"))
    }

    /// Writes one stage's DPI (same on X and Y), then checks the echo and reads the stages back.
    func changeDPI(stage: Int, to dpi: Int) {
        guard !busy, stages.indices.contains(stage), DPIEntry.isValid(dpi: dpi),
              stages[stage].dpi?.x != dpi else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await writeDPIAndVerify(stage, dpi)
                stages = try await device.readStages()
            } catch { append("stage DPI write failed: \(error) (is the mouse awake? move it)") }
        }
    }

    private func writeDPIAndVerify(_ stage: Int, _ dpi: Int) async throws {
        append("WRITE stage \(stage + 1) DPI = \(dpi)")
        let echoed = try await device.writeStageDPI(stage: stage, dpi: dpi)
        let back = try await device.readStages()[stage].dpi
        append("stage \(stage + 1) DPI: echo \(echoed ? "ok" : "MISMATCH"), read back \(back.map { String($0.x) } ?? "bad checksum")"
               + (echoed && back == DPIEntry(x: dpi, y: dpi) ? "  -> verified" : "  -> NOT verified"))
    }

    private func writeColorAndVerify(_ stage: Int, _ color: DPIColor) async throws {
        append("WRITE stage \(stage + 1) colour = \(String(format: "%02X%02X%02X", color.r, color.g, color.b))")
        let echoed = try await device.writeStageColor(stage: stage, color)
        let back = try await device.readStages()[stage].color
        append("stage \(stage + 1) colour: echo \(echoed ? "ok" : "MISMATCH")"
               + (echoed && back == color ? "  -> verified" : "  -> NOT verified"))
    }

    /// Writes back every setting that differs from the values first read after opening.
    func restoreInitial() {
        guard !busy, let target = initialSettings, let now = settings else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                for slot in KeyMap.physicalSlots where keys.indices.contains(slot) && initialKeys.indices.contains(slot) {
                    if let wanted = initialKeys[slot], keys[slot] != wanted, keys[slot]?.isEditable == true, wanted.isEditable {
                        try await writeKeyAndVerify(slot, wanted)
                        keys[slot] = wanted
                    }
                }
                for (i, wanted) in initialDPIs.enumerated() where stages.indices.contains(i) {
                    if let wanted, stages[i].dpi?.x != wanted, DPIEntry.isValid(dpi: wanted) {
                        try await writeDPIAndVerify(i, wanted)
                    }
                }
                for (i, wanted) in initialColors.enumerated() where stages.indices.contains(i) && stages[i].color != wanted {
                    try await writeColorAndVerify(i, wanted)
                }
                let pairs: [(MouseSetting, String, UInt8, UInt8)] = [
                    (.reportRate, "report rate", now.reportRate, target.reportRate),
                    (.currentDPIIndex, "DPI stage", now.dpiStage, target.dpiStage),
                    (.lod, "LOD", now.lod, target.lod),
                    (.motionSync, "motion sync", now.motionSync, target.motionSync),
                    (.angleSnapping, "angle snapping", now.angleSnapping, target.angleSnapping),
                    (.rippleControl, "ripple control", now.rippleControl, target.rippleControl),
                    (.sensorMode, "sensor mode", now.sensorMode, target.sensorMode),
                    (.peakPerformance, "peak performance", now.peakPerformance ?? 0, target.peakPerformance ?? 0),
                    (.peakPerformanceTime, "peak performance time", now.peakTime ?? 0, target.peakTime ?? 0)]
                for (setting, name, current, wanted) in pairs where current != wanted && setting.accepts(wanted) {
                    try await writeAndVerify(setting, wanted, name: name)
                }
                settings = try await loadSettings()
                stages = try await device.readStages()
                keys = try await device.readKeyMap()
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
                if let b = try await device.readBattery() {
                    append("battery: \(b.percent) %, \(b.millivolts) mV, \(b.isCharging ? "charging" : "not charging")")
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
                for (n, key) in try await device.readKeyMap().enumerated() {
                    append("  button slot \(n + 1): \(key?.title ?? "bad checksum")")
                }
                for (name, setting) in [("LOD (1=1mm, 2=2mm)", MouseSetting.lod),
                                        ("motion sync", .motionSync), ("angle snapping", .angleSnapping),
                                        ("ripple control", .rippleControl), ("sensor mode (0=LP, 1=HP, 10=corded)", .sensorMode),
                                        ("peak performance", .peakPerformance), ("peak performance time (x10 s)", .peakPerformanceTime)] {
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
                                      angleSnapping: 0, rippleControl: 0, sensorMode: 0,
                                      peakPerformance: 1, peakTime: 6)
        let table: [(Int, UInt8, UInt8, UInt8)] = [(400, 0x80, 0x80, 0), (800, 0, 0xFF, 0), (1600, 0x80, 0, 0xFF),
                                                   (3200, 0xFF, 0x80, 0xFF), (6400, 0xFF, 0, 0), (26000, 0x80, 0, 0xFF)]
        m.stages = table.map { MouseDevice.Stage(dpi: DPIEntry(x: $0.0, y: $0.0), color: DPIColor(r: $0.1, g: $0.2, b: $0.3)) }
        m.keys = [.mouse(.left), .mouse(.right), .mouse(.middle), .mouse(.back), .mouse(.forward), .dpi(.loop)]
        m.battery = BatteryStatus(percent: 80, isCharging: false, millivolts: 4011)
        return m
    }
}
