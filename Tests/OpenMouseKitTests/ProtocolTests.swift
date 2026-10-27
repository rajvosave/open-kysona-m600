import XCTest
@testable import OpenMouseKit

final class ProtocolTests: XCTestCase {
    func testChecksumRule() {
        XCTAssertEqual(Protocol.checksum([UInt8]()), 0x55)
        XCTAssertEqual(Protocol.checksum([0x08, 0x12]), 0x3B)
    }

    func testReadVersionFrame() {
        // Vendor library pushes checksum 0x3B for this command.
        let f = Protocol.readVersion()
        XCTAssertEqual(f.count, 17)
        XCTAssertEqual(Array(f[0..<2]), [0x08, 0x12])
        XCTAssertEqual(f[16], 0x3B)
    }

    func testReadSettingsBlockFrame() {
        let f = Protocol.readSettingsBlock()
        XCTAssertEqual(Array(f[0..<6]), [0x08, 0x08, 0x00, 0x00, 0x00, 0x0A])
        XCTAssertEqual(f[16], 0x3B)
    }

    func testReadCurrentDPIFrame() {
        // Same bytes the vendor app sends (USB capture): 08 08 00 00 04 01 ... 40
        let f = Protocol.readCurrentDPI()
        XCTAssertEqual(Array(f[0..<6]), [0x08, 0x08, 0x00, 0x00, 0x04, 0x01])
        XCTAssertEqual(f[16], 0x40)
    }

    func testFlashAddressIsBigEndianInBytes3And4() {
        let f = Protocol.flashRead(address: 0x169F, count: 10)
        XCTAssertEqual(Array(f[2...5]), [0x00, 0x16, 0x9F, 0x0A])
    }

    // Captured from hardware (F5D5 dongle).
    let settingsReply: [UInt8] = [0x08, 0x08, 0x00, 0x00, 0x00, 0x0A,
                                  0x08, 0x4D, 0x06, 0x4F, 0x02, 0x53, 0x00, 0x55, 0x00, 0x55, 0x92]

    func testSettingsBlockParse() {
        XCTAssertEqual(SettingsBlock.parse(reply: settingsReply),
                       SettingsBlock(currentDPIIndex: 2, dpiStageCount: 6))
        var bad = settingsReply; bad[10] = 0x03   // value no longer matches checksum
        XCTAssertNil(SettingsBlock.parse(reply: bad))
    }

    func testReplyMatching() {
        let req = Protocol.readSettingsBlock()
        XCTAssertTrue(Protocol.isReply(settingsReply, to: req))
        XCTAssertFalse(Protocol.isReply(settingsReply, to: Protocol.readVersion()))
        var other = settingsReply; other[5] = 0x06; other[16] = Protocol.checksum(other[0..<16])
        XCTAssertFalse(Protocol.isReply(other, to: req))
        var corrupt = settingsReply; corrupt[16] ^= 0xFF
        XCTAssertFalse(Protocol.isReply(corrupt, to: req))
        let version: [UInt8] = [0x08, 0x12, 0, 0, 0, 0x02, 0x03, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0x26]
        XCTAssertTrue(Protocol.isReply(version, to: Protocol.readVersion()))
    }

    func testSetCurrentConfigChecksum() {
        // 0x55 - (0x18 + value)
        for v: UInt8 in [0, 1, 5] {
            XCTAssertEqual(Protocol.setCurrentConfig(v)[16], 0x55 &- (0x18 &+ v))
        }
    }

