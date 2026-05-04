#!/bin/bash
# new-patch.sh — create a new patch for a package
# Usage: ./new-patch.sh <package-name> <patch-description>
# Example: ./new-patch.sh io.elementary.files "fix crash on empty drives"

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/src}"

PACKAGE="${1:-}"
DESCRIPTION="${2:-}"

if [[ -z "$PACKAGE" || -z "$DESCRIPTION" ]]; then
    echo "Usage: $0 <package-name> <patch-description>"
    echo "Example: $0 io.elementary.files \"fix crash on empty drives\""
    exit 1
fi

SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: no source directory found for '$PACKAGE' in $WORK_DIR"
    echo "Run: ./_scripts/apply.sh $PACKAGE"
    exit 1
fi

# Generate a sequential patch name
PATCHES_DIR="$REPO_DIR/$PACKAGE"
SERIES_FILE="$PATCHES_DIR/series"

# Count existing patches to get next number
EXISTING=$(grep -c '\.patch$' "$SERIES_FILE" 2>/dev/null || echo 0)
NEXT=$(printf "%04d" $((EXISTING + 1)))

# Slugify description
SLUG=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
PATCH_NAME="${NEXT}-${SLUG}.patch"

echo "==> Creating patch: $PATCH_NAME"
(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" new "$PATCH_NAME")

echo ""
echo "==> Patch created. Now tell quilt which files you'll edit:"
echo "    cd $SOURCE_DIR"
echo "    QUILT_PATCHES=patches quilt add <file-to-edit>"
echo "    (edit the file)"
echo "    QUILT_PATCHES=patches quilt refresh"
echo "    QUILT_PATCHES=patches quilt header -e   # optional: add a description"
echo ""
echo "Or run: ./_scripts/edit.sh $PACKAGE <file-to-edit>"
