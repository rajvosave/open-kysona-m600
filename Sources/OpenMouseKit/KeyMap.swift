import Foundation

/// What a mouse button does. The simple cases can be written; shortcut, macro and anything
/// not understood are read-only and kept as raw bytes so they can be shown but not changed.
public enum KeyFunction: Equatable {
    public enum MouseButton: UInt8, CaseIterable {
        case left = 0x01, right = 0x02, middle = 0x04, back = 0x08, forward = 0x10
    }
    public enum DPIAction: UInt8, CaseIterable { case loop = 1, up = 2, down = 3 }
    public enum Scroll: UInt8, CaseIterable { case left = 1, right = 2 }

    case disabled
    case mouse(MouseButton)
    case dpi(DPIAction)
    case horizontalScroll(Scroll)
    case reportRate
    case profile
    /// Raw type and parameters of functions this app does not edit (fire, shortcut, macro,
    /// DPI lock, or an unknown type).
    case other(type: UInt8, param1: UInt8, param2: UInt8)

    public var bytes: (type: UInt8, param1: UInt8, param2: UInt8) {
        switch self {
        case .disabled: return (0, 0, 0)
        case .mouse(let b): return (1, b.rawValue, 0)
        case .dpi(let a): return (2, a.rawValue, 0)
        case .horizontalScroll(let s): return (3, s.rawValue, 0)
        case .reportRate: return (7, 0, 0)
        case .profile: return (9, 0, 0)
        case .other(let t, let p1, let p2): return (t, p1, p2)
        }
    }

    public static func decode(type: UInt8, param1: UInt8, param2: UInt8) -> KeyFunction {
        switch (type, param1, param2) {
        case (0, 0, 0): return .disabled
        case (1, let p, 0): return MouseButton(rawValue: p).map(KeyFunction.mouse) ?? .other(type: type, param1: p, param2: 0)
        case (2, let p, 0): return DPIAction(rawValue: p).map(KeyFunction.dpi) ?? .other(type: type, param1: p, param2: 0)
        case (3, let p, 0): return Scroll(rawValue: p).map(KeyFunction.horizontalScroll) ?? .other(type: type, param1: p, param2: 0)
        case (7, 0, 0): return .reportRate
        case (9, 0, 0): return .profile
        default: return .other(type: type, param1: param1, param2: param2)
        }
    }

    /// True for the functions this app can write.
    public var isEditable: Bool {
        if case .other = self { return false }
        return true
    }

    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .mouse(let b):
            switch b {
            case .left: return "Left click"
            case .right: return "Right click"
            case .middle: return "Middle click"
            case .back: return "Back"
            case .forward: return "Forward"
            }
        case .dpi(let a):
            switch a {
            case .loop: return "DPI cycle"
            case .up: return "DPI up"
            case .down: return "DPI down"
            }
        case .horizontalScroll(let s): return s == .left ? "Scroll left" : "Scroll right"
        case .reportRate: return "Report rate switch"
        case .profile: return "Profile switch"
        case .other(let t, let p1, let p2):
            switch t {
            case 4: return "Fire key"
            case 5: return "Shortcut"
            case 6: return "Macro"
            case 10: return "DPI lock"
            default: return String(format: "Type %02X %02X %02X", t, p1, p2)
            }
        }
    }

    /// The functions offered in a picker.
    public static let choices: [KeyFunction] =
        MouseButton.allCases.map(KeyFunction.mouse)
        + DPIAction.allCases.map(KeyFunction.dpi)
        + Scroll.allCases.map(KeyFunction.horizontalScroll)
        + [.reportRate, .profile, .disabled]
}

/// The button table in flash: 16 slots of `type param1 param2 chk` from 0x60 (confirmed by a dump
/// of the mouse; 0x5C..0x5F holds two unrelated value/checksum pairs).
public enum KeyMap {
    public static let slotCount = 16
    public static let baseAddress: UInt16 = 0x60
    /// Slots of the six physical buttons: left, right, middle, back, forward, DPI. Slots 6 and 7
    /// are disabled on the test mouse and the ones after hold DPI/report-rate functions with no
    /// button identified, so only these can be written.
    public static let physicalSlots = 0..<6
    public static func address(slot: Int) -> UInt16 { baseAddress + UInt16(4 * slot) }

    /// A slot entry, nil if its checksum fails.
    public static func parse(_ entry: [UInt8]) -> KeyFunction? {
        guard ReplyField.isValid(entry, values: 0..<3, checksumAt: 3) else { return nil }
        return KeyFunction.decode(type: entry[0], param1: entry[1], param2: entry[2])
    }

    public static func entry(for function: KeyFunction) -> [UInt8] {
        let b = function.bytes
        let v = [b.type, b.param1, b.param2]
        return v + [Protocol.checksum(v)]
    }
}

extension Protocol {
    /// One button slot write. Only the editable functions can be built.
    public static func setKeyFunction(slot: Int, _ function: KeyFunction) -> [UInt8] {
        precondition(KeyMap.physicalSlots.contains(slot), "slot is not a physical button")
        precondition(function.isEditable, "function is read-only")
        return flashWrite(address: KeyMap.address(slot: slot), data: KeyMap.entry(for: function))
    }
}
