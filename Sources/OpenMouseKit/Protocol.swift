import Foundation

/// Wire format, derived from static analysis of the Windows HID library.
/// See PROTOCOL_NOTES.md. All of it is unverified on hardware.
public enum Protocol {
    /// Total report length including the leading 0x08 byte and the checksum.
    public static let reportLength = 17
    /// Constant first byte of every command. May be the HID report ID.
    public static let leadByte: UInt8 = 0x08
    public static let checksumSeed: UInt8 = 0x55
    /// The vendor library never reads more than 10 flash bytes per packet.
    public static let maxFlashChunk = 10

    /// `(0x55 - sum(bytes)) & 0xFF`, used for outgoing frames and reply fields.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        checksumSeed &- bytes.reduce(0 as UInt8) { $0 &+ $1 }
    }

    public enum Command: UInt8 {
        case flashWrite = 0x07
        case flashRead = 0x08
        case setCurrentConfig = 0x0F
        case readVersion = 0x12
        case readBattery = 0x04
    }

    /// Builds a 17-byte frame: `08 <cmd> <params, zero padded to 14> <checksum>`.
    public static func frame(_ command: Command, params: [UInt8] = []) -> [UInt8] {
        precondition(params.count <= reportLength - 3, "too many parameters")
        var payload: [UInt8] = [leadByte, command.rawValue] + params
        payload += [UInt8](repeating: 0, count: (reportLength - 1) - payload.count)
        return payload + [checksum(payload)]
    }

    /// One flash read packet. `count` must be 1...10.
    public static func flashRead(address: UInt16, count: UInt8) -> [UInt8] {
        precondition((1...UInt8(maxFlashChunk)).contains(count), "count out of range")
        // Byte 2 is always 0, the address is big-endian in bytes 3...4, byte 5 the count
        // (confirmed by a USB capture of the vendor app and by hardware).
        return frame(.flashRead, params: [0x00, UInt8(address >> 8), UInt8(address & 0xFF), count])
    }

    /// One flash write packet (`08 07 00 hi lo count data... chk`), as sent by the vendor
    /// app (USB capture). The device answers with an identical copy. Nothing in the app
    /// or `MouseDevice` sends these yet.
    public static func flashWrite(address: UInt16, data: [UInt8]) -> [UInt8] {
        precondition((1...10).contains(data.count), "count out of range")
        return frame(.flashWrite, params: [0x00, UInt8(address >> 8), UInt8(address & 0xFF), UInt8(data.count)] + data)
    }

    /// A one-byte setting is stored as `value, 0x55 - value` (two bytes).
    public static func writeValue(address: UInt16, value: UInt8) -> [UInt8] {
        flashWrite(address: address, data: [value, checksum([value])])
    }

    /// Colour of one DPI stage: `R G B chk` at `StageTable.colorAddress`. This is the only
    /// multi-byte write the app sends; the address range is fixed to the six colour entries.
    public static func setStageColor(stage: Int, color: DPIColor) -> [UInt8] {
        precondition((0..<StageTable.stageCount).contains(stage), "stage out of range")
        let rgb = [color.r, color.g, color.b]
        return flashWrite(address: StageTable.colorAddress(stage: stage), data: rgb + [checksum(rgb)])
    }

    /// Report rate write: 2 bytes at 0x0000, the one-hot value then its checksum.
    public static func setReportRate(_ value: UInt8) -> [UInt8] {
        writeValue(address: 0x0000, value: value)
    }

    /// Read a value/checksum pair; the value is reply byte 6, its checksum byte 7.
    public static func readValuePair(address: UInt16) -> [UInt8] {
        flashRead(address: address, count: 2)
    }

    /// The value of a pair reply, nil if its checksum fails.
    public static func valuePair(from reply: [UInt8]) -> UInt8? {
        guard reply.count == reportLength, reply[7] == checksum([reply[6]]) else { return nil }
        return reply[6]
    }

    /// App settings stored as value/checksum pairs. Addresses and meanings come from the vendor
    /// app's writes with a screen recording of what was toggled (all 1 = on / 2 mm).
    public enum Setting: UInt16 {
        case reportRate = 0x0000       // one-hot, see `ReportRate`
        case currentDPIIndex = 0x0004  // 0...5, the active DPI stage
        case lod = 0x000A              // 1 = 1 mm, 2 = 2 mm
        case motionSync = 0x00AB       // 1 = on
        case angleSnapping = 0x00AF    // 1 = on
        case rippleControl = 0x00B1    // 1 = on
        /// 0 = LP (read back as 00). The app sent 01 (HP) while the mouse was asleep, got no
        /// acknowledgement and reverted, so 01 = HP is unconfirmed.
        case sensorMode = 0x00B9

        /// Values the vendor app was seen to write (or that are valid for the control).
        /// Sensor mode is never accepted: its HP value is unconfirmed.
        public func accepts(_ value: UInt8) -> Bool {
            switch self {
            case .reportRate: return ReportRate(rawValue: value) != nil
            case .currentDPIIndex: return Int(value) < StageTable.stageCount
            case .lod: return (1...2).contains(value)
            case .motionSync, .angleSnapping, .rippleControl: return value <= 1
            case .sensorMode: return false
            }
        }
    }

    /// Splits a longer read into packets of at most 10 bytes, advancing the
    /// address by 10 each time, like the vendor library does.
    public static func flashReadFrames(address: UInt16, length: Int) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var addr = Int(address)
        var remaining = length
        while remaining > 0 {
            let n = min(remaining, maxFlashChunk)
            frames.append(flashRead(address: UInt16(addr), count: UInt8(n)))
            addr += n
            remaining -= n
        }
        return frames
    }

    /// Current DPI index: a one-byte flash read at 0x0004. The reply data is at byte 6.
    public static func readCurrentDPI() -> [UInt8] {
        flashRead(address: 0x0004, count: 1)
    }

    /// The settings block at flash address 0: five value/checksum pairs.
    public static func readSettingsBlock() -> [UInt8] {
        flashRead(address: 0x0000, count: 10)
    }

    /// True when `reply` answers `request`: valid checksum, same command, and for
    /// flash reads and writes the same echoed address and count.
    public static func isReply(_ reply: [UInt8], to request: [UInt8]) -> Bool {
        guard reply.count == reportLength, request.count == reportLength,
              reply[0] == leadByte, reply[1] == request[1],
              reply[16] == checksum(reply[0..<16]) else { return false }
        if request[1] == Command.flashRead.rawValue || request[1] == Command.flashWrite.rawValue {
            return Array(reply[2...5]) == Array(request[2...5])
        }
        return true
    }

    public static func readBattery() -> [UInt8] {
        frame(.readBattery)
    }

    public static func readVersion() -> [UInt8] {
        frame(.readVersion)
    }

    /// Params are `00 00 00 01 <value>` (bytes 2...6 of the frame).
    public static func setCurrentConfig(_ value: UInt8) -> [UInt8] {
        frame(.setCurrentConfig, params: [0x00, 0x00, 0x00, 0x01, value])
    }
}

/// Lets code outside the module name the setting without `Protocol`, which clashes
/// with the Objective-C runtime's `Protocol` type.
public typealias MouseSetting = Protocol.Setting
