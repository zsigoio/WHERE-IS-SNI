#!/usr/bin/env bash

set -e

REPO="zsigoio/WHERE-IS-SNI"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
TARGET_DIR="${SNI_FINDER_DIR:-.}"
mkdir -p -- "$TARGET_DIR"

DOWNLOAD_DIR="$(mktemp -d "$TARGET_DIR/.sni-download.XXXXXXXX")"
trap 'rm -f -- "$DOWNLOAD_DIR/sni-finder.sh" "$DOWNLOAD_DIR/sni-finder.go" "$DOWNLOAD_DIR/domains.txt"; rmdir -- "$DOWNLOAD_DIR"' EXIT

echo "Downloading SNI finder from $REPO..." >&2
for file in sni-finder.sh sni-finder.go domains.txt; do
  curl -fsSL "$BASE_URL/$file" -o "$DOWNLOAD_DIR/$file"
done
chmod +x "$DOWNLOAD_DIR/sni-finder.sh"
for file in sni-finder.go domains.txt sni-finder.sh; do
  mv -- "$DOWNLOAD_DIR/$file" "$TARGET_DIR/$file"
done

rmdir -- "$DOWNLOAD_DIR"
trap - EXIT

# In curl | bash, stdin carries the launcher. Give the menu the terminal.
if [[ ! -t 0 && -t 2 ]] && { exec 3</dev/tty; } 2>/dev/null; then
  exec bash "$TARGET_DIR/sni-finder.sh" "$@" <&3 3<&-
fi
exec bash "$TARGET_DIR/sni-finder.sh" "$@"
