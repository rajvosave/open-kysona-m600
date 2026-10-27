# OpenMouse: macOS companion app design

Clean-room Mac replacement for a Windows mouse configuration tool. Written from interface notes (`PROTOCOL_NOTES.md`), not from vendor code or assets. The UI and code here are original.

## Layout

```
Package.swift
Sources/OpenMouseKit/      protocol + transport, no UI
  DeviceIdentifiers.swift  VID 0x3554, PIDs F57D (mouse), F57C/F57E/F512/F5D5 (dongles)
  Protocol.swift           17-byte frame builder, checksum, flash-read splitting
  Parsers.swift            DPI colour, DPI LED, LED bar reply fields
  HIDTransport.swift       IOHIDManager discovery, open, SetReport, input callback
  MouseDevice.swift        send frame, await next input report, raw results
Sources/OpenMouseApp/      SwiftUI shell (device list, diagnostics, hex log)
Tests/OpenMouseKitTests/   frame and checksum vectors from the decompiled code
```

## Status

Written without a Swift toolchain (this machine is Windows). It has not been compiled or run. Expect small build fixes on first `swift build` on a Mac.

Everything in `Protocol.swift` and `Parsers.swift` comes from static analysis only.

## Layers

1. **Transport.** Lists every matching HID interface with usage page, usage and report sizes. The app auto-selects a vendor-defined interface whose output report size is 17 (or 16 plus a report ID) and lets the user override.
2. **Protocol.** Pure functions with unit tests, no IOKit.
3. **Device.** One request in flight at a time. Returns raw replies for now.
4. **UI.** Today: interface list, Open, Read version, Read DPI, hex traffic log. Later: DPI stages, button remap, LED, polling rate, battery, macros.

## Open questions (all need hardware)

| Question | How to settle it |
|---|---|
| Is the HID report ID 0x08, or does the interface have no report IDs? | Read the interface's report descriptor on the Mac (`ioreg -l -w0`, or the app's output sizes). Try `reportID` 0x08 with the full frame, then 0 without the lead byte. |
| Where does the data sit in a reply? | Capture Windows traffic with USBPcap/Wireshark while the vendor app reads settings, then diff against the Mac log. |
| Does the mouse and dongle use the same channel? | Compare the interface lists for PID F57D and the dongle PIDs. |
| What do DPI LED and LED bar fields mean? | Change one setting at a time in the Windows app and watch the flash bytes. |
| Flash map for DPI stages, key map, macros | Dump flash with `readFlashRaw`, change settings on Windows, diff. |
| Are the extra frames for report rate, battery, long-range mode needed? | Decompile the matching functions (not done yet). |

## Safety

- The only writes in the UI are six one-byte settings (report rate, DPI stage, LOD, motion sync, angle snapping, ripple control). Each is written only with a value `Setting.accepts` allows, checked against the mouse's echo and a read-back, and "Restore initial values" puts back what was read on open. Anything else (flash blocks, colours, remaps) stays unreachable. A bad flash write could leave the device misbehaving, and there is a firmware-update path in the vendor app that we deliberately do not implement.
- Do not implement `EnterUsbUpdateMode`, `EnterMTKMode`, `SetVidPid` or `SetDeviceDescriptorString` without a strong reason. They can brick or re-identify the hardware.

## macOS specifics

- Reading input reports from a mouse interface can trigger the **Input Monitoring** permission prompt. A packaged `.app` needs an `Info.plist` with a usage description; the bare SwiftPM executable may be blocked or prompt under the Terminal's identity.
- Don't seize the device (`kIOHIDOptionsTypeSeizeDevice`); that would stop the pointer working.
- For distribution: Xcode app target, hardened runtime, sign and notarize. The SwiftPM package is a development shell.

## Suggested order

1. Build and run on a Mac; confirm the interface list and which one is the control channel.
2. Send Read version, record the raw reply.
3. Capture the same exchange in Windows to align reply layouts.
4. Add typed decoding, then DPI read, then DPI write, with a test mouse profile as backup.
