# `scripts/` implementation invariants

Every `scripts/*.sh` resolves the repo root via `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` — they live one level down, so the `..` is required. Don't drop it.

quilt on noble does **not** accept `-d <dir>` as a global flag. Always `cd "$SOURCE_DIR"` (in a subshell) before invoking `quilt`, and pass `QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches --quiltrc "$REPO_DIR/quiltrc"` so config and state are explicit.

Package directories live under `pkgs/` (`PATCHES_DIR="$REPO_DIR/pkgs"`), separate from tooling (`scripts/`, `crash-dashboard/`) and repo config (dotdirectories) at the top level. Discovery loops (`for d in "$PATCHES_DIR"/*/`) don't need to filter by name — everything under `pkgs/` is a package.

## Local, untracked patches

`pkgs/<package>/local/` is an optional second series directory, same shape as `pkgs/<package>/` (its own `series` + numbered `.patch` files), gitignored via `pkgs/*/local/`. It's for patches you want applied on your machine but never committed — WIP, or anything too speculative/personal for the tracked series.

`apply.sh`, `refresh.sh --rebase`, and `rebuild.sh` all push the tracked series first, then `local/series` on top, onto the *same* `.pc` state — quilt tracks applied patches by filename, so re-pointing the `patches` symlink between the two stages doesn't disturb what's already applied. `new-patch.sh --local` (and by extension `edit.sh`/`refresh.sh` right after it) point the symlink at `local/` instead, so `quilt new`/`quilt refresh` write through to the untracked directory. `status.sh` and `rebuild.sh`'s up-to-date hash both fold `local/` in when present.
