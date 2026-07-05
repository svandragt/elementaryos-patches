# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Target platform: **elementary OS 8** (Ubuntu 24.04 base). Source packages are pulled from that archive via `apt source`, so any version assumptions (build-deps, library APIs, etc.) should be checked against noble, not jammy.

Personal quilt-style patch series for elementary OS Debian source packages. Each top-level directory named after a package (e.g. `io.elementary.notifications/`) holds a `series` file plus numbered `.patch` files in standard quilt format. Patches are AI-assisted and intentionally kept out of upstream — they live here for local rebuilds.

Underscore-prefixed directories are tooling, not patch series: `_scripts/` holds the `ep` helper scripts, and `_crash-dashboard/` is a standalone Go binary (Sentry-style local crash dashboard over coredumpctl/Apport, with a web UI and an `-mcp` stdio mode for assistant-driven triage — see its README). Build with `go build` inside that directory; don't add a `series` file there.

elementary OS does not accept AI-generated contributions, so do not propose pushing patches upstream.

## Workflow

The intended workflow (per `README.md`) is driven by an `ep` CLI wrapper:

```
./ep apply   <package>              # apt source + symlink patches/ + quilt push -a
./ep new     <package> <desc>       # quilt new
./ep edit    <package> <file>       # quilt add + $EDITOR
./ep refresh <package> [--rebase]   # quilt refresh (or rebase onto new upstream)
./ep build   <package> [--install]  # dpkg-buildpackage, optional dpkg -i
./ep status  [package]              # quilt applied/unapplied
```

Source is fetched into `$WORK_DIR` (default `~/src`) via `apt source`. Patches are exposed to quilt by symlinking `<repo>/<package>` into `<source>/patches`, with `.pc` state kept inside the source tree.

## Script invariants

Every `_scripts/*.sh` resolves the repo root via `REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` — they live one level down, so the `..` is required. Don't drop it.

quilt on noble does **not** accept `-d <dir>` as a global flag. Always `cd "$SOURCE_DIR"` (in a subshell) before invoking `quilt`, and pass `QUILT_PC=$SOURCE_DIR/.pc QUILT_PATCHES=$SOURCE_DIR/patches --quiltrc "$REPO_DIR/quiltrc"` so config and state are explicit.

Package directory discovery (`for d in "$REPO_DIR"/*/`) skips entries starting with `_` or `.`, which is why `_scripts/` is hidden from `ep apply` / `ep status` output.

## Commit style

Commit subjects follow `<package>: <change>`, e.g. `io.elementary.notifications: add fix-focus patch`. One patch (or one rebase) per commit.
