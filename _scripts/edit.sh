#!/bin/bash
# edit.sh — add a file to the current patch and open it in $EDITOR
# Usage: ./edit.sh <package-name> <file-relative-to-source-root>
# Example: ./edit.sh io.elementary.files src/View/Miller.vala

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/src}"
EDITOR="${EDITOR:-nano}"

PACKAGE="${1:-}"
FILE="${2:-}"

if [[ -z "$PACKAGE" || -z "$FILE" ]]; then
    echo "Usage: $0 <package-name> <file-relative-to-source-root>"
    exit 1
fi

SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: source directory not found for $PACKAGE in $WORK_DIR"
    exit 1
fi

(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" add "$FILE")
"$EDITOR" "$SOURCE_DIR/$FILE"

echo ""
echo "==> When done editing, run:"
echo "    ./_scripts/refresh.sh $PACKAGE"
