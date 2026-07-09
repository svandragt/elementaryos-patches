# `scripts/` implementation invariants

Every `scripts/*.sh` resolves the repo root via `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` — they live one level down, so the `..` is required. Don't drop it.

quilt on noble does **not** accept `-d <dir>` as a global flag. Always `cd "$SOURCE_DIR"` (in a subshell) before invoking `quilt`, and pass `QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches --quiltrc "$REPO_DIR/quiltrc"` so config and state are explicit.

Package directories live under `pkgs/` (`PATCHES_DIR="$REPO_DIR/pkgs"`), separate from tooling (`scripts/`, `crash-dashboard/`) and repo config (dotdirectories) at the top level. Discovery loops (`for d in "$PATCHES_DIR"/*/`) don't need to filter by name — everything under `pkgs/` is a package.
