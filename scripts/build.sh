#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ChatGPTLimitsBar"
BUILD_DIR="$REPO_DIR/build"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
RESOURCES_DIR="$BUNDLE_DIR/Contents/Resources"

echo "🔨 Building $APP_NAME..."

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

ARCH=$(uname -m)
echo "📦 Target Architecture: $ARCH (macOS 12.0+)"

swiftc -O -target "${ARCH}-apple-macos12.0" \
    "$REPO_DIR/src/main.swift" \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa

cp "$REPO_DIR/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

if [ -f "$REPO_DIR/assets/AppIcon.icns" ]; then
    cp "$REPO_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/"
fi

echo "✅ Build succeeded: $BUNDLE_DIR"
