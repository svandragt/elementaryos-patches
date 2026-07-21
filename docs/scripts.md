# `scripts/` implementation invariants

Every `scripts/*.sh` resolves the repo root via `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` — they live one level down, so the `..` is required. Don't drop it.

quilt on noble does **not** accept `-d <dir>` as a global flag. Always `cd "$SOURCE_DIR"` (in a subshell) before invoking `quilt`, and pass `QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches --quiltrc "$REPO_DIR/quiltrc"` so config and state are explicit.

Package directories live under `pkgs/` (`PATCHES_DIR="$REPO_DIR/pkgs"`), separate from tooling (`scripts/`, `crash-dashboard/`) and repo config (dotdirectories) at the top level. Discovery loops (`for d in "$PATCHES_DIR"/*/`) don't need to filter by name — everything under `pkgs/` is a package.

## Local, untracked patches

`pkgs/<package>/local/` is an optional second series directory, same shape as `pkgs/<package>/` (its own `series` + numbered `.patch` files), gitignored via `pkgs/*/local/`. It's for patches you want applied on your machine but never committed — WIP, or anything too speculative/personal for the tracked series.

quilt needs one consistent series/patches directory per invocation — it errors ("series file no longer matches the applied patches") if you swap `QUILT_PATCHES` between two directories mid-session, because it checks the current series against `.pc/applied-patches`. So there's no simple two-stage "push tracked, then repoint the symlink and push local" — `scripts/lib.sh`'s `sync_patches_dir` instead rebuilds `$SOURCE_DIR/patches` as one real directory holding a symlink per patch (tracked series first, then `local/series` if present) plus a merged `series` file, and every quilt-consuming script (`apply.sh`, `refresh.sh --rebase`, `rebuild.sh`) pushes that single merged view in one `push -a`/loop. Verified empirically that `quilt refresh` writes a refreshed patch through its symlink in place (not unlink+replace), so edits made via the merged view land back in whichever real directory — tracked or `local/` — a patch's symlink points to.

`new-patch.sh --local` names the new patch with a `local-` prefix (avoids colliding with a tracked patch's filename in the merged view), calls `sync_patches_dir` so quilt sees the full applied history as one consistent series, then `quilt new`. Since `quilt new` writes no real file content until the first refresh, `lib.sh`'s `commit_new_patch` makes sure the patch exists as a real file in its true home (`pkgs/<package>/` or `pkgs/<package>/local/`), appends it to that directory's own `series`, and leaves a symlink in the merged dir so `edit.sh`/`refresh.sh` right after it write straight through. `status.sh` and `rebuild.sh`'s up-to-date hash both fold `local/` in when present.
