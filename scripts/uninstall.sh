#!/bin/bash
set -e

APP_NAME="ChatGPTLimitsBar"
DEST_APP="$HOME/Applications/$APP_NAME.app"
PLIST_FILE="$HOME/Library/LaunchAgents/com.gptlimitbar.menubar.plist"

echo "🗑 Uninstalling $APP_NAME..."

# 1. Terminate running process
killall "$APP_NAME" 2>/dev/null || true

# 2. Remove LaunchAgent
if [ -f "$PLIST_FILE" ]; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
    echo "Removed LaunchAgent: $PLIST_FILE"
fi

# 3. Remove application bundle
if [ -d "$DEST_APP" ]; then
    rm -rf "$DEST_APP"
    echo "Removed application: $DEST_APP"
fi

echo "✅ $APP_NAME has been completely uninstalled."
