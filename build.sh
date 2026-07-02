#!/bin/bash
# Builds FanWatch.app from the Swift package.
# Requirements: macOS 13+, Xcode command line tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

echo "Building (release)…"
swift build -c release

APP="FanWatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FanWatch "$APP/Contents/MacOS/FanWatch"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>FanWatch</string>
    <key>CFBundleDisplayName</key>       <string>FanWatch</string>
    <key>CFBundleIdentifier</key>        <string>local.fanwatch</string>
    <key>CFBundleExecutable</key>        <string>FanWatch</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper is happy on your own machine
codesign --force --deep --sign - "$APP"

echo
echo "Done → $(pwd)/$APP"
echo "Run it with:  open $APP"
