# elementary OS Patches

Personal patches for elementary OS packages — bug fixes and improvements that
bother me enough to maintain them locally.

> **Note:** Patches in this repo are AI-assisted and reviewed/tested by me.
> elementary OS does not accept AI contributions upstream, so these live here
> for anyone who finds them useful.

## Packages

| Package | Patches | Description |
|---------|---------|-------------|
| [io.elementary.notifications](io.elementary.notifications/) | [series](io.elementary.notifications/series) | Don't steal focus when a notification bubble appears on X11 |

Target: elementary OS 8 (Ubuntu 24.04 / noble).

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

```bash
./ep refresh io.elementary.notifications --rebase
# Fix any failures (quilt will stop and tell you)
git add io.elementary.notifications/
git commit -m "io.elementary.notifications: rebase patches onto 8.x"
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | `~/src` | Where source packages are fetched |
| `EDITOR` | `nano` | Editor used by `ep edit` |

## Why not upstream?

These patches were written with AI assistance. elementary OS (and many projects)
don't accept AI-generated contributions due to code review and licensing concerns.
If a patch ever gets rewritten by a human and passes review, it could go upstream.

## Licence

This repo is **GPL-3.0** — same as the upstream packages it patches
(io.elementary.notifications is GPL-3.0). Patch files are derivative works of
the upstream source they apply to and inherit that licence; the wrapper
tooling (`ep`, `_scripts/`) is licensed under GPL-3.0 too for simplicity.

See [LICENSE](LICENSE) for the full text.
