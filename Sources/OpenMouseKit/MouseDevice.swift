import Foundation

/// Request/response layer on top of `HIDTransport`.
///
/// The reply layout is not known yet, so every call returns the raw input
/// report. Typed decoding goes in once hardware captures confirm where the
/// data sits in a reply.
@MainActor
public final class MouseDevice {
    private let transport: HIDTransport
    private var pending: [UInt8]?
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var timeoutTask: Task<Void, Never>?

    /// Hex-friendly traffic log hook for the diagnostics view.
    public var onTraffic: ((Direction, [UInt8]) -> Void)?
    public enum Direction { case sent, received }
    /// Unsolicited report from the mouse (command 0x0A). Byte 6 is 1 after the DPI button and
    /// 2 after the report-rate button.
    public var onEvent: ((UInt8) -> Void)?

    public init(transport: HIDTransport) {
        self.transport = transport
        transport.onInputReport = { [weak self] report in
            Task { @MainActor in self?.receive(report) }
        }
    }

    private func receive(_ report: [UInt8]) {
        // The control collection shares its interface with pointer reports and the
        // mouse sends unsolicited ID 8 reports (e.g. on DPI button presses), so
        // only a report that answers the request in flight resolves it.
        guard report.first == Protocol.leadByte else { return }
        onTraffic?(.received, report)
        if report.count == Protocol.reportLength, report[1] == 0x0A { onEvent?(report[6]) }
        guard let request = pending, Protocol.isReply(report, to: request) else { return }
        pending = nil
        timeoutTask?.cancel()
        waiter?.resume(returning: report)
        waiter = nil
    }

    /// Sends a frame and waits for the next input report.
    public func exchange(_ frame: [UInt8], timeout: TimeInterval = 1.0) async throws -> [UInt8] {
        onTraffic?(.sent, frame)
        pending = frame
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.pending = nil
                self?.waiter?.resume(throwing: HIDTransportError.timeout)
                self?.waiter = nil
            }
            do { try transport.sendOutput(frame) } catch {
                timeoutTask?.cancel()
                pending = nil
                waiter = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func readVersionRaw() async throws -> [UInt8] {
        try await exchange(Protocol.readVersion())
    }

    /// Current DPI index (0...5 on the test mouse) from a one-byte read at 0x0004.
    public func readCurrentDPI() async throws -> UInt8 {
        try await exchange(Protocol.readCurrentDPI())[6]
    }

    public func readSettingsRaw() async throws -> [UInt8] {
        try await exchange(Protocol.readSettingsBlock())
    }

    /// Current DPI index and stage count, nil if the reply fails its checksums.
    public func readSettings() async throws -> SettingsBlock? {
        SettingsBlock.parse(reply: try await readSettingsRaw())
    }

    /// Report rate from a one-byte read at 0x0000, nil for a value that is not one-hot.
    public func readReportRate() async throws -> ReportRate? {
        ReportRate.parse(valueByte: try await exchange(Protocol.flashRead(address: 0x0000, count: 1))[6])
    }

    public func readBattery() async throws -> BatteryStatus? {
        BatteryStatus.parse(reply: try await exchange(Protocol.readBattery()))
    }

    /// A one-byte app setting (LOD, motion sync, ...), nil if the reply fails its checksum.
    public func readValue(_ setting: Protocol.Setting) async throws -> UInt8? {
        Protocol.valuePair(from: try await exchange(Protocol.readValuePair(address: setting.rawValue)))
    }

    /// Writes one setting and returns true if the mouse echoed the frame back unchanged,
    /// which is what the vendor app's writes got in the captures.
    public func writeValue(_ setting: Protocol.Setting, _ value: UInt8) async throws -> Bool {
        guard setting.accepts(value) else { throw HIDTransportError.valueRejected }
        let frame = Protocol.writeValue(address: setting.rawValue, value: value)
        return try await exchange(frame) == frame
    }

    /// Bytes of a flash range, from the data field of each reply.
    public func readFlash(address: UInt16, length: Int) async throws -> [UInt8] {
        try await readFlashRaw(address: address, length: length).flatMap { $0[6..<(6 + Int($0[5]))] }
    }

    public struct Stage: Equatable {
        public var dpi: DPIEntry?
        public var color: DPIColor
        public init(dpi: DPIEntry?, color: DPIColor) { self.dpi = dpi; self.color = color }
    }

    /// DPI and colour of every stage, read-only. Not yet checked against hardware.
    public func readStages() async throws -> [Stage] {
        let n = StageTable.stageCount
        let dpi = try await readFlash(address: StageTable.dpiAddress(stage: 0), length: 4 * n)
        let color = try await readFlash(address: StageTable.colorAddress(stage: 0), length: 4 * n)
        return (0..<n).map { i in
            Stage(dpi: DPIEntry.parse(Array(dpi[(4 * i)..<(4 * i + 4)])),
                  color: DPIColor.parse(Array(color[(4 * i)..<(4 * i + 4)])))
        }
    }

    /// Reads a flash range in 10-byte packets and returns each raw reply.
    public func readFlashRaw(address: UInt16, length: Int) async throws -> [[UInt8]] {
        var replies: [[UInt8]] = []
        for frame in Protocol.flashReadFrames(address: address, length: length) {
            replies.append(try await exchange(frame))
        }
        return replies
    }

    /// Writes the current config value. Do not expose in the UI until the
    /// read side is verified on hardware.
    public func setCurrentConfig(_ value: UInt8) async throws -> [UInt8] {
        try await exchange(Protocol.setCurrentConfig(value))
    }
}
