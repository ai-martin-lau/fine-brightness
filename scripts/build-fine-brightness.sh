#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/Fine Brightness.app"
LEGACY_APP_PATH="$ROOT_DIR/亮度细调.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/Fine Brightness"
BUILD_DIR="$ROOT_DIR/build/fine-brightness"

rm -rf "$APP_PATH"
rm -rf "$LEGACY_APP_PATH"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
mkdir -p "$BUILD_DIR"

cp "$ROOT_DIR/src/FineBrightness/Info.plist" "$APP_PATH/Contents/Info.plist"
cp -R "$ROOT_DIR/src/FineBrightness/en.lproj" "$ROOT_DIR/src/FineBrightness/zh-Hans.lproj" "$APP_PATH/Contents/Resources/"

xcrun swiftc \
  "$ROOT_DIR/src/FineBrightness/App.swift" \
  -target arm64-apple-macosx12.0 \
  -o "$BUILD_DIR/FineBrightness-arm64" \
  -F /System/Library/PrivateFrameworks \
  -framework Cocoa \
  -framework CoreGraphics \
  -framework DisplayServices

xcrun swiftc \
  "$ROOT_DIR/src/FineBrightness/App.swift" \
  -target x86_64-apple-macosx12.0 \
  -o "$BUILD_DIR/FineBrightness-x86_64" \
  -F /System/Library/PrivateFrameworks \
  -framework Cocoa \
  -framework CoreGraphics \
  -framework DisplayServices

lipo -create \
  "$BUILD_DIR/FineBrightness-arm64" \
  "$BUILD_DIR/FineBrightness-x86_64" \
  -output "$EXECUTABLE"

chmod +x "$EXECUTABLE"
codesign --force --sign - "$APP_PATH" >/dev/null

echo "$APP_PATH"
