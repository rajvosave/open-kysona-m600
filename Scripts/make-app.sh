#!/bin/sh
# Builds OpenMouse.app in ./dist. Ad-hoc signed, not notarized: fine for running on the
# Mac that built it. Distributing to others needs a Developer ID signature and notarization.
set -eu
cd "$(dirname "$0")/.."

ARCHS="--arch arm64 --arch x86_64"   # universal: runs on Apple Silicon and Intel
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)/OpenMouse

APP=dist/OpenMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/OpenMouse"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenMouse</string>
    <key>CFBundleDisplayName</key><string>OpenMouse</string>
    <key>CFBundleIdentifier</key><string>io.github.rajvosave.openmouse</string>
    <key>CFBundleExecutable</key><string>OpenMouse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSInputMonitoringUsageDescription</key>
    <string>OpenMouse talks to your mouse's control channel to read and change its settings.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
