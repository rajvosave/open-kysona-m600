import Foundation
import IOKit.hid

/// Description of one HID interface/collection a physical device exposes.
/// A mouse usually exposes several (pointer, keyboard, vendor-defined), so the
/// app lists them all and picks the vendor one by heuristic or by user choice.
public struct HIDInterfaceInfo: Identifiable, Hashable {
    public let id: UInt64              // IORegistry entry ID
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let usagePage: Int
    public let usage: Int
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int

    /// Heuristic: an interface with a 17-byte (or 16 + report ID) output report.
    /// On the F5D5 dongle the control channel is a vendor collection (page 0xFF02,
    /// report ID 8) nested inside the pointer interface (page 1, usage 2), so the
    /// primary usage page cannot be required to be vendor-defined.
    public var looksLikeVendorChannel: Bool {
        maxOutputReportSize == Protocol.reportLength
            || maxOutputReportSize == Protocol.reportLength - 1
    }
}

public enum HIDTransportError: Error {
    case notOpen
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout
    /// The value is not one the setting is known to accept; nothing was sent.
    case valueRejected
}

/// Thin IOKit wrapper: discovery, open, output report write, input report stream.
public final class HIDTransport {
    private let manager: IOHIDManager
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var inputBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var openID: UInt64?

    /// Called on the main run loop whenever the interface list changes.
    public var onDevicesChanged: (() -> Void)?
    /// Called for every input report from the open interface (report ID included if the device uses one).
    public var onInputReport: (([UInt8]) -> Void)?

    public init(vendorID: Int = DeviceIdentifiers.vendorID,
                productIDs: [Int] = DeviceIdentifiers.allProductIDs) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = productIDs.map {
            [kIOHIDVendorIDKey as String: vendorID, kIOHIDProductIDKey as String: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    deinit { stop() }

    public func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Opening the manager without seizing the device keeps the pointer working.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        closeInterface()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public var interfaces: [HIDInterfaceInfo] {
        devices.compactMap { id, device in
            func int(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
            }
            return HIDInterfaceInfo(
                id: id,
                vendorID: int(kIOHIDVendorIDKey),
                productID: int(kIOHIDProductIDKey),
                product: (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown",
                usagePage: int(kIOHIDPrimaryUsagePageKey),
                usage: int(kIOHIDPrimaryUsageKey),
                maxInputReportSize: int(kIOHIDMaxInputReportSizeKey),
                maxOutputReportSize: int(kIOHIDMaxOutputReportSizeKey),
                maxFeatureReportSize: int(kIOHIDMaxFeatureReportSizeKey))
        }.sorted { $0.id < $1.id }
    }

    // MARK: open / close

    public func open(_ id: UInt64) throws {
        closeInterface()
        guard let device = devices[id] else { throw HIDTransportError.notOpen }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDTransportError.openFailed(result) }

        let size = max(64, (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        inputBuffers[id] = buffer
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().onInputReport?(bytes)
        }, context)
        openID = id
    }

    public func closeInterface() {
        guard let id = openID, let device = devices[id] else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffers[id]?.deallocate()
        inputBuffers[id] = nil
        openID = nil
    }

    // MARK: write

    /// Sends a 17-byte frame as an output report.
    /// `reportID` 0x08 with the full frame (leading 0x08 included) mirrors the Windows
    /// call. If hardware shows the interface has no report IDs, use reportID 0 and
    /// drop the leading byte instead.
    public func sendOutput(_ frame: [UInt8], reportID: UInt8 = Protocol.leadByte) throws {
        guard let id = openID, let device = devices[id] else { throw HIDTransportError.notOpen }
        let result = frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw HIDTransportError.writeFailed(result) }
    }

    // MARK: callbacks

    private func added(_ device: IOHIDDevice) {
        devices[registryID(device)] = device
        onDevicesChanged?()
    }

    private func removed(_ device: IOHIDDevice) {
        let id = registryID(device)
        if openID == id { closeInterface() }
        devices[id] = nil
        onDevicesChanged?()
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }
}
