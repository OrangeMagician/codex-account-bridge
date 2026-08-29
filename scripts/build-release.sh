#!/bin/sh
set -eu

version=${1:-dev}
case "$version" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'invalid release version: %s\n' "$version" >&2
    exit 2
    ;;
esac
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_root/dist"
go_bin=${GO:-go}

"$project_root/scripts/check-go-version.sh" "$go_bin"

mkdir -p "$dist_dir"
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64; do
  os=${target%/*}
  arch=${target#*/}
  output="$dist_dir/cab_${version}_${os}_${arch}"
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 "$go_bin" build -trimpath \
    -ldflags "-s -w -X main.version=$version" \
    -o "$output" "$project_root/cmd/cab"
  output_name=$(basename "$output")
  (cd "$dist_dir" && shasum -a 256 "$output_name" > "$output_name.sha256")
done