    func testFlashReadSplitsAtTen() {
        let frames = Protocol.flashReadFrames(address: 0x0100, length: 25)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map { $0[5] }, [10, 10, 5])
        XCTAssertEqual(frames.map { $0[3] }, [0x01, 0x01, 0x01])
        XCTAssertEqual(frames.map { $0[4] }, [0x00, 0x0A, 0x14])
    }

    func testParsersFallBackOnBadChecksum() {
        XCTAssertEqual(DPIColor.parse([1, 2, 3, 0]), .fallback)
        XCTAssertEqual(DPILed.parse([UInt8](repeating: 0, count: 8)), DPILed())
        XCTAssertEqual(LedBar.parse([UInt8](repeating: 0, count: 9)), LedBar())
    }

    func testDPIColorParse() {
        let rgb: [UInt8] = [0x10, 0x20, 0x30]
        XCTAssertEqual(DPIColor.parse(rgb + [Protocol.checksum(rgb)]),
                       DPIColor(r: 0x10, g: 0x20, b: 0x30))
    }

    // Captured from the vendor app's startup read; app showed 400/800/1600/3200/6400/26000.
    func testDPIEntriesMatchVendorAppList() {
        let entries: [[UInt8]] = [[0x07, 0x07, 0x00, 0x47], [0x0F, 0x0F, 0x00, 0x37],
                                  [0x1F, 0x1F, 0x00, 0x17], [0x3F, 0x3F, 0x00, 0xD7],
                                  [0x7F, 0x7F, 0x00, 0x57], [0x07, 0x07, 0x88, 0xBF]]
        XCTAssertEqual(entries.compactMap { DPIEntry.parse($0)?.x }, [400, 800, 1600, 3200, 6400, 26000])
        XCTAssertEqual(DPIEntry.parse(entries[5])?.y, 26000)
        XCTAssertNil(DPIEntry.parse([0x07, 0x07, 0x00, 0x00]))
    }

    func testStageAddressesAndColorWrites() {
        XCTAssertEqual((0..<6).map { StageTable.colorAddress(stage: $0) }, [0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40])
        XCTAssertEqual(StageTable.dpiAddress(stage: 5), 0x20)
        // Colour writes seen in the capture: stage 2 -> 80 00 FF d6
        XCTAssertEqual(DPIColor.parse([0x80, 0x00, 0xFF, 0xD6]), DPIColor(r: 0x80, g: 0x00, b: 0xFF))
    }

    func testReportRateCodes() {
        // Values read after presses of the mouse's rate button, in capture order.
        XCTAssertEqual([0x08, 0x04, 0x02, 0x01].compactMap { ReportRate.parse(valueByte: $0)?.hertz },
                       [125, 250, 500, 1000])
        XCTAssertNil(ReportRate.parse(valueByte: 0x03))
        XCTAssertNil(ReportRate.parse(valueByte: 0xFF))
    }

    // The four writes the vendor app sent when the rate was clicked 1000 -> 125 -> 250 -> 500 -> 1000.
    func testReportRateWritesMatchCapture() {
        let captured: [(UInt8, [UInt8])] = [
            (0x08, [0x08, 0x07, 0x00, 0x00, 0x00, 0x02, 0x08, 0x4D, 0, 0, 0, 0, 0, 0, 0, 0, 0xEF]),
            (0x04, [0x08, 0x07, 0x00, 0x00, 0x00, 0x02, 0x04, 0x51, 0, 0, 0, 0, 0, 0, 0, 0, 0xEF]),
            (0x02, [0x08, 0x07, 0x00, 0x00, 0x00, 0x02, 0x02, 0x53, 0, 0, 0, 0, 0, 0, 0, 0, 0xEF]),
            (0x01, [0x08, 0x07, 0x00, 0x00, 0x00, 0x02, 0x01, 0x54, 0, 0, 0, 0, 0, 0, 0, 0, 0xEF])]
        for (value, frame) in captured { XCTAssertEqual(Protocol.setReportRate(value), frame) }
    }

    // Writes the vendor app sent while the user toggled settings (recording clock: LOD 2 mm at
    // 13:37:58, ripple on 13:38:17, angle snapping on 13:38:25, motion sync off 13:38:33).
    func testSettingWritesMatchCapture() {
        func tail(_ f: [UInt8]) -> [UInt8] { [f[3], f[4], f[5], f[6], f[7], f[16]] }
        XCTAssertEqual(tail(Protocol.writeValue(address: Protocol.Setting.lod.rawValue, value: 2)),
                       [0x00, 0x0A, 0x02, 0x02, 0x53, 0xE5])
        XCTAssertEqual(tail(Protocol.writeValue(address: Protocol.Setting.rippleControl.rawValue, value: 1)),
                       [0x00, 0xB1, 0x02, 0x01, 0x54, 0x3E])
        XCTAssertEqual(tail(Protocol.writeValue(address: Protocol.Setting.angleSnapping.rawValue, value: 1)),
                       [0x00, 0xAF, 0x02, 0x01, 0x54, 0x40])
        XCTAssertEqual(tail(Protocol.writeValue(address: Protocol.Setting.motionSync.rawValue, value: 0)),
                       [0x00, 0xAB, 0x02, 0x00, 0x55, 0x44])
    }

    func testValuePairReply() {
        // Read at 0xAB returned 01 54 in the capture (motion sync on).
        var r = [UInt8](repeating: 0, count: 17)
        r[0] = 0x08; r[1] = 0x08; r[4] = 0xAB; r[5] = 0x02; r[6] = 0x01; r[7] = 0x54
        r[16] = Protocol.checksum(r[0..<16])
        XCTAssertEqual(Protocol.valuePair(from: r), 1)
        r[7] = 0x00
        XCTAssertNil(Protocol.valuePair(from: r))
    }

    func testWriteEchoCountsAsReply() {
        let w = Protocol.writeValue(address: 0x00B1, value: 1)
        XCTAssertTrue(Protocol.isReply(w, to: w))
        var other = Protocol.writeValue(address: 0x00AF, value: 1)
        XCTAssertFalse(Protocol.isReply(other, to: w))
        other = w; other[5] = 0x01; other[16] = Protocol.checksum(other[0..<16])
        XCTAssertFalse(Protocol.isReply(other, to: w))
    }

    func testSettingValueValidation() {
        XCTAssertTrue(MouseSetting.reportRate.accepts(0x04))
        XCTAssertFalse(MouseSetting.reportRate.accepts(0x03))
        XCTAssertTrue(MouseSetting.currentDPIIndex.accepts(5))
        XCTAssertFalse(MouseSetting.currentDPIIndex.accepts(6))
        XCTAssertTrue(MouseSetting.lod.accepts(2))
        XCTAssertFalse(MouseSetting.lod.accepts(0))
        XCTAssertFalse(MouseSetting.rippleControl.accepts(2))
        XCTAssertFalse(MouseSetting.sensorMode.accepts(0))
    }

    func testDPIStageWriteMatchesCapture() {
        // The app's "select stage 4" write: 08 07 00 00 04 02 03 52 ... eb
        let f = Protocol.writeValue(address: MouseSetting.currentDPIIndex.rawValue, value: 3)
        XCTAssertEqual(Array(f[0..<8]), [0x08, 0x07, 0x00, 0x00, 0x04, 0x02, 0x03, 0x52])
        XCTAssertEqual(f[16], 0xEB)
    }
}
