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

source "$REPO_DIR/scripts/lib.sh"

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

TRACKED_DIR="$PATCHES_DIR/$PACKAGE"
LOCAL_DIR="$TRACKED_DIR/local"

if [[ "$MODE" == "--rebase" ]]; then
    echo "==> Popping all patches..."
    (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" pop -a) || true

    echo "==> Fetching new upstream source..."
    cd "$WORK_DIR"
    OLD_VERSION=$(basename "$SOURCE_DIR")
    apt source "$PACKAGE"
    NEW_SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" | sort -V | tail -1)

    if [[ "$NEW_SOURCE_DIR" == "$SOURCE_DIR" ]]; then
        echo "==> Source is already up to date ($OLD_VERSION)"
    else
        echo "==> New source: $NEW_SOURCE_DIR"
        SOURCE_DIR="$NEW_SOURCE_DIR"
    fi

    # Merged series (tracked + local/, if present) as one consistent quilt view
    sync_patches_dir "$SOURCE_DIR" "$TRACKED_DIR" "$LOCAL_DIR"

    echo "==> Re-applying patches one by one..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        PATCH="$line"
        echo ""
        echo "--- Applying: $PATCH"
        if ! (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" push); then
            echo ""
            echo "!!! Patch failed: $PATCH"
            echo "    Fix the .rej files in $SOURCE_DIR, then run:"
            echo "    QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches quilt --quiltrc $REPO_DIR/quiltrc refresh"
            echo "    Then re-run: ./scripts/refresh.sh $PACKAGE --rebase"
            exit 1
        fi
    done < "$SOURCE_DIR/patches/series"

    echo ""
    echo "==> All patches rebased successfully onto $(basename "$SOURCE_DIR")"

else
    # Simple refresh of top patch. quilt writes the refreshed diff through
    # the top patch's symlink in place, so it lands back in whichever real
    # directory (tracked or local/) it came from.
    echo "==> Refreshing top patch..."
    (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" refresh)
    echo "==> Done."
fi

# Record verified-against version. Stamped in both the tracked dir and
# local/ (if present) — cheap bookkeeping, no need to work out which one the
# just-refreshed patch actually belongs to.
VERSION="${SOURCE_DIR##*/${PACKAGE}-}"
echo "$VERSION" > "$TRACKED_DIR/VERIFIED"
[[ -f "$LOCAL_DIR/series" ]] && echo "$VERSION" > "$LOCAL_DIR/VERIFIED"
echo "==> Recorded verified version: $VERSION"
