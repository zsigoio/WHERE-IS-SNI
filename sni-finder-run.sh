#!/usr/bin/env bash

set -e

REPO="zsigoio/WHERE-IS-SNI"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

# Detect where to save
TARGET_DIR="${SNI_FINDER_DIR:-.}"
mkdir -p "$TARGET_DIR"

echo "Downloading sni-finder.sh and domains.txt from $REPO..."

curl -sL "$BASE_URL/sni-finder.sh" -o "$TARGET_DIR/sni-finder.sh"
curl -sL "$BASE_URL/domains.txt" -o "$TARGET_DIR/domains.txt"

chmod +x "$TARGET_DIR/sni-finder.sh"

echo "Done. Running sni-finder.sh $*"
echo "---"
exec bash "$TARGET_DIR/sni-finder.sh" "$@"
