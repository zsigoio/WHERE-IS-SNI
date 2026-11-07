#!/usr/bin/env bash

set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
if ! command -v go >/dev/null 2>&1; then
  echo "sni-finder.sh requires Go 1.25 or newer." >&2
  exit 1
fi

export SNI_FINDER_POOL="${SNI_FINDER_POOL:-$SCRIPT_DIR/domains.txt}"
# Build with the local toolchain so the launcher works offline.
export GOTOOLCHAIN=local
exec go run "$SCRIPT_DIR/sni-finder.go" "$@"
