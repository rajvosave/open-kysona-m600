# KYSOAN mouse: protocol notes (static analysis, unverified on hardware)

Scope: interoperability notes for writing our own Mac driver. No vendor code or assets are to be copied. Everything below comes from static analysis of the installed files and is unverified on a real device.

## Files analysed

| File | Arch | SHA-256 | Notes |
|---|---|---|---|
| Mouse Drive Beta.exe | x86, .NET 4 IL-only | 234e8d89...9e67c | Main app. Embeds native DLLs via Costura |
| carved/HIDUsb_x64.dll | x64 | a64dab55...8021 | HID transport and device API, Ghidra 12.1.4 |
| carved/HIDUsb_x86.dll | x86 | 56C9ED1B...15A5 | 32-bit build of the same library (not analysed yet) |

## App structure (managed)
- Namespace `DriverLib`: `UsbFinder`, `UsbServer`, `UsbCommand`, `UsbCommandID`, `DataParser`, `MouseConfig`, `DPIConfig`, `LedBar`, `MacroKey`, `ShortCutKey`, `KeyFunMap`, `BatteryStatus`, `DeviceInfo`.
- Namespace `USBUpdateTool`: firmware upgrade flow.
- Config.ini: four models (M600, Aztec, M511, M600 V2), DPI table, 16 key slots, LED and battery parameters.

## Transport (from HIDUsb_x64.dll imports and strings)
- Enumerates HID interfaces with `HidD_GetHidGuid` and `SetupDi*`.
- Filters devices by VID/PID and by interface/collection (`vid_%ls&pid_%ls&mi_%02d&col%02d`).
- Opens the device with `CreateFileW`, then uses overlapped `ReadFile`/`WriteFile`.
- Reports are 17 bytes (`0x11`) on the wire, in both directions.
- Feature reports are also used (`HidD_SetFeature`, `HidD_GetAttributes`).
- A worker thread (`CS_UsbServer_Thread`) pulls 20-byte command records from a queue.

## Command record layout (inferred from `UsbServer_SetCurrentConfig`, `ReadVersion`)
The 20-byte record is built as follows:
- Bytes 0 to 7: `01 01 00 08 0F 00 00 00` for the config command (`0x0F080001 01`), or `01 01 00 08 12 00 00 00` for the version read.
- Bytes 8 to 15: `01 <param>` then zeros.
- Bytes 16 to 19: a checksum byte in the top position, computed as `(0x55 - (param + 0x18)) & 0xFF` for the config command.

The thread sends bytes 3 to 19 (17 bytes) with `WriteFile`. Bytes 0 to 2 are not transmitted.

Open questions:
- The exact report ID and the meaning of the first transmitted byte (0x08 in both cases) need device testing.
- The checksum formula is taken from one function only and needs checking against captured USB traffic.

## Exported command surface (CS_* and UsbServer_* functions)
Read: `ReadVersion`, `ReadConfig`, `ReadCurrentDPI` (calls `ReadFalshData(4,1,0)`), `ReadDPILed`, `ReadLedBar`, `ReadReportRate`, `ReadBatteryLevel`, `ReadOnLine`, `ReadCidMid`, `ReadAllFlashData`, `ReadEncryption`.
Write: `SetCurrentConfig`, `SetVidPid`, `SetDeviceDescriptorString`, `SetLongRangeMode`, `SetBatteryOptimize*`, `SetPCDriverStatus`, `Set4KDongleRGB`, `SetClearSetting`.
Mode: `EnterUsbUpdateMode`, `EnterMTKMode`, `EnterDonglePair*`, `Exit`.
Firmware upgrade: `CS_UsbUpgrade_Start`, `FileSplit`, `FindBootDevices`, with states for reset-to-boot, wait-boot, and download.

## Confirmed framing and checksum (second pass; supersedes the guesses above)

Checksum helper `FUN_18000c8c0(buf, start, end)` returns `(0x55 - sum(buf[start..end))) & 0xFF`. The same rule is used when sending and when validating replies.

On-wire output report (17 bytes, the queue record minus its 3 internal header bytes):

| Byte | Meaning |
|---|---|
| 0 | `0x08` (constant in all commands seen) |
| 1 | command: `0x08` = flash read, `0x0F` = set current config, `0x12` = read version |
| 2 | `0x00` (flash read) |
| 3..4 | flash address, big-endian (flash read) |
| 5 | byte count, at most 10 per packet (flash read) |
| 6..15 | zeros, or command parameters (set config: byte 5 = `0x01`, byte 6 = the config value) |
| 16 | checksum over bytes 0..15 of this frame |

**Correction from a USB capture of the vendor app (Windows, USBPcap) and Mac hardware tests:** the flash address is in bytes 3..4, not 2..3. Reads with the address one byte early return `0xFF` for every non-zero address. The vendor app sends 17-byte frames as USB `SET_REPORT` control transfers (`21 09 08 02 01 00 11 00`, report ID 8, interface 1) and gets replies on interrupt IN endpoint 0x82. Replies echo bytes 2..5 of the request, then data from byte 6, checksum last (all 162 captured replies verify).

