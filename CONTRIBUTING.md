# Contributing

Thanks for helping. The most valuable contribution is **a capture of the vendor app changing one
setting**, because every new feature starts as a packet we have not decoded yet. Code, tests and
device reports are welcome too.

## Ground rules

- **No vendor material.** Do not paste or attach vendor code, decompiler output, strings, artwork
  or firmware. Describe behaviour in your own words and with the bytes on the wire. Packet
  captures of your own mouse are fine.
- **Evidence first.** A protocol claim needs either a capture, a recording matching it, or a
  hardware test. Mark anything inferred as unconfirmed, as `PROTOCOL_NOTES.md` does.
- **Writes stay narrow.** A setting only becomes writable with a known address, an allow-list of
  values (`Setting.accepts`), an echo check and a read-back. Do not add firmware update, boot-mode,
  device-ID or descriptor commands (`EnterUsbUpdateMode`, `EnterMTKMode`, `SetVidPid`,
  `SetDeviceDescriptorString`). They can brick the hardware.
- **Tests with real bytes.** Protocol additions need a unit test built from captured frames.

## Building

```sh
swift build
swift test
Scripts/make-app.sh      # optional: dist/OpenMouse.app
```

macOS 13+, Swift 5.9+. `OpenMouse --render-preview out.png` renders the main window with demo
values, which is handy for layout changes without a mouse.

## Making a capture

See [docs/capturing.md](docs/capturing.md). Short version: USBPcap and Wireshark on Windows, a
screen recording with a visible clock, one change per Apply with a few seconds between, and a text
list of what you changed and when. Put each change back afterwards.

## Reporting a different mouse or dongle

Open an issue with the "Device report" template. Include the USB vendor and product ID, what the
app shows, and which settings read back correctly.

## Pull requests

Keep changes small and focused, run `swift test`, and describe what evidence supports any new
protocol detail. By contributing you agree your work is released under the MIT licence.
