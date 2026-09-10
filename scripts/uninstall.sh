#!/bin/bash
set -e

APP_NAME="CodexLImitBar"
DEST_APP="$HOME/Applications/$APP_NAME.app"
PLIST_FILE="$HOME/Library/LaunchAgents/com.codexlimitbar.menubar.plist"

echo "🗑 Uninstalling $APP_NAME..."

# 1. Terminate running process
killall "$APP_NAME" 2>/dev/null || true
killall "ChatGPTLimitsBar" 2>/dev/null || true

# 2. Remove LaunchAgents (current and legacy)
for p in "$PLIST_FILE" "$HOME/Library/LaunchAgents/com.emon.chatgptlimitsbar.plist" "$HOME/Library/LaunchAgents/com.gptlimitbar.menubar.plist"; do
    if [ -f "$p" ]; then
        launchctl unload "$p" 2>/dev/null || true
        rm -f "$p"
        echo "Removed LaunchAgent: $p"
    fi
done

# 3. Remove application bundles
for app in "$DEST_APP" "$HOME/Applications/ChatGPTLimitsBar.app"; do
    if [ -d "$app" ]; then
        rm -rf "$app"
        echo "Removed application: $app"
    fi
done

echo "✅ $APP_NAME has been completely uninstalled."