Flash read `ReadFalshData(addr, len, mode)`: splits reads longer than 10 bytes into several packets and advances the address by 10 each time. `ReadCurrentDPI` is `ReadFalshData(0x0004, 1, 0)`, so the current DPI index lives at flash address 0x0004.

Replies are also 17 bytes. Parsed fields are stored as value bytes each followed by their own checksum byte.

## Reply parsers

- `BufferToDPIColor(buf)`: `R G B chk`. Checksum over bytes 0..2 sits at byte 3. On a bad checksum the colour defaults to `FF FF FF`.
- `BufferToDPILed(buf)`: four value/checksum pairs at bytes (0,1), (2,3), (4,5), (6,7). Defaults on a bad checksum: `0x02`, `0x80`, `0x03`, `0x01`. These look like mode, brightness, speed and on/off, but the meaning is a guess.
- `BufferToLedBar(buf)`: bytes 0..5 plus checksum at byte 6, then a separate value at byte 7 with checksum at byte 8. Defaults: `01 FF FF FF 08 09` and `01`. Likely mode, R, G, B, then two more parameters (brightness and speed, guessed), then an on/off flag.
- `BufferToMacroKey`, `BufferToShortcutKey`, `BufferToKeyFunMap` not decompiled yet.

Still unconfirmed: the HID report ID (the Windows API takes the first byte as the report ID, so byte 0 = `0x08` may be it), which HID interface and collection to use, and whether the "mode" argument of `ReadFalshData` is actually sent. All of this needs checking on hardware.

## Not done yet
- Ghidra decompile for `UsbServer_WriteCommand` and `InitWriteCommand`, to confirm report ID and framing.
- Decompile `ReadFalshData` and the DPI/LED data parsers (`DataParser`, `BufferToDPIColor`, `BufferToLedBar`).
- Analyse `UsbFile.dll` (the 558 KB x64 candidate `pe_00433BAB.bin` did not expose its exports as expected; check before relying on it).
- Check the x86 build for differences.
- Confirm everything on a real mouse with USB or HID traffic capture.

## Legal and clean-room notes
Keep this document as the spec. Write the Mac driver from it, with our own code and UI. Do not copy vendor code, strings, artwork or firmware.

## Capture findings (startup read plus button presses, unverified meanings marked)

Commands seen from the app: `01` (8 bytes of param, reply `58 aa da f8 22 04`), `02 01 01` (probably SetPCDriverStatus), `03` (reply `01 01 9a 31`), `04` (reply `50 00 0f b4`), `0E`, `12` (version, reply `02 03 10`), `17`, `08` flash read. No write commands appear in this capture.

Unsolicited mouse reports use command `0x0A`: byte 6 = 1 after the DPI button (the app then reads address 4, giving the DPI index 0...5), byte 6 = 2 after a second button (the app then reads address 0, which cycles 4, 2, 1, 8).

Flash 0x00..0xBF (value/checksum pairs; guesses): 0x02 = 6 (DPI stage count), 0x04 = current DPI index, 0x30..0x4B = RGB + checksum entries (red, green, blue, cyan, magenta...), probably per-stage DPI colours; 0x0C..0x27 = `v v 00 chk` entries with v = 07 0F 1F 3F 7F (growing bit patterns); 0x5C..0x73 one-hot 01 02 04 08 10 entries. Regions up to 0x19FF were read; everything beyond 0xBF came back 0xFF in this capture.

## Flash map from a hardware dump (Mac, F5D5 dongle, read-only)

Only 0x0000..0x00BF holds data. Everything from 0x00BE up to 0x01FF, and every address the vendor app probed from 0x200 to 0x19FF, reads 0xFF. Layout, with confidence:

| Address | Content | Confidence |
|---|---|---|
| 0x00..0x09 | value/checksum pairs; 0x02 = 6, 0x04 = current DPI index | index confirmed by button presses |
| 0x0C..0x2F | 8 entries of `x y hi chk`: `07 0F 1F 3F 7F` then `07 07 88` x3 and a zero entry | structure certain, meaning unknown. Doubling codes look like DPI register values (800, 1600, 3200, 6400, 12800 if value = (code+1)*100) |
| 0x30..0x4B | 7 RGB+checksum colours: red, green, blue, cyan, magenta x3 | structure certain, likely per-stage DPI colours |
| 0x4C..0x53 | `02 53 80 d5 03 52 00 55`: matches the DPI LED parser (defaults 02, 80, 03, 01), here mode 2, 0x80, 3, off | likely |
| 0x5C..0x9B | 16 slots of `type a b chk`: `01 01`, `01 02`, `01 04`, `01 08`, `01 10` (HID mouse button bitmask 1..5), then `02 01`, `07 00`, `02 02`, `02 03` | likely the button remap table (Config.ini has 16 key slots) |
| 0xA0..0xBD | mixed value/checksum pairs | unknown |

