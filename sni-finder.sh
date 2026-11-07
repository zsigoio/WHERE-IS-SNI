#!/usr/bin/env bash

set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

# Check and run the actual local toolchain without Go's automatic downloads.
export GOTOOLCHAIN=local
GO_RELEASE=go1.27.3
GO_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sni-finder/$GO_RELEASE"

go_is_supported() {
  local version
  version=$("$1" env GOVERSION 2>/dev/null) || return 1
  [[ "$version" =~ ^go([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || return 1
  (( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 25) ))
}

install_go() (
  local arch checksum work_dir
  if [[ "$(uname -s)" != Linux ]]; then
    echo "Install Go 1.25 or newer from https://go.dev/dl/ for this platform." >&2
    exit 1
  fi
  # SHA-256 checksums published at https://go.dev/dl/ for GO_RELEASE.
  case "$(uname -m)" in
    x86_64)
      arch=amd64
      checksum=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
      ;;
    aarch64|arm64)
      arch=arm64
      checksum=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
      ;;
    *)
      echo "Install Go 1.25 or newer from https://go.dev/dl/ for this architecture." >&2
      exit 1
      ;;
  esac
  for tool in curl tar sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Automatic Go installation requires $tool." >&2
      exit 1
    fi
  done

  mkdir -p -- "$(dirname -- "$GO_DIR")"
  work_dir=$(mktemp -d "${GO_DIR%/*}/.install.XXXXXXXX")
  trap 'rm -rf -- "$work_dir"' EXIT
  echo "Downloading $GO_RELEASE for Linux/$arch into the SNI finder cache..." >&2
  cd -- "$work_dir"
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 \
    "https://go.dev/dl/$GO_RELEASE.linux-$arch.tar.gz" -o go.tar.gz
  if ! printf '%s  go.tar.gz\n' "$checksum" | sha256sum --check --status; then
    echo "SHA-256 verification failed for $GO_RELEASE (Linux/$arch)." >&2
    exit 1
  fi
  tar -xzf go.tar.gz
  go_is_supported "$work_dir/go/bin/go"
  # Keep the first complete installation if two processes download at once.
  mv -nT -- "$work_dir/go" "$GO_DIR"
)

go_bin=$(command -v go || true)
if ! go_is_supported "$go_bin"; then
  go_bin="$GO_DIR/bin/go"
  if ! go_is_supported "$go_bin"; then
    previous_go="$HOME/.local/opt/sni-go/current/bin/go"
    if go_is_supported "$previous_go"; then
      go_bin="$previous_go"
    else
      install_go
      if ! go_is_supported "$go_bin"; then
        echo "The cached Go installation is unusable: $GO_DIR" >&2
        exit 1
      fi
    fi
  fi
fi

export SNI_FINDER_POOL="${SNI_FINDER_POOL:-$SCRIPT_DIR/domains.txt}"
if [[ ! -t 0 ]]; then
  set -- --no-menu "$@"
fi
exec "$go_bin" run "$SCRIPT_DIR/sni-finder.go" "$@"
