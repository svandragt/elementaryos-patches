#!/bin/bash
# refresh.sh — refresh the top patch, or rebase all patches after an upstream update
# Usage: ./refresh.sh <package-name> [--rebase]
#
# Without --rebase: refreshes the currently applied top patch (use while editing)
# With --rebase:    pops all patches, updates source, re-applies one by one so you
#                   can fix any that fail

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/pkgs"
WORK_DIR="${WORK_DIR:-$HOME/src}"

PACKAGE="${1:-}"
MODE="${2:-}"

if [[ -z "$PACKAGE" ]]; then
    echo "Usage: $0 <package-name> [--rebase]"
    exit 1
fi

SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: source directory not found for $PACKAGE in $WORK_DIR"
    exit 1
fi

Q="QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches quilt --quiltrc $REPO_DIR/quiltrc"

if [[ "$MODE" == "--rebase" ]]; then
    echo "==> Popping all patches..."
    (cd "$SOURCE_DIR" && eval "$Q pop -a") || true

    echo "==> Fetching new upstream source..."
    cd "$WORK_DIR"
    # Remove old source dir after backing up .pc state
    OLD_VERSION=$(basename "$SOURCE_DIR")
    apt source "$PACKAGE"
    NEW_SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" | sort -V | tail -1)

    if [[ "$NEW_SOURCE_DIR" == "$SOURCE_DIR" ]]; then
        echo "==> Source is already up to date ($OLD_VERSION)"
    else
        echo "==> New source: $NEW_SOURCE_DIR"
        SOURCE_DIR="$NEW_SOURCE_DIR"
        rm -f "$SOURCE_DIR/patches"
        ln -s "$PATCHES_DIR/$PACKAGE" "$SOURCE_DIR/patches"
    fi

    echo "==> Re-applying patches one by one..."
    SERIES="$PATCHES_DIR/$PACKAGE/series"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        PATCH="$line"
        echo ""
        echo "--- Applying: $PATCH"
        if ! (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" push); then
            echo ""
            echo "!!! Patch failed: $PATCH"
            echo "    Fix the .rej files in $SOURCE_DIR, then run:"
            echo "    QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches quilt --quiltrc $REPO_DIR/quiltrc refresh"
            echo "    Then re-run: ./_scripts/refresh.sh $PACKAGE --rebase"
            exit 1
        fi
    done < "$SERIES"

    echo ""
    echo "==> All patches rebased successfully onto $(basename $SOURCE_DIR)"

else
    # Simple refresh of top patch
    echo "==> Refreshing top patch..."
    (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" refresh)
    echo "==> Done. Patch updated in $PATCHES_DIR/$PACKAGE/"
fi

# Record verified-against version
VERSION="${SOURCE_DIR##*/${PACKAGE}-}"
echo "$VERSION" > "$PATCHES_DIR/$PACKAGE/VERIFIED"
echo "==> Recorded verified version: $VERSION"
