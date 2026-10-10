# crash-dashboard

A proof-of-concept, Sentry-style crash dashboard for a personal Linux
machine. Single Go binary, no cgo. Polls `coredumpctl` (systemd-coredump),
the `/var/lib/systemd/coredump` directory itself, and `/var/crash`
(Apport) for new crashes, groups repeats into "issues" by
executable + signal + top stack frame, and serves a small web UI. The
issue list can be sorted by any column (click a header) and grouped by
process. Also
speaks a minimal MCP so an AI assistant can query and resolve crashes
directly.

This is a POC, not hardened software: no auth, no TLS, don't expose it
beyond localhost.

## Build

```bash
cd crash-dashboard
go build -o crash-dashboard .
```

Requires network access once to fetch `modernc.org/sqlite` (pure Go, no
cgo) if it isn't already in the module cache. The result is a single
static binary.

## Run the dashboard

```bash
./crash-dashboard                 # listens on 127.0.0.1:9999
./crash-dashboard -demo           # seed sample issues if the DB is empty
./crash-dashboard -addr :9999 -interval 15s -db ~/.local/share/crash-dashboard/crashes.db
```

Open http://127.0.0.1:9999/.

Flags:

| Flag | Default | Meaning |
|------|---------|---------|
| `-addr` | `127.0.0.1:9999` | Bind address for the web UI |
| `-interval` | `10s` | Poll interval for coredumpctl / `/var/crash` |
| `-db` | `$XDG_DATA_HOME/crash-dashboard/crashes.db` | SQLite database path |
| `-demo` | off | Seed sample issues if the database is empty |
| `-mcp` | off | Run as an MCP server over stdio instead of the web dashboard |

### Recovering crashes the journal has forgotten

`coredumpctl` only lists crashes whose metadata is still in the journal.
With capped journal retention (e.g. `SystemMaxUse=500M`), rotation deletes
those entries while the compressed core files stay behind in
`/var/lib/systemd/coredump`. The dashboard therefore also scans that
directory and recovers crashes from the filenames
(`core.<comm>.<uid>.<bootid>.<pid>.<usec>[.zst]`). Recovered entries have
no signal or backtrace (that lived in the journal), but the crash is still
counted and grouped by executable name. Crashes still visible to
`coredumpctl` are not double-counted.

### Permissions

- `coredumpctl` needs permission to read the coredump (root, or a user in
  a group with journal/coredump ACLs).
- Under `sudo`, the default `-db` path resolves via `$SUDO_USER` to the
  invoking user's home, so plain and sudo runs share one database.
- `/var/crash/*.crash` files written by Apport are typically root-owned
  (mode 0600). Run the binary as root for full Apport coverage; without
  root it silently skips files it can't read.

## Running persistently (systemd user service)

Crash collection only happens while the dashboard process is running —
there's no separate daemon or timer. Running `-mcp` mode alone does
**not** collect anything; it only reads whatever's already in the
database. To collect crashes continuously in the background, run the
web dashboard as a systemd user service:

```ini
# ~/.config/systemd/user/crash-dashboard.service
[Unit]
Description=Crash dashboard (coredumpctl/Apport collector + web UI)
After=default.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart="/path/to/crash-dashboard"
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=crash-dashboard

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now crash-dashboard.service
```

Memory footprint is a few MB (SQLite + a 10s poll ticker), negligible
for an always-on background service. If your journal/coredump ACLs
grant your user group (e.g. `adm`) read access, this runs fine without
root; root is only needed for Apport files in `/var/crash`.

## Finding the cause of an out-of-memory logout

When the kernel runs out of memory, it can kill `gnome-session-manager`,
which ends the whole session. Gala then crashes during shutdown, so the
dashboard shows a gala crash that is a symptom, not the cause. The kernel
log shows only the moment of the OOM, not what grew before it.

`memwatch` logs one line a minute to the journal: available RAM, free
swap, shared memory, and the programs using the most RAM and swap. To
install it as a user service:

```ini
# ~/.config/systemd/user/memwatch.service
[Unit]
Description=Memory snapshot logger

[Service]
ExecStart="/path/to/crash-dashboard/memwatch"
Restart=always

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now memwatch.service
loginctl enable-linger "$USER"   # start at boot and survive a logout
```

After an unexpected logout, confirm the OOM and read the minutes before it:

```bash
journalctl --user -b | grep -i oom-kill
journalctl -k -b | grep -E "invoked oom-killer|Killed process"
journalctl --user -t memwatch --since "-1h"
```

Look for the program whose number rises across the snapshots. A high
`Shmem` value usually means LXD VM guest memory. A spike shorter than a
minute falls between snapshots; the kernel's OOM task table is then the
only evidence.

## MCP: let an assistant fix reported crashes

`-mcp` runs the same binary as a minimal MCP server over stdio (JSON-RPC
2.0, one message per line), reading/writing the same SQLite database as
the web dashboard. It exposes three tools:

- `list_crashes` — unresolved issues by default (`include_resolved: true` to see all)
- `get_crash` — full detail + recent occurrences/backtraces for one issue ID
- `set_crash_resolved` — mark an issue resolved after fixing it, or reopen it

Register it with Claude Code:

```bash
claude mcp add crash-dashboard -- /path/to/crash-dashboard -mcp -db ~/.local/share/crash-dashboard/crashes.db
```

Then an assistant can list open crashes, pull a backtrace, propose/apply a
fix in the affected package's source, and mark the issue resolved once
verified — without touching the web UI.

## Why this isn't wired into `ep`

This isn't a quilt patch series, so it lives outside `pkgs/` — `ep apply`
and `ep status` only loop over directories under `pkgs/`.
