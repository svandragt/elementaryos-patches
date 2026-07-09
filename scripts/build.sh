#!/bin/bash
# build.sh — build a patched package and optionally install it
# Usage: ./build.sh <package-name> [--install]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/src}"

PACKAGE="${1:-}"
INSTALL="${2:-}"

if [[ -z "$PACKAGE" ]]; then
    echo "Usage: $0 <package-name> [--install]"
    exit 1
fi

SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Error: source directory not found for $PACKAGE in $WORK_DIR"
    echo "Run: ./scripts/apply.sh $PACKAGE"
    exit 1
fi

# Make sure all patches are applied
echo "==> Ensuring all patches are applied..."
(cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" push -a) 2>/dev/null || true

echo "==> Installing build dependencies..."
sudo apt build-dep "$PACKAGE" -y

echo "==> Building..."
cd "$SOURCE_DIR"
dpkg-buildpackage -us -uc -b -j"$(nproc)"

echo ""
echo "==> Build complete. Packages:"
find "$WORK_DIR" -maxdepth 1 -name "*.deb" | sort

if [[ "$INSTALL" == "--install" ]]; then
    echo "==> Installing..."
    DEBS=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE}_*.deb" | sort)
    if [[ -z "$DEBS" ]]; then
        echo "Warning: no .deb found matching $PACKAGE"
    else
        sudo dpkg -i $DEBS
        echo "==> Installed."
    fi
fi
