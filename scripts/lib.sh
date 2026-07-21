#!/bin/bash
# lib.sh — shared helpers for merging a package's tracked + local patch series
# into the single directory quilt needs. Source, don't execute.

# sync_patches_dir SOURCE_DIR TRACKED_DIR LOCAL_DIR
#
# Rebuilds $SOURCE_DIR/patches as a real directory containing one symlink per
# patch (tracked series first, then local/series if present) plus a merged
# series file listing them in that order. Safe to call any time: the merged
# dir holds no state of its own, it's rebuilt from TRACKED_DIR/LOCAL_DIR (the
# real, persistent series+patch files) every time.
#
# quilt writes refreshed patches through a symlink in place (verified: it
# does not unlink+replace), so edits made via the merged dir land back in
# whichever real directory a patch's symlink points to.
sync_patches_dir() {
    local SOURCE_DIR="$1" TRACKED_DIR="$2" LOCAL_DIR="$3"
    local STAGE="$SOURCE_DIR/patches"

    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    : > "$STAGE/series"

    local dir line
    for dir in "$TRACKED_DIR" "$LOCAL_DIR"; do
        [[ -f "$dir/series" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^#.*$ ]] && continue
            ln -sf "$dir/$line" "$STAGE/$line"
            echo "$line" >> "$STAGE/series"
        done < "$dir/series"
    done
}

# commit_new_patch SOURCE_DIR TARGET_DIR PATCH_NAME
#
# 'quilt new' registers PATCH_NAME in the merged dir's series and .pc state,
# but writes no real content until the first 'quilt refresh' (it may leave a
# real placeholder file behind, or nothing at all, depending on quilt
# version). Either way: make sure PATCH_NAME exists as a real file in
# TARGET_DIR (pkgs/<package> or pkgs/<package>/local — its true, persistent
# home), record it in TARGET_DIR/series, and leave a symlink in the merged
# dir so later commands (quilt add, refresh) write straight through to it.
commit_new_patch() {
    local SOURCE_DIR="$1" TARGET_DIR="$2" PATCH_NAME="$3"
    local STAGED="$SOURCE_DIR/patches/$PATCH_NAME"
    mkdir -p "$TARGET_DIR"
    touch "$TARGET_DIR/series"
    if [[ -e "$STAGED" && ! -L "$STAGED" ]]; then
        mv "$STAGED" "$TARGET_DIR/$PATCH_NAME"
    else
        touch "$TARGET_DIR/$PATCH_NAME"
    fi
    echo "$PATCH_NAME" >> "$TARGET_DIR/series"
    ln -sf "$TARGET_DIR/$PATCH_NAME" "$STAGED"
}
