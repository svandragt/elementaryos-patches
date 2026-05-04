#!/bin/bash
# apply.sh — fetch upstream source and apply all patches for a package
# Usage: ./apply.sh <package-name> [source-dir]
# Example: ./apply.sh io.elementary.files
#          ./apply.sh io.elementary.files ~/src/io.elementary.files-6.3.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$REPO_DIR"
WORK_DIR="${2:-$HOME/src}"

PACKAGE="${1:-}"
if [[ -z "$PACKAGE" ]]; then
    echo "Usage: $0 <package-name> [work-dir]"
    echo ""
    echo "Available packages:"
    for d in "$REPO_DIR"/*/; do
        name="$(basename "$d")"
        [[ "$name" == _* ]] && continue
        [[ "$name" == .* ]] && continue
        echo "  $name"
    done
    exit 1
fi

if [[ ! -d "$PATCHES_DIR/$PACKAGE" ]]; then
    echo "Error: no patches directory found for '$PACKAGE'"
    echo "Expected: $PATCHES_DIR/$PACKAGE"
    exit 1
fi

mkdir -p "$WORK_DIR"

# Find or fetch source
SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)

if [[ -z "$SOURCE_DIR" ]]; then
    echo "==> Fetching source for $PACKAGE..."
    cd "$WORK_DIR"
    apt source "$PACKAGE"
    SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" | sort -V | tail -1)
fi

echo "==> Source directory: $SOURCE_DIR"

# Remove any existing .pc state and patches symlink
rm -rf "$SOURCE_DIR/.pc"
rm -f "$SOURCE_DIR/patches"

# Symlink our patches in
ln -s "$PATCHES_DIR/$PACKAGE" "$SOURCE_DIR/patches"
echo "==> Linked patches: $PATCHES_DIR/$PACKAGE -> $SOURCE_DIR/patches"

# Apply
echo "==> Applying patches..."
QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" -d "$SOURCE_DIR" push -a

echo ""
echo "==> All patches applied to $SOURCE_DIR"
echo "    To build: cd $SOURCE_DIR && dpkg-buildpackage -us -uc -b"
