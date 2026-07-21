#!/bin/bash
# new-patch.sh — create a new patch for a package
# Usage: ./new-patch.sh <package-name> <patch-description> [--local]
# Example: ./new-patch.sh io.elementary.files "fix crash on empty drives"
#
# --local creates the patch under pkgs/<package>/local/ instead of
# pkgs/<package>/. That directory is gitignored: it's for patches you want
# applied locally (via 'ep apply') but never committed — e.g. work in
# progress, or changes too speculative/personal for the tracked series.
# 'ep apply' pushes the tracked series first, then local/ on top, as one
# merged quilt series (see scripts/lib.sh) — local patches are named with a
# "local-" prefix so they can't collide with a tracked patch's filename in
# that merged view.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/src}"

source "$REPO_DIR/scripts/lib.sh"

PACKAGE="${1:-}"
DESCRIPTION="${2:-}"
LOCAL=""
if [[ "${3:-}" == "--local" ]]; then
    LOCAL="yes"
fi

if [[ -z "$PACKAGE" || -z "$DESCRIPTION" ]]; then
    echo "Usage: $0 <package-name> <patch-description> [--local]"
    echo "Example: $0 io.elementary.files \"fix crash on empty drives\""
    exit 1
fi

SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: no source directory found for '$PACKAGE' in $WORK_DIR"
    echo "Run: ./scripts/apply.sh $PACKAGE"
    exit 1
fi

TRACKED_DIR="$REPO_DIR/pkgs/$PACKAGE"
LOCAL_DIR="$TRACKED_DIR/local"
if [[ -n "$LOCAL" ]]; then
    TARGET_DIR="$LOCAL_DIR"
    PREFIX="local-"
else
    TARGET_DIR="$TRACKED_DIR"
    PREFIX=""
fi

# Count existing patches in the series we're authoring into, to get the next number
SERIES_FILE="$TARGET_DIR/series"
EXISTING=$(grep -c '\.patch$' "$SERIES_FILE" 2>/dev/null) || EXISTING=0
NEXT=$(printf "%04d" $((EXISTING + 1)))

# Slugify description
SLUG=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
PATCH_NAME="${PREFIX}${NEXT}-${SLUG}.patch"

# Rebuild the merged patches dir so quilt sees the full applied history
# (tracked + local) as one consistent series, then create the new patch on
# top of it.
sync_patches_dir "$SOURCE_DIR" "$TRACKED_DIR" "$LOCAL_DIR"

echo "==> Creating patch: $PATCH_NAME${LOCAL:+ (local, untracked)}"
(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" new "$PATCH_NAME")

# 'quilt new' created a real file in the merged dir — move it into its real,
# persistent home and leave a symlink behind so later commands still find it
commit_new_patch "$SOURCE_DIR" "$TARGET_DIR" "$PATCH_NAME"

echo ""
echo "==> Patch created. Now tell quilt which files you'll edit:"
echo "    cd $SOURCE_DIR"
echo "    QUILT_PATCHES=patches quilt add <file-to-edit>"
echo "    (edit the file)"
echo "    QUILT_PATCHES=patches quilt refresh"
echo "    QUILT_PATCHES=patches quilt header -e   # optional: add a description"
echo ""
echo "Or run: ./scripts/edit.sh $PACKAGE <file-to-edit>"
