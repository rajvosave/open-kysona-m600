import Foundation

/// USB identifiers for the supported hardware family.
///
/// Source: the vendor config shipped with the Windows app (base64-encoded
/// strings that decode to a hex VID and PID lists). Unverified on hardware.
public enum DeviceIdentifiers {
    public static let vendorID = 0x3554

    /// Mouse PID.
    public static let mouseProductIDs = [0xF57D]

    /// Wireless dongle PIDs.
    public static let dongleProductIDs = [0xF57C, 0xF57E, 0xF512, 0xF5D5]

    public static var allProductIDs: [Int] { mouseProductIDs + dongleProductIDs }
}
