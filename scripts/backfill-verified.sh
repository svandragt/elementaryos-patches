#!/bin/bash
# backfill-verified.sh — one-shot: record VERIFIED for every package whose
# patches currently apply cleanly against the source apt ships today.
#
# Usage: ./scripts/backfill-verified.sh [package ...]
#   With no args: processes every package directory in the repo.
#   With args:    processes only the listed packages.
#
# For each package this runs `ep apply`; on success it writes the upstream
# version (parsed from the source dir name) into <package>/VERIFIED. Packages
# that fail to apply are listed at the end and left without a VERIFIED file.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/pkgs"
WORK_DIR="${WORK_DIR:-$HOME/src}"

if [[ $# -gt 0 ]]; then
    PACKAGES=("$@")
else
    PACKAGES=()
    for d in "$PATCHES_DIR"/*/; do
        PACKAGES+=("$(basename "$d")")
    done
fi

OK=()
FAIL=()

for PACKAGE in "${PACKAGES[@]}"; do
    echo ""
    echo "############################################"
    echo "# $PACKAGE"
    echo "############################################"

    # Start from clean upstream source — otherwise leftover patched files from
    # a prior run make quilt think patches are already applied.
    echo "==> Removing any existing source dirs for $PACKAGE..."
    find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" -exec rm -rf {} +

    if ! bash "$REPO_DIR/scripts/apply.sh" "$PACKAGE"; then
        echo "!!! apply failed for $PACKAGE — skipping"
        FAIL+=("$PACKAGE")
        continue
    fi

    SOURCE_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "${PACKAGE}-*" 2>/dev/null | sort -V | tail -1)
    if [[ -z "$SOURCE_DIR" ]]; then
        echo "!!! no source dir found for $PACKAGE after apply — skipping"
        FAIL+=("$PACKAGE")
        continue
    fi

    VERSION="${SOURCE_DIR##*/${PACKAGE}-}"
    echo "$VERSION" > "$PATCHES_DIR/$PACKAGE/VERIFIED"
    echo "==> Wrote $PACKAGE/VERIFIED: $VERSION"
    OK+=("$PACKAGE")
done

echo ""
echo "############################################"
echo "# Summary"
echo "############################################"
echo "Verified: ${#OK[@]}"
for p in "${OK[@]}"; do echo "  ok    $p"; done
if [[ ${#FAIL[@]} -gt 0 ]]; then
    echo "Failed: ${#FAIL[@]}"
    for p in "${FAIL[@]}"; do echo "  FAIL  $p"; done
    exit 1
fi
