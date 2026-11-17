#!/bin/bash
# Builds HubWatch, installs it to ~/Applications, and starts it at every login.
# Undo with: bash install.sh --remove
set -e
cd "$(dirname "$0")"
DEST="$HOME/Applications/HubWatch.app"
PLIST="$HOME/Library/LaunchAgents/local.hubwatch.plist"
LABEL="gui/$(id -u)/local.hubwatch"

launchctl bootout "$LABEL" 2>/dev/null || true
pkill -x HubWatch 2>/dev/null || true

if [ "$1" = "--remove" ]; then
  rm -f "$PLIST"
  echo "Removed login item. App left at $DEST"
  exit 0
fi

bash build.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R HubWatch.app "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.hubwatch</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string><string>-a</string><string>$DEST</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $DEST and set it to open at login."
