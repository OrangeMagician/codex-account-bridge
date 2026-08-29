#!/bin/sh
set -eu

go_bin=${1:-go}
version=$($go_bin env GOVERSION)
numeric=${version#go}
old_ifs=$IFS
IFS=.
set -- $numeric
IFS=$old_ifs
major=${1:-0}
minor=${2:-0}
patch=${3:-0}

case "$major:$minor:$patch" in
  *[!0-9:]*|::*|*::*)
    printf 'a stable Go 1.26.7 or newer toolchain is required; found %s\n' "$version" >&2
    exit 1
    ;;
esac

if [ "$major" -gt 1 ] || [ "$major" -eq 1 ] && { [ "$minor" -gt 26 ] || [ "$minor" -eq 26 ] && [ "$patch" -ge 7 ]; }; then
  exit 0
fi

printf 'Go 1.26.7 or newer is required for security fixes; found %s\n' "$version" >&2
exit 1
