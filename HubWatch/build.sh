#!/bin/bash
# Builds HubWatch.app next to this script.
set -e
cd "$(dirname "$0")"
APP=HubWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/HubWatch" HubWatch.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.hubwatch</string>
  <key>CFBundleName</key><string>HubWatch</string>
  <key>CFBundleExecutable</key><string>HubWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSLocationUsageDescription</key><string>HubWatch reads which Wi-Fi hub your Mac is connected to.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>HubWatch reads which Wi-Fi hub your Mac is connected to.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
