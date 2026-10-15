#!/bin/sh
# Package locally built binaries. Run make local-release first.
set -eu
version=${1:?usage: package-release.sh VERSION}
case "$version" in
  ''|*[!0-9.]*|.*|*.|*..*) printf 'invalid version\n' >&2; exit 2 ;;
esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist="$root/dist"
packages="$dist/release-$version"
mkdir -p "$packages"
staging=$(mktemp -d "${TMPDIR:-/tmp}/cab-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
for target in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
  mkdir -p "$staging/$target"
  install -m 0755 "$dist/cab_${version}_$target" "$staging/$target/cab"
  cp "$root/LICENSE" "$staging/$target/LICENSE"
  cp "$root/docs/INSTALL.txt" "$staging/$target/INSTALL.txt"
  tar -czf "$packages/cab_${version}_$target.tar.gz" -C "$staging/$target" cab LICENSE INSTALL.txt
done
app="$dist/CodexAccountBridge.app"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || { printf 'app version mismatch\n' >&2; exit 1; }
arch=$(lipo -archs "$app/Contents/MacOS/CABDesktop")
case "$arch" in arm64|x86_64) ;; *) printf 'unsupported app architecture: %s\n' "$arch" >&2; exit 1 ;; esac
codesign --verify --deep --strict "$app"
name="CodexAccountBridge_${version}_macos_$arch"
ditto -c -k --sequesterRsrc --keepParent "$app" "$packages/$name.zip"
mkdir -p "$staging/dmg"
ditto "$app" "$staging/dmg/CodexAccountBridge.app"
ln -s /Applications "$staging/dmg/Applications"
cp "$root/docs/INSTALL.txt" "$staging/dmg/INSTALL.txt"
hdiutil create -volname "CodexAccountBridge $version" -srcfolder "$staging/dmg" -ov -format UDZO "$packages/$name.dmg"
cp "$root/docs/INSTALL.txt" "$packages/INSTALL.txt"
(cd "$packages" && shasum -a 256 ./*.tar.gz ./*.zip ./*.dmg INSTALL.txt > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
printf 'Release assets: %s\n' "$packages"
