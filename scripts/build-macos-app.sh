#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT/macos/CABDesktop"
OUTPUT="$ROOT/dist/CAB Desktop.app"
EXECUTABLE="$PACKAGE/.build/release/CABDesktop"

swift build -c release --package-path "$PACKAGE"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
install -m 0755 "$EXECUTABLE" "$OUTPUT/Contents/MacOS/CABDesktop"

PLIST="$OUTPUT/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDisplayName -string "CAB Desktop" "$PLIST"
plutil -insert CFBundleExecutable -string "CABDesktop" "$PLIST"
plutil -insert CFBundleIdentifier -string "com.orangemagician.codex-account-bridge.desktop" "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$PLIST"
plutil -insert CFBundleName -string "CAB Desktop" "$PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$PLIST"
plutil -insert CFBundleShortVersionString -string "0.2.0" "$PLIST"
plutil -insert CFBundleVersion -string "1" "$PLIST"
plutil -insert LSMinimumSystemVersion -string "13.0" "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
codesign --force --deep --sign - "$OUTPUT"

printf 'built %s\n' "$OUTPUT"
