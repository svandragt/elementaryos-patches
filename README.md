# elementary OS Patches

Personal patches for elementary OS packages — bug fixes and improvements that
bother me enough to maintain them locally.

> **Note:** Patches in this repo are AI-assisted and reviewed/tested by me.
> elementary OS does not accept AI contributions upstream, so these live here
> for anyone who finds them useful.

## Packages

| Package | Patches | Description |
|---------|---------|-------------|
| [io.elementary.notifications](pkgs/io.elementary.notifications/) | [series](pkgs/io.elementary.notifications/series) | Don't steal focus when a notification bubble appears on X11; fix notifications silently dropped after sleep/resume (GDK frame clock not ready, retry until compositor is up) |
| [gala](pkgs/gala/) | [series](pkgs/gala/series) | Stop crash loop from unbalanced `WorkspaceManager.thaw_remove` when a workspace is added outside a swipe gesture; prevent focus-stealing on attention demand |
| [io.elementary.terminal](pkgs/io.elementary.terminal/) | [series](pkgs/io.elementary.terminal/series) | Restore double-click on empty tab bar to open a new tab (GTK4 regression); open OSC 8 hyperlinks on ctrl-click |
| [pantheon-files](pkgs/pantheon-files/) | [series](pkgs/pantheon-files/series) | Double-click on empty tab bar opens a new tab (matches terminal behavior) |
| [appcenter](pkgs/appcenter/) | [series](pkgs/appcenter/series) | Don't show AppCenter in the dock with a "0" badge when there are no pending updates |

Target: elementary OS 8 (Ubuntu 24.04 / noble).

## Tools

| Tool | Description |
|------|-------------|
| [_crash-dashboard](_crash-dashboard/) | Sentry-style POC crash dashboard: single Go binary that collects crashes from `coredumpctl` and Apport, groups them into issues with stack traces, and serves a localhost web UI. Also runs as a minimal MCP server (`-mcp`) so an AI assistant can list, inspect, and resolve reported crashes. See its [README](_crash-dashboard/README.md). |

Patch series live under `pkgs/`; underscore-prefixed directories
(`_scripts/`, `_crash-dashboard/`) are tooling, not patch series.

## Install a patched package (end users)

If you just want a patched build of one of these packages on your own machine —
no contributing, no patch authoring — this is the short path.

### 1. Prerequisites (one time)

```bash
sudo apt install quilt git build-essential devscripts
```

`apt source` and `apt build-dep` need a `deb-src` line for the elementary
archive enabled in `/etc/apt/sources.list` (or a file in
`/etc/apt/sources.list.d/`). Then refresh:

```bash
sudo apt update
```

### 2. Clone and run

```bash
git clone https://github.com/svandragt/elementary-patches.git
cd elementary-patches
chmod +x ep _scripts/*.sh
cat quiltrc >> ~/.quiltrc        # one time

./ep apply io.elementary.notifications       # fetch source + apply patches
./ep build io.elementary.notifications --install
```

`--install` runs `sudo dpkg -i` on the freshly built `.deb`. The unpatched
upstream package will be replaced; remove it later with
`sudo apt install --reinstall io.elementary.notifications` to revert.

### Reverting

```bash
sudo apt install --reinstall io.elementary.notifications
```

That pulls the unpatched upstream version back from the archive.

## Contributor workflow

The end-user steps above already get you a working dev environment. From there:

### Full command reference

```
ep apply   <package>              Fetch source and apply all patches
ep new     <package> <desc>       Create a new patch
ep edit    <package> <file>       Add a file to current patch and open editor
ep refresh <package>              Refresh top patch after editing
ep refresh <package> --rebase     Rebase all patches onto new upstream version
ep build   <package> [--install]  Build package, optionally install it
ep rebuild <package>|--all        Fetch latest source, re-apply patches, build and install
                                  (--no-install to only build, --force to ignore the
                                  up-to-date check)
ep status  [package]              Show patch status
```

### Adding a new patch

```bash
./ep apply   <package>                       # make sure source is ready
./ep new     <package> "fix crash on startup" # create the patch
./ep edit    <package> path/to/file.vala     # add file to patch and open in $EDITOR
./ep refresh <package>                        # finalise the patch
git add <package>/
git commit -m "<package>: fix crash on startup"
```

### Updating after a new upstream release

The one-command path — rebuilds every patched package against whatever the
archive currently ships:

```bash
./ep rebuild --all
```

Per package it fetches the latest source, re-extracts it pristine, re-applies
the series (auto-refreshing patches that land with offsets/fuzz), updates
`VERIFIED`, builds and installs. Pass `--no-install` to only build.

Builds can take a while, so each successful rebuild+install stamps
`$WORK_DIR/.ep-built-<package>` with the source version and a hash of the
patch series. While both are unchanged the package is reported as up to date
and skipped — so `ep rebuild --all` is cheap to re-run. Pass `--force` to
rebuild anyway. (The installed version can't be used for this check: a locally
built `.deb` has the same version as the stock archive package.)

A patch that fails outright skips that package and the summary lists it for a
manual rebase:

```bash
./ep refresh io.elementary.notifications --rebase
# Fix any failures (quilt will stop and tell you)
git add pkgs/io.elementary.notifications/
git commit -m "io.elementary.notifications: rebase patches onto 8.x"
```

After a `rebuild` that refreshed patches, review and commit the changed
`.patch` files the same way.

### Verified-against version

Each package directory contains (or will contain after the next refresh) a
`VERIFIED` file recording the upstream version the patch series was last
refreshed against. It's a breadcrumb, not a lock — `ep apply` still pulls
whatever `apt source` currently ships, but it warns when that version differs
from the recorded one so you know to eyeball the result. `ep refresh` rewrites
`VERIFIED` on success.

To record `VERIFIED` for every package whose patches already apply cleanly
against the current archive, run the one-shot
`./_scripts/backfill-verified.sh` (optionally pass package names to limit it).

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | `~/src` | Where source packages are fetched |
| `EDITOR` | `nano` | Editor used by `ep edit` |

## Why not upstream?

These patches were written with AI assistance. elementary OS (and many projects)
don't accept AI-generated contributions due to code review and licensing concerns.
If a patch ever gets rewritten by a human and passes review, it could go upstream.
Permission is hereby granted to integrate the patches upstream.

## Licence

This repo is **GPL-3.0** — same as the upstream packages it patches
(io.elementary.notifications is GPL-3.0). Patch files are derivative works of
the upstream source they apply to and inherit that licence; the wrapper
tooling (`ep`, `_scripts/`) is licensed under GPL-3.0 too for simplicity.

See [LICENSE](LICENSE) for the full text.
