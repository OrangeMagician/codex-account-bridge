#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT/macos/CABDesktop"
OUTPUT="$ROOT/dist/CodexAccountBridge.app"
EXECUTABLE="$PACKAGE/.build/release/CABDesktop"
ICON_SOURCE="$PACKAGE/Resources/AppIcon.png"
VERSION=${1:-0.0.0}
BUILD_NUMBER=${2:-0}

case "$VERSION" in
  *[!0-9.]*|''|.*|*.|*..*)
    printf 'invalid macOS app version: %s\n' "$VERSION" >&2
    exit 2
    ;;
esac
case "$BUILD_NUMBER" in
  ''|*[!0-9]*)
    printf 'invalid macOS build number: %s\n' "$BUILD_NUMBER" >&2
    exit 2
    ;;
esac

swift build -c release --package-path "$PACKAGE"
if [ -e "$OUTPUT" ]; then
    rm -rf -- "$OUTPUT"
fi
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
install -m 0755 "$EXECUTABLE" "$OUTPUT/Contents/MacOS/CABDesktop"
ditto "$PACKAGE/Resources" "$OUTPUT/Contents/Resources"

ICON_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cab-icon.XXXXXX")
trap 'rm -rf "$ICON_TEMP"' EXIT HUP INT TERM
ICONSET="$ICON_TEMP/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$OUTPUT/Contents/Resources/AppIcon.icns"

PLIST="$OUTPUT/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDisplayName -string "CodexAccountBridge" "$PLIST"
plutil -insert CFBundleExecutable -string "CABDesktop" "$PLIST"
plutil -insert CFBundleIdentifier -string "com.orangemagician.codex-account-bridge.desktop" "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$PLIST"
plutil -insert CFBundleName -string "CodexAccountBridge" "$PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string "en" "$PLIST"
plutil -insert CFBundleLocalizations -json '["en","zh-Hans"]' "$PLIST"
plutil -insert LSMinimumSystemVersion -string "13.0" "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
codesign --force --deep --sign - "$OUTPUT"

printf 'built %s\n' "$OUTPUT"
