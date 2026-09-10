#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexLImitBar"
TARGET_DIR="$HOME/Applications"
DEST_APP="$TARGET_DIR/$APP_NAME.app"

# 1. Build the application
"$REPO_DIR/scripts/build.sh"

# 2. Install to ~/Applications
mkdir -p "$TARGET_DIR"
echo "🚀 Installing to $DEST_APP..."

# Close existing instance if running (both new and legacy names)
killall "$APP_NAME" 2>/dev/null || true
killall "ChatGPTLimitsBar" 2>/dev/null || true
sleep 0.5

rm -rf "$DEST_APP"
cp -R "$REPO_DIR/build/$APP_NAME.app" "$DEST_APP"

# 3. Setup LaunchAgent (optional auto-start at login)
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/com.codexlimitbar.menubar.plist"
mkdir -p "$PLIST_DIR"

cat << PLIST > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.codexlimitbar.menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST

# Clean up legacy LaunchAgent plist if present
rm -f "$PLIST_DIR/com.emon.chatgptlimitsbar.plist"
rm -f "$PLIST_DIR/com.gptlimitbar.menubar.plist"

# 4. Launch app
echo "✨ Launching $APP_NAME..."
open -a "$DEST_APP"

echo ""
echo "🎉 CodexLImitBar installed successfully!"
echo "Check your top menu bar for: 5HL=... We=..."
