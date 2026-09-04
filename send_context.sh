#!/bin/bash
# Usage: send_context.sh <local_file> [dest_name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$1"
DEST="${2:-$(basename "$1")}"
DATE=$(date +%Y-%m-%d)

if [ ! -f "$SRC" ]; then
    echo "File not found: $SRC" >&2
    exit 1
fi

cp "$SRC" "$SCRIPT_DIR/context/${DATE}-${DEST}"
cd "$SCRIPT_DIR"
git add context/
git commit -m "context: ${DATE}-${DEST}"
git push origin main
echo "Pushed to: https://raw.githubusercontent.com/byomes/watson-review/main/context/${DATE}-${DEST}"
