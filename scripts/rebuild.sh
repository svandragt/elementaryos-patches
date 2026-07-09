#!/bin/bash
# rebuild.sh — fetch latest source, re-apply patches, build and install
# Usage: ./rebuild.sh <package-name>|--all [--no-install] [--force]
#
# Per package: download the latest source and re-extract it PRISTINE
# (the unpacked tree is removed and re-created from the .dsc — quilt state
# or stray edits in $WORK_DIR/<package>-<version> are discarded), then
# re-apply the series patch by patch, auto-refresh any patch that applies
# with offsets/fuzz, re-bless VERIFIED, then build and install. A patch
# that fails outright skips the package; it's listed at the end for a
# manual 'ep refresh <package> --rebase'.
#
# The pristine re-extract matters: pushing patches onto a tree that
# already has them applied (with no .pc) can double-apply additive
# patches, and the fuzz auto-refresh would then corrupt the patch file.
#
# Skip logic: a successful rebuild+install stamps $WORK_DIR/.ep-built-<pkg>
# with the .dsc version and a hash of series+patches. The package is
# skipped while both are unchanged (a locally built .deb has the same
# version as the stock archive one, so the installed version can't tell
# us). --force rebuilds regardless; --no-install never writes the stamp.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/pkgs"
WORK_DIR="${WORK_DIR:-$HOME/src}"

TARGET="${1:-}"
shift || true
INSTALL="yes"
FORCE=""
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL="" ;;
        --force)      FORCE="yes" ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <package-name>|--all [--no-install] [--force]"
    exit 1
fi

