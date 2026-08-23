#!/bin/sh
set -eu

version=${1:-dev}
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_root/dist"

mkdir -p "$dist_dir"
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64; do
  os=${target%/*}
  arch=${target#*/}
  output="$dist_dir/cab_${version}_${os}_${arch}"
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=$version" \
    -o "$output" "$project_root/cmd/cab"
  shasum -a 256 "$output" > "$output.sha256"
done

