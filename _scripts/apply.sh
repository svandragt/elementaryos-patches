#!/bin/bash
# apply.sh — fetch upstream source and apply all patches for a package
# Usage: ./apply.sh <package-name> [source-dir]
# Example: ./apply.sh io.elementary.files
#          ./apply.sh io.elementary.files ~/src/io.elementary.files-6.3.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Fetch latest source files (cached in WORK_DIR, cheap if current)
echo "==> Fetching source for $PACKAGE..."
(cd "$WORK_DIR" && apt source --download-only "$PACKAGE")

DSC=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE}_*.dsc" 2>/dev/null | sort -V | tail -1)
if [[ -z "$DSC" ]]; then
    echo "Error: no .dsc found for $PACKAGE in $WORK_DIR"
    exit 1
fi

# Re-extract pristine: pushing onto an already-patched tree (with no .pc)
# can double-apply additive patches. Discards any edits in the old tree.
VERSION="${DSC##*_}"; VERSION="${VERSION%.dsc}"
UPSTREAM="${VERSION%-*}"; UPSTREAM="${UPSTREAM#*:}"
SOURCE_DIR="$WORK_DIR/${PACKAGE}-${UPSTREAM}"
if [[ -d "$SOURCE_DIR" ]]; then
    echo "==> Removing existing tree for pristine re-extract: $SOURCE_DIR"
    rm -rf "$SOURCE_DIR"
fi
(cd "$WORK_DIR" && dpkg-source -x "$(basename "$DSC")")

echo "==> Source directory: $SOURCE_DIR (pristine)"

# Verified-against version check
CURRENT_VERSION="${SOURCE_DIR##*/${PACKAGE}-}"
VERIFIED_FILE="$PATCHES_DIR/$PACKAGE/VERIFIED"
if [[ -f "$VERIFIED_FILE" ]]; then
    VERIFIED_VERSION="$(head -n1 "$VERIFIED_FILE" | tr -d '[:space:]')"
    if [[ "$VERIFIED_VERSION" != "$CURRENT_VERSION" ]]; then
        echo "==> WARNING: patches last verified against $VERIFIED_VERSION, applying against $CURRENT_VERSION"
        echo "    Review the result and run 'ep refresh $PACKAGE --rebase' to re-bless."
    else
        echo "==> Verified against $VERIFIED_VERSION"
    fi
else
    echo "==> No VERIFIED file yet for $PACKAGE (run 'ep refresh' to record $CURRENT_VERSION)"
fi

# Remove any existing .pc state and patches symlink
rm -rf "$SOURCE_DIR/.pc"
rm -f "$SOURCE_DIR/patches"

# Symlink our patches in
ln -s "$PATCHES_DIR/$PACKAGE" "$SOURCE_DIR/patches"
echo "==> Linked patches: $PATCHES_DIR/$PACKAGE -> $SOURCE_DIR/patches"

# Apply
echo "==> Applying patches..."
(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" push -a)

echo ""
echo "==> All patches applied to $SOURCE_DIR"
echo "    To build: cd $SOURCE_DIR && dpkg-buildpackage -us -uc -b"
