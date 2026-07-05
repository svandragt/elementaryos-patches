# crash-dashboard

A proof-of-concept, Sentry-style crash dashboard for a personal Linux
machine. Single Go binary, no cgo. Polls `coredumpctl` (systemd-coredump)
and `/var/crash` (Apport) for new crashes, groups repeats into "issues" by
executable + signal + top stack frame, and serves a small web UI. Also
speaks a minimal MCP so an AI assistant can query and resolve crashes
directly.

This is a POC, not hardened software: no auth, no TLS, don't expose it
beyond localhost.

## Build

```bash
cd _crash-dashboard
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

### Permissions

- `coredumpctl` needs permission to read the coredump (root, or a user in
  a group with journal/coredump ACLs).
- `/var/crash/*.crash` files written by Apport are typically root-owned
  (mode 0600). Run the binary as root for full Apport coverage; without
  root it silently skips files it can't read.

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

This isn't a quilt patch series, so it's prefixed with `_` (like
`_scripts/`) to stay out of `ep apply` / `ep status` package discovery,
which loops over non-underscore top-level directories expecting a
`series` file.
