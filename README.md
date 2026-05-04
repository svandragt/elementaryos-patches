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

## Quick start

### 1. Clone this repo

```bash
git clone https://github.com/svandragt/elementary-patches.git
cd elementary-patches
chmod +x ep _scripts/*.sh
```

### 2. Set up quiltrc (one time)

```bash
cat quiltrc >> ~/.quiltrc
```

### 3. Apply patches and build a package

```bash
./ep apply io.elementary.notifications       # fetches source, applies all patches
./ep build io.elementary.notifications --install
```

That's it.

## Full command reference

```
ep apply   <package>              Fetch source and apply all patches
ep new     <package> <desc>       Create a new patch
ep edit    <package> <file>       Add a file to current patch and open editor
ep refresh <package>              Refresh top patch after editing
ep refresh <package> --rebase     Rebase all patches onto new upstream version
ep build   <package> [--install]  Build package, optionally install it
ep status  [package]              Show patch status
```

## Adding a new patch

```bash
./ep apply   <package>                       # make sure source is ready
./ep new     <package> "fix crash on startup" # create the patch
./ep edit    <package> path/to/file.vala     # add file to patch and open in $EDITOR
./ep refresh <package>                        # finalise the patch
git add <package>/
git commit -m "<package>: fix crash on startup"
```

## Updating after a new upstream release

```bash
./ep refresh io.elementary.notifications --rebase
# Fix any failures (quilt will stop and tell you)
git add io.elementary.notifications/
git commit -m "io.elementary.notifications: rebase patches onto 8.x"
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | `~/src` | Where source packages are fetched |
| `EDITOR` | `nano` | Editor used by `ep edit` |

## Why not upstream?

These patches were written with AI assistance. elementary OS (and many projects)
don't accept AI-generated contributions due to code review and licensing concerns.
If a patch ever gets rewritten by a human and passes review, it could go upstream.

## Licence

Patches are provided as-is. Underlying code belongs to the respective upstream
projects and their licences apply.
