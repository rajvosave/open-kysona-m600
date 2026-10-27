import Foundation

/// Reply-field parsers. Each field is a run of value bytes followed by a
/// checksum byte over those values. A bad checksum falls back to defaults,
/// matching the vendor library's behaviour.
public enum ReplyField {
    static func isValid(_ b: [UInt8], values: Range<Int>, checksumAt: Int) -> Bool {
        guard checksumAt < b.count, values.upperBound <= b.count else { return false }
        return b[checksumAt] == Protocol.checksum(b[values])
    }
}

public struct DPIColor: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public static let fallback = DPIColor(r: 0xFF, g: 0xFF, b: 0xFF)

    /// `R G B <chk>`
    public static func parse(_ buf: [UInt8]) -> DPIColor {
        guard ReplyField.isValid(buf, values: 0..<3, checksumAt: 3) else { return .fallback }
        return DPIColor(r: buf[0], g: buf[1], b: buf[2])
    }
}

/// Four value/checksum pairs at (0,1) (2,3) (4,5) (6,7).
/// Field meaning is a guess: mode, brightness, speed, on/off.
public struct DPILed: Equatable {
    public var v0: UInt8 = 0x02
    public var v1: UInt8 = 0x80
    public var v2: UInt8 = 0x03
    public var v3: UInt8 = 0x01

    public static func parse(_ buf: [UInt8]) -> DPILed {
        var out = DPILed()
        if ReplyField.isValid(buf, values: 0..<1, checksumAt: 1) { out.v0 = buf[0] }
        if ReplyField.isValid(buf, values: 2..<3, checksumAt: 3) { out.v1 = buf[2] }
        if ReplyField.isValid(buf, values: 4..<5, checksumAt: 5) { out.v2 = buf[4] }
        if ReplyField.isValid(buf, values: 6..<7, checksumAt: 7) { out.v3 = buf[6] }
        return out
    }
}

/// Six bytes plus checksum at 6, then one value at 7 with checksum at 8.
/// Meaning is a guess: mode, R, G, B, brightness, speed, on/off.
public struct LedBar: Equatable {
    public var mode: UInt8 = 0x01
    public var r: UInt8 = 0xFF, g: UInt8 = 0xFF, b: UInt8 = 0xFF
    public var p4: UInt8 = 0x08
    public var p5: UInt8 = 0x09
    public var enabled: UInt8 = 0x01

    public static func parse(_ buf: [UInt8]) -> LedBar {
        var out = LedBar()
        if ReplyField.isValid(buf, values: 0..<6, checksumAt: 6) {
            out.mode = buf[0]
            out.r = buf[1]; out.g = buf[2]; out.b = buf[3]
            out.p4 = buf[4]; out.p5 = buf[5]
        }
        if ReplyField.isValid(buf, values: 7..<8, checksumAt: 8) { out.enabled = buf[7] }
        return out
    }
}

/// Reply to `Protocol.readSettingsBlock()`: data starts at reply byte 6, as
/// value/checksum pairs. Offset 4 follows the DPI button on hardware (0...5 while
/// cycling), offset 2 reads 6 (probably the number of DPI stages). Offsets 0, 6
/// and 8 are unidentified.
public struct SettingsBlock: Equatable {
    public var currentDPIIndex: UInt8
    public var dpiStageCount: UInt8

    public static func parse(reply: [UInt8]) -> SettingsBlock? {
        guard reply.count == Protocol.reportLength else { return nil }
        let data = Array(reply[6..<16])
        guard ReplyField.isValid(data, values: 2..<3, checksumAt: 3),
              ReplyField.isValid(data, values: 4..<5, checksumAt: 5) else { return nil }
        return SettingsBlock(currentDPIIndex: data[4], dpiStageCount: data[2])
    }
}

/// One DPI stage entry: `x_lo y_lo hi chk` at flash 0x0C + 4 * stage.
/// Each axis is a 10-bit code, DPI = (code + 1) * 50. X's top two bits are
/// hi bits 3:2, Y's are hi bits 7:6. Matches the vendor app's 400...26000 list
/// for codes 07 0F 1F 3F 7F and `07 07 88`.
public struct DPIEntry: Equatable {
    public var x: Int
    public var y: Int

    public static func parse(_ b: [UInt8]) -> DPIEntry? {
        guard b.count >= 4, ReplyField.isValid(b, values: 0..<3, checksumAt: 3) else { return nil }
        let xCode = Int(b[0]) | (Int(b[2] >> 2) & 3) << 8
        let yCode = Int(b[1]) | (Int(b[2] >> 6) & 3) << 8
        return DPIEntry(x: (xCode + 1) * 50, y: (yCode + 1) * 50)
    }
}

/// Stage addresses in flash (six stages on the M600 V2).
public enum StageTable {
    public static let stageCount = 6
    public static func dpiAddress(stage: Int) -> UInt16 { UInt16(0x0C + 4 * stage) }
    /// Colour entries are `R G B chk`; stage 0 is at 0x2C (confirmed by writes in a USB capture).
    public static func colorAddress(stage: Int) -> UInt16 { UInt16(0x2C + 4 * stage) }
}

/// Report rate at flash 0x0000: a one-hot byte (value, then checksum at 0x0001).
/// The mouse's own button cycles it 125 -> 250 -> 500 -> 1000 Hz and wraps.
public enum ReportRate: UInt8, CaseIterable {
    case hz1000 = 0x01, hz500 = 0x02, hz250 = 0x04, hz125 = 0x08

    public var hertz: Int {
        switch self {
        case .hz1000: return 1000
        case .hz500: return 500
        case .hz250: return 250
        case .hz125: return 125
        }
    }

    public static func parse(valueByte: UInt8) -> ReportRate? { ReportRate(rawValue: valueByte) }
}
