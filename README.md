# elementary OS Patches

Personal patches for elementary OS packages — bug fixes and improvements that
bother me enough to maintain them locally.

> **Note:** Patches in this repo are AI-assisted and reviewed/tested by me.
> elementary OS does not accept AI contributions upstream, so these live here
> for anyone who finds them useful.

## Packages

| Package | Patches | Description |
|---------|---------|-------------|
| [io.elementary.files](io.elementary.files/) | see series | File manager fixes |

## Quick start

### 1. Clone this repo

```bash
git clone https://github.com/YOUR_USERNAME/elementary-patches.git
cd elementary-patches
chmod +x ep _scripts/*.sh
```

### 2. Set up quiltrc (one time)

```bash
cat quiltrc >> ~/.quiltrc
```

### 3. Apply patches and build a package

```bash
./ep apply io.elementary.files       # fetches source, applies all patches
./ep build io.elementary.files --install
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
./ep apply io.elementary.files                         # make sure source is ready
./ep new   io.elementary.files "fix crash on startup"  # create the patch
./ep edit  io.elementary.files src/View/Miller.vala    # edit the file
./ep refresh io.elementary.files                       # finalise the patch
git add io.elementary.files/
git commit -m "io.elementary.files: fix crash on startup"
```

## Updating after a new upstream release

```bash
./ep refresh io.elementary.files --rebase
# Fix any failures (quilt will stop and tell you)
git add io.elementary.files/
git commit -m "io.elementary.files: rebase patches onto 6.4.0"
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
