#!/bin/sh
set -eu

version=${1:-dev}
case "$version" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'invalid build version: %s\n' "$version" >&2
    exit 2
    ;;
esac

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_bin=${GO:-go}
"$project_root/scripts/check-go-version.sh" "$go_bin"
mkdir -p "$project_root/bin"
"$go_bin" build -trimpath -ldflags "-s -w -X main.version=$version" -o "$project_root/bin/cab" "$project_root/cmd/cab"
