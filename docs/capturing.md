# Capturing the vendor app's traffic

Goal: record exactly what the vendor's Windows app sends when you change one setting, and note
what you did and when.

## Setup (Windows, once)

1. Install Wireshark and tick **USBPcap** in the installer. Reboot if asked.
2. Plug the mouse's dongle into the port you will keep using.
3. In Wireshark pick the **USBPcap** interface whose hub contains the dongle.
4. Turn on a screen recording with a **visible clock** (the Windows taskbar clock with seconds, or
   a clock widget). Keep the vendor app, Wireshark and the clock in view.

## Recording

1. Start the Wireshark capture, then open the vendor app and wait about 5 seconds.
2. Change **one** setting, press Apply if there is one, and wait 3 to 5 seconds. Write down the
   clock time and what you did, for example `13:38:17 ripple control on`.
3. Repeat for each setting. Change each one back afterwards, so the mouse ends as it started.
4. Stop the capture and save it as `.pcapng`.

Good first targets: a button remap, an LED mode or colour, one DPI stage's value, report rate,
sensor mode, Peak Performance.

## Avoid

Firmware update, factory reset, restore defaults and pairing. A capture only listens, but those
actions change the mouse.

## Share

Attach the `.pcapng`, your list of times and changes, and, if the file is small enough, the
recording or a few screenshots. Do not include anything personal: captures contain the HID traffic
of the selected USB hub, so pick the hub with only the dongle if you can.

## Reading a capture

The vendor app sends 17-byte output reports (report ID 8) as USB `SET_REPORT` control transfers
(`21 09 08 02 01 00 11 00`) and the mouse answers on an interrupt IN endpoint. See
`PROTOCOL_NOTES.md` for the frame layout and checksum.