# Hash of a package's patch series — part of the up-to-date stamp
patches_hash() {
    cat "$PATCHES_DIR/$1/series" "$PATCHES_DIR/$1"/*.patch 2>/dev/null | sha256sum | awk '{print $1}'
}

PACKAGES=()
if [[ "$TARGET" == "--all" ]]; then
    for d in "$PATCHES_DIR"/*/; do
        PACKAGES+=("$(basename "$d")")
    done
else
    if [[ ! -d "$PATCHES_DIR/$TARGET" ]]; then
        echo "Error: no patches directory found for '$TARGET'"
        exit 1
    fi
    PACKAGES=("$TARGET")
fi

mkdir -p "$WORK_DIR"

# Returns 0 on success, 1 when a patch needs manual rebasing, 2 on build failure
rebuild_one() {
    local PACKAGE="$1"

    echo ""
    echo "===== $PACKAGE ====="

    # Download the latest source files (cached in WORK_DIR, cheap if current)
    if ! (cd "$WORK_DIR" && apt source --download-only "$PACKAGE"); then
        echo "!!! apt source failed for $PACKAGE"
        return 1
    fi

    local DSC
    DSC=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE}_*.dsc" 2>/dev/null | sort -V | tail -1)
    if [[ -z "$DSC" ]]; then
        echo "!!! no .dsc found for $PACKAGE in $WORK_DIR"
        return 1
    fi

    local VERSION="${DSC##*_}"; VERSION="${VERSION%.dsc}"

    # Skip when this exact version + patch series was already built+installed
    local STAMP="$WORK_DIR/.ep-built-$PACKAGE"
    if [[ -z "$FORCE" && -f "$STAMP" ]] \
        && [[ "$(cat "$STAMP")" == "$VERSION $(patches_hash "$PACKAGE")" ]]; then
        echo "==> Up to date ($VERSION, patches unchanged) — skipping (--force to rebuild)"
        return 3
    fi

    # Re-extract pristine: never push patches onto an already-patched tree
    local UPSTREAM="${VERSION%-*}"; UPSTREAM="${UPSTREAM#*:}"
    local SOURCE_DIR="$WORK_DIR/${PACKAGE}-${UPSTREAM}"
    rm -rf "$SOURCE_DIR"
    if ! (cd "$WORK_DIR" && dpkg-source -x "$(basename "$DSC")"); then
        echo "!!! dpkg-source -x failed for $DSC"
        return 1
    fi
    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "!!! expected source directory not found: $SOURCE_DIR"
        return 1
    fi
    echo "==> Source: $SOURCE_DIR (pristine)"

    # Drop any quilt state dpkg-source left for debian/patches + our symlink
    rm -rf "$SOURCE_DIR/.pc"
    rm -f "$SOURCE_DIR/patches"
    ln -s "$PATCHES_DIR/$PACKAGE" "$SOURCE_DIR/patches"

    # Apply patch by patch, refreshing any that land with offsets/fuzz
    local SERIES="$PATCHES_DIR/$PACKAGE/series"
    local PATCH OUT REFRESHED=""
    while IFS= read -r PATCH || [[ -n "$PATCH" ]]; do
        [[ "$PATCH" =~ ^#.*$ || -z "$PATCH" ]] && continue
        echo "--- Applying: $PATCH"
        if ! OUT=$( (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" push) 2>&1 ); then
            echo "$OUT"
            echo "!!! Patch failed: $PATCH"
            echo "    Run: ./ep refresh $PACKAGE --rebase"
            return 1
        fi
        echo "$OUT"
        if grep -qE "offset|fuzz" <<<"$OUT"; then
            echo "==> Applied with offsets/fuzz — refreshing $PATCH"
            (cd "$SOURCE_DIR" && QUILT_PC="$SOURCE_DIR/.pc" QUILT_PATCHES="$SOURCE_DIR/patches" quilt --quiltrc "$REPO_DIR/quiltrc" refresh)
            REFRESHED="$REFRESHED $PATCH"
        fi
    done < "$SERIES"

    # Re-bless verified version
    local VERSION="${SOURCE_DIR##*/${PACKAGE}-}"
    echo "$VERSION" > "$PATCHES_DIR/$PACKAGE/VERIFIED"
    echo "==> Verified against $VERSION"
    if [[ -n "$REFRESHED" ]]; then
        echo "==> Refreshed:$REFRESHED — review and commit the changes in $PATCHES_DIR/$PACKAGE/"
    fi

    # Build (and install unless --no-install)
    if [[ -n "$INSTALL" ]]; then
        bash "$REPO_DIR/scripts/build.sh" "$PACKAGE" --install || return 2
        # Stamp so the next run skips this version+series (hash recomputed:
        # the apply step may have auto-refreshed patches)
        echo "$VERSION $(patches_hash "$PACKAGE")" > "$STAMP"
    else
        bash "$REPO_DIR/scripts/build.sh" "$PACKAGE" || return 2
    fi
    return 0
}

OK=()
SKIPPED=()
NEEDS_REBASE=()
BUILD_FAILED=()

for PACKAGE in "${PACKAGES[@]}"; do
    rc=0
    rebuild_one "$PACKAGE" || rc=$?
    case "$rc" in
        0) OK+=("$PACKAGE") ;;
        2) BUILD_FAILED+=("$PACKAGE") ;;
        3) SKIPPED+=("$PACKAGE") ;;
        *) NEEDS_REBASE+=("$PACKAGE") ;;
    esac
done

echo ""
echo "===== Summary ====="
if [[ ${#OK[@]} -gt 0 ]]; then
    echo "Rebuilt: ${OK[*]}"
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "Up to date: ${SKIPPED[*]}"
fi
if [[ ${#BUILD_FAILED[@]} -gt 0 ]]; then
    echo "Build failed: ${BUILD_FAILED[*]}"
fi
if [[ ${#NEEDS_REBASE[@]} -gt 0 ]]; then
    echo "Needs manual rebase (ep refresh <package> --rebase): ${NEEDS_REBASE[*]}"
fi

[[ ${#BUILD_FAILED[@]} -eq 0 && ${#NEEDS_REBASE[@]} -eq 0 ]]
