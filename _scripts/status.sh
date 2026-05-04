#!/bin/bash
# status.sh — show patch status for all packages
# Usage: ./status.sh [package-name]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/src}"

show_package() {
    local PACKAGE="$1"
    local PATCHES_DIR="$REPO_DIR/$PACKAGE"
    local SERIES="$PATCHES_DIR/series"

    echo "=== $PACKAGE ==="

    if [[ ! -f "$SERIES" ]]; then
        echo "  (no series file)"
        return
    fi

    local COUNT
    COUNT=$(grep -c '\.patch$' "$SERIES" 2>/dev/null || echo 0)
    echo "  Patches: $COUNT"

    SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
    if [[ -n "$SOURCE_DIR" ]]; then
        echo "  Source:  $(basename "$SOURCE_DIR")"
        APPLIED=$(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" applied 2>/dev/null | wc -l || echo "?")
        echo "  Applied: $APPLIED / $COUNT"
    else
        echo "  Source:  (not fetched)"
    fi

    echo "  Patch list:"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        echo "    - $line"
    done < "$SERIES"
    echo ""
}

FILTER="${1:-}"

for d in "$REPO_DIR"/*/; do
    name="$(basename "$d")"
    [[ "$name" == _* ]] && continue
    [[ "$name" == .* ]] && continue
    if [[ -n "$FILTER" && "$name" != "$FILTER" ]]; then
        continue
    fi
    show_package "$name"
done