## Second capture: writes and polling (Windows app, F5D5 dongle)

Command `0x07` is a flash **write**: `08 07 00 <addr hi> <addr lo> <count> <data...> <chk>`, checksum rule as before. The device answers with an identical copy of the request. Observed writes (the user selected DPI stages 0..5 in turn and changed each stage's colour):

- `08 07 00 00 04 02 <idx> <0x55-idx>`: set current DPI index (2 bytes at 0x0004, value then checksum).
- `08 07 00 00 <a> 04 <R> <G> <B> <chk>` with a = 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40: colour of stage 0..5. So the colour table is `0x2C + 4 * stage`, `R G B chk`, and the 0x2C entry earlier read as `00 00 00 55`.

Polling: the app sends `03` and `04` about every 4 s. Reply to `03` was always `01 01 9a 31` (meaning unknown). Reply to `04` was `50 00 0f ab` or `0f b0`: probably battery (0x50 = 80 %, 0x0FAB = 4011 mV), unconfirmed.

The `0x0A` event with byte 6 = 1 is the DPI button; the app answers by reading 0x0004.

## Confirmed with the vendor app's screen recording (Kysona M600 V2)

- Stage DPI entry at `0x0C + 4 * stage`: `x_lo y_lo hi chk`, 10-bit codes, DPI = (code + 1) * 50. X's top bits are hi bits 3:2, Y's are hi bits 7:6. The app showed 400, 800, 1600, 3200, 6400, 26000 for `07`, `0F`, `1F`, `3F`, `7F`, `07 07 88`.
- Stage colour entry at `0x2C + 4 * stage`: `R G B chk`. Six colour writes in the capture match the app's final swatches exactly (olive, green, purple, pink, red, purple).
- App UI items still unmapped to flash: report rate (125/250/500/1000 Hz), LOD, sensor mode (LP), Ripple control, Angle snapping, Motion sync, Peak Performance.

## Polling-rate capture (mouse button, no app writes)

Four presses of the mouse's second button produced `0A` events with byte 6 = 2, and the app read address 0 each time: 08, 04, 02, 01 in turn (first capture saw 04, 02, 01, 08, 04, 02, 01). So flash 0x0000 is a one-hot report-rate selector that wraps 01 -> 08. Mapping confirmed by the user: 08 = 125 Hz, 04 = 250 Hz, 02 = 500 Hz, 01 = 1000 Hz (the app showed 1000 Hz when the byte was 01 in the earlier dump). No write appears, so the app-side "set report rate" command is still unseen.

## Report rate write (capture of the app's Report Rate button)

Each click sends a flash write: `08 07 00 00 00 02 <value> <0x55 - value>` + zeros + checksum (`ef`), answered by an identical echo. Sequence from the capture: 1000 -> 125 wrote 08, 125 -> 250 wrote 04, 250 -> 500 wrote 02, 500 -> 1000 wrote 01. The app's button cycles in that order. `Protocol.flashWrite` and `setReportRate` build these frames; no code sends them yet.

## App settings (capture + screen recording with a clock, 2026-10-27)

All are `value, 0x55 - value` pairs written with command `07` and echoed by the mouse. The clock on the recording (video 0 s = 13:37:36) lines up with the capture timestamps.

| Setting | Address | Evidence |
|---|---|---|
| LOD | 0x000A | 13:37:58 wrote 02 (dropdown 2 mm open at :56), 13:38:04 wrote 01. First flash dump read 01 here |
| Ripple control | 0x00B1 | 13:38:17 wrote 01 (hover tooltip at :16), 13:38:21 wrote 00 |
| Angle snapping | 0x00AF | 13:38:25 wrote 01 (screenshot :26 shows it on), 13:38:30 wrote 00 |
| Motion sync | 0x00AB | 13:38:33 wrote 00 (screenshot :36 shows it off), 13:38:37 wrote 01 |
| Sensor mode (LP/HP) | 0x00B9 | reads 00 with LP. The app wrote 01 eleven times, one per second (13:37:40..50) while it showed "Device Offline, please move mouse"; no echo came back and the UI went back to LP. HP = 01 is unconfirmed |

Peak Performance (greyed checkbox) was not exercised, so its address is unknown. Startup also sends `02 01 01`, `12`, `0E`, `17`, then reads 0x00A0..0x00BF (`be 02` last).

## Write path verified on hardware (2026-10-27)

The Mac app wrote ripple control (0x00B1) with `Protocol.writeValue`: the mouse echoed the frame, a read-back matched, and the vendor Windows app then showed the setting on. Turning it off in the Windows app was read back as 0 by the Mac app. So write frames, echo, checksum and the address/meaning of ripple control are confirmed in both directions.
