// Command crash-dashboard is a proof-of-concept, Sentry-style dashboard for
// system crashes on a personal Linux machine. It polls systemd-coredump
// (coredumpctl) and Apport (/var/crash) for new crashes, groups them into
// "issues" by executable+signal+top stack frame, and serves a small
// read/resolve web UI on localhost.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

type Issue struct {
	ID         string    `json:"id"`
	Executable string    `json:"executable"`
	Signal     string    `json:"signal"`
	TopFrame   string    `json:"top_frame"`
	FirstSeen  time.Time `json:"first_seen"`
	LastSeen   time.Time `json:"last_seen"`
	Count      int       `json:"count"`
	Resolved   bool      `json:"resolved"`
}

type Occurrence struct {
	ID         int64     `json:"id"`
	IssueID    string    `json:"issue_id"`
	SourceKey  string    `json:"source_key"`
	Source     string    `json:"source"` // "coredumpctl" | "apport" | "demo"
	OccurredAt time.Time `json:"occurred_at"`
	PID        int       `json:"pid"`
	UID        int       `json:"uid"`
	Backtrace  string    `json:"backtrace"`
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

const schema = `
CREATE TABLE IF NOT EXISTS issues (
	id TEXT PRIMARY KEY,
	executable TEXT NOT NULL,
	signal TEXT NOT NULL,
	top_frame TEXT NOT NULL,
	first_seen INTEGER NOT NULL,
	last_seen INTEGER NOT NULL,
	count INTEGER NOT NULL DEFAULT 0,
	resolved INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS occurrences (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	issue_id TEXT NOT NULL REFERENCES issues(id),
	source_key TEXT NOT NULL UNIQUE,
	source TEXT NOT NULL,
	occurred_at INTEGER NOT NULL,
	pid INTEGER NOT NULL DEFAULT 0,
	uid INTEGER NOT NULL DEFAULT 0,
	backtrace TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_occurrences_issue ON occurrences(issue_id);
`

type Store struct {
	db *sql.DB
}

func openStore(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create db dir: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(1) // modernc.org/sqlite: keep it simple, avoid SQLITE_BUSY
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate schema: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// recordCrash inserts a new occurrence (ignored if sourceKey already exists)
// and creates or updates the issue it belongs to. Returns true if a new
// occurrence was actually recorded.
func (s *Store) recordCrash(exe, signal, topFrame, sourceKey, source string, at time.Time, pid, uid int, backtrace string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	id := fingerprint(exe, signal, topFrame)

	res, err := tx.Exec(
		`INSERT OR IGNORE INTO occurrences (issue_id, source_key, source, occurred_at, pid, uid, backtrace)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, sourceKey, source, at.Unix(), pid, uid, backtrace,
	)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n == 0 {
		return false, nil // already ingested this crash before
	}

	var exists int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM issues WHERE id = ?`, id).Scan(&exists); err != nil {
		return false, err
	}
	if exists == 0 {
		if _, err := tx.Exec(
			`INSERT INTO issues (id, executable, signal, top_frame, first_seen, last_seen, count, resolved)
			 VALUES (?, ?, ?, ?, ?, ?, 1, 0)`,
			id, exe, signal, topFrame, at.Unix(), at.Unix(),
		); err != nil {
			return false, err
		}
	} else {
		if _, err := tx.Exec(
			`UPDATE issues SET count = count + 1,
			 first_seen = MIN(first_seen, ?),
			 last_seen = MAX(last_seen, ?),
			 resolved = 0
			 WHERE id = ?`,
			at.Unix(), at.Unix(), id,
		); err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

func fingerprint(exe, signal, topFrame string) string {
	h := sha256.Sum256([]byte(exe + "\x00" + signal + "\x00" + topFrame))
	return hex.EncodeToString(h[:])[:12]
}

func (s *Store) listIssues() ([]Issue, error) {
	rows, err := s.db.Query(`SELECT id, executable, signal, top_frame, first_seen, last_seen, count, resolved FROM issues`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Issue
	for rows.Next() {
		var iss Issue
		var first, last int64
		var resolved int
		if err := rows.Scan(&iss.ID, &iss.Executable, &iss.Signal, &iss.TopFrame, &first, &last, &iss.Count, &resolved); err != nil {
			return nil, err
		}
		iss.FirstSeen = time.Unix(first, 0)
		iss.LastSeen = time.Unix(last, 0)
		iss.Resolved = resolved != 0
		out = append(out, iss)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeen.After(out[j].LastSeen) })
	return out, rows.Err()
}

func (s *Store) getIssue(id string) (Issue, error) {
	var iss Issue
	var first, last int64
	var resolved int
	err := s.db.QueryRow(
		`SELECT id, executable, signal, top_frame, first_seen, last_seen, count, resolved FROM issues WHERE id = ?`, id,
	).Scan(&iss.ID, &iss.Executable, &iss.Signal, &iss.TopFrame, &first, &last, &iss.Count, &resolved)
	iss.FirstSeen = time.Unix(first, 0)
	iss.LastSeen = time.Unix(last, 0)
	iss.Resolved = resolved != 0
	return iss, err
}

func (s *Store) listOccurrences(issueID string) ([]Occurrence, error) {
	rows, err := s.db.Query(
		`SELECT id, issue_id, source_key, source, occurred_at, pid, uid, backtrace
		 FROM occurrences WHERE issue_id = ? ORDER BY occurred_at DESC LIMIT 25`, issueID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Occurrence
	for rows.Next() {
		var o Occurrence
		var at int64
		if err := rows.Scan(&o.ID, &o.IssueID, &o.SourceKey, &o.Source, &at, &o.PID, &o.UID, &o.Backtrace); err != nil {
			return nil, err
		}
		o.OccurredAt = time.Unix(at, 0)
		out = append(out, o)
	}
	return out, rows.Err()
}

func (s *Store) toggleResolved(id string) error {
	_, err := s.db.Exec(`UPDATE issues SET resolved = 1 - resolved WHERE id = ?`, id)
	return err
}

func (s *Store) setResolved(id string, resolved bool) error {
	v := 0
	if resolved {
		v = 1
	}
	res, err := s.db.Exec(`UPDATE issues SET resolved = ? WHERE id = ?`, v, id)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("no such issue: %s", id)
	}
	return nil
}

func (s *Store) isEmpty() (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM issues`).Scan(&n)
	return n == 0, err
}

func (s *Store) knownSourceKeys() (map[string]bool, error) {
	rows, err := s.db.Query(`SELECT source_key FROM occurrences`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	known := make(map[string]bool)
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		known[k] = true
	}
	return known, rows.Err()
}

// ---------------------------------------------------------------------------
// Signal names
// ---------------------------------------------------------------------------

var signalNames = map[int]string{
	1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP",
	6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1",
	11: "SIGSEGV", 12: "SIGUSR2", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
	16: "SIGSTKFLT", 17: "SIGCHLD", 18: "SIGCONT", 19: "SIGSTOP", 20: "SIGTSTP",
	21: "SIGTTIN", 22: "SIGTTOU", 23: "SIGURG", 24: "SIGXCPU", 25: "SIGXFSZ",
	26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH", 29: "SIGIO", 30: "SIGPWR",
	31: "SIGSYS",
}

func normalizeSignal(raw string) string {
	raw = strings.TrimSpace(raw)
	if n, err := strconv.Atoi(raw); err == nil {
		if name, ok := signalNames[n]; ok {
			return name
		}
		return "SIG" + raw
	}
	if !strings.HasPrefix(strings.ToUpper(raw), "SIG") {
		return "SIG" + strings.ToUpper(raw)
	}
	return strings.ToUpper(raw)
}

// frameRegexp pulls the function name out of a gdb "bt" frame line, e.g.:
//
//	#0  0x00007f9a1c2b3e40 in g_assertion_message_expr (domain=0x0) at gtestutils.c:3167
//	#1  0x00005611a2b3c4d5 in main ()
var frameRegexp = regexp.MustCompile(`^#\d+\s+(?:0x[0-9a-fA-F]+\s+in\s+)?([A-Za-z_][A-Za-z0-9_:<>~.]*)\s*\(`)

func extractFrames(backtrace string) []string {
	var frames []string
	sc := bufio.NewScanner(strings.NewReader(backtrace))
	for sc.Scan() {
		line := sc.Text()
		if m := frameRegexp.FindStringSubmatch(line); m != nil {
			frames = append(frames, m[1])
		}
	}
	return frames
}

func topFrameOf(backtrace string) string {
	frames := extractFrames(backtrace)
	if len(frames) == 0 {
		return "(no backtrace)"
	}
	return frames[0]
}

// ---------------------------------------------------------------------------
// coredumpctl collector
// ---------------------------------------------------------------------------

func coredumpctlAvailable() bool {
	_, err := exec.LookPath("coredumpctl")
	return err == nil
}

func pollCoredumpctl(ctx context.Context, store *Store, known map[string]bool) {
	out, err := exec.CommandContext(ctx, "coredumpctl", "--json=short", "--no-legend", "list").Output()
	if err != nil {
		log.Printf("coredumpctl: list failed: %v", err)
		return
	}
	var entries []map[string]any
	if err := json.Unmarshal(out, &entries); err != nil {
		log.Printf("coredumpctl: parse json: %v", err)
		return
	}

	for _, e := range entries {
		pid := int(asFloat(e["pid"]))
		uid := int(asFloat(e["uid"]))
		exe := asString(e["exe"])
		corefile := asString(e["corefile"])
		sig := normalizeSignal(rawSignal(e["sig"]))
		occurredAt := parseCoredumpTime(e["time"])

		sourceKey := fmt.Sprintf("coredumpctl:%d:%d:%s", pid, occurredAt.UnixMicro(), exe)
		if known[sourceKey] {
			continue
		}
		known[sourceKey] = true

		var backtrace string
		switch strings.ToLower(corefile) {
		case "none", "missing", "error", "inaccessible", "":
			backtrace = "(no core file available: " + corefile + ")"
		default:
			bt, err := debugBacktrace(ctx, pid)
			if err != nil {
				backtrace = "(failed to extract backtrace: " + err.Error() + ")"
			} else {
				backtrace = bt
			}
		}

		top := topFrameOf(backtrace)
		if exe == "" {
			exe = "(unknown executable)"
		}
		created, err := store.recordCrash(exe, sig, top, sourceKey, "coredumpctl", occurredAt, pid, uid, backtrace)
		if err != nil {
			log.Printf("coredumpctl: record crash: %v", err)
			continue
		}
		if created {
			log.Printf("coredumpctl: new crash exe=%s signal=%s top=%s pid=%d", exe, sig, top, pid)
		}
	}
}

func debugBacktrace(ctx context.Context, pid int) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "coredumpctl", "debug", "--no-pager", "-1",
		"-A", "-batch -ex bt", strconv.Itoa(pid))
	out, err := cmd.CombinedOutput()
	if err != nil {
		if len(out) > 0 {
			return "", fmt.Errorf("%v: %s", err, firstLine(string(out)))
		}
		return "", err
	}
	return string(out), nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func asFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case string:
		f, _ := strconv.ParseFloat(t, 64)
		return f
	default:
		return 0
	}
}

func asString(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func rawSignal(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.Itoa(int(t))
	default:
		return fmt.Sprint(v)
	}
}

// parseCoredumpTime handles both numeric (usec-since-epoch) and formatted
// string timestamps, since the exact JSON encoding of TABLE_TIMESTAMP cells
// has varied across systemd versions.
func parseCoredumpTime(v any) time.Time {
	switch t := v.(type) {
	case float64:
		return time.UnixMicro(int64(t))
	case string:
		layouts := []string{
			"Mon 2006-01-02 15:04:05 MST",
			time.RFC3339,
			"2006-01-02 15:04:05",
		}
		for _, layout := range layouts {
			if ts, err := time.Parse(layout, t); err == nil {
				return ts
			}
		}
	}
	return time.Now()
}

// ---------------------------------------------------------------------------
// Apport collector
// ---------------------------------------------------------------------------

const apportCrashDir = "/var/crash"

func pollApport(store *Store, known map[string]bool) {
	entries, err := os.ReadDir(apportCrashDir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, os.ErrPermission) {
			log.Printf("apport: read %s: %v", apportCrashDir, err)
		}
		return
	}

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".crash") {
			continue
		}
		path := filepath.Join(apportCrashDir, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		sourceKey := fmt.Sprintf("apport:%s:%d", path, info.ModTime().Unix())
		if known[sourceKey] {
			continue
		}
		known[sourceKey] = true

		fields, err := parseApportReport(path)
		if err != nil {
			log.Printf("apport: skip %s (permission or parse error): %v", path, err)
			continue
		}

		exe := fields["ExecutablePath"]
		if exe == "" {
			exe = fields["Executable"]
		}
		if exe == "" {
			exe = "(unknown executable)"
		}
		sig := normalizeSignal(fields["Signal"])
		backtrace := fields["StacktraceTop"]
		if backtrace == "" {
			backtrace = fields["Stacktrace"]
		}
		if backtrace == "" {
			backtrace = "(apport report had no stack trace field)"
		}
		top := topFrameOf(backtrace)
		pid, _ := strconv.Atoi(fields["Pid"])
		uid, _ := strconv.Atoi(fields["Uid"])
		occurredAt := info.ModTime()
		if d := fields["Date"]; d != "" {
			if ts, err := time.Parse("Mon Jan _2 15:04:05 2006", strings.TrimSpace(d)); err == nil {
				occurredAt = ts
			}
		}

		created, err := store.recordCrash(exe, sig, top, sourceKey, "apport", occurredAt, pid, uid, backtrace)
		if err != nil {
			log.Printf("apport: record crash: %v", err)
			continue
		}
		if created {
			log.Printf("apport: new crash exe=%s signal=%s top=%s file=%s", exe, sig, top, path)
		}
	}
}

// parseApportReport does a lenient parse of Apport's RFC822-ish crash report
// format: "Key: value" lines, optionally followed by space-indented
// continuation lines for multi-line text fields. Fields marked "base64"
// (binary payloads like the core dump itself) are skipped since we only need
// the plain-text stack trace / metadata fields.
func parseApportReport(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fields := make(map[string]string)
	var curKey string
	var curLines []string
	var skipBinary bool

	flush := func() {
		if curKey != "" && !skipBinary {
			fields[curKey] = strings.Join(curLines, "\n")
		}
		curKey, curLines, skipBinary = "", nil, false
	}

	keyLine := regexp.MustCompile(`^([A-Za-z][A-Za-z0-9]*):\s?(.*)$`)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, " ") {
			if !skipBinary {
				curLines = append(curLines, strings.TrimPrefix(line, " "))
			}
			continue
		}
		if m := keyLine.FindStringSubmatch(line); m != nil {
			flush()
			curKey = m[1]
			val := m[2]
			if val == "base64" {
				skipBinary = true
			} else if val != "" {
				curLines = append(curLines, val)
			}
			continue
		}
		// Unrecognized line shape; ignore rather than fail the whole file.
	}
	flush()
	return fields, sc.Err()
}

// ---------------------------------------------------------------------------
// Demo data
// ---------------------------------------------------------------------------

func seedDemoData(store *Store) error {
	demo := []struct {
		exe, sig, backtrace string
		age                 time.Duration
		count               int
	}{
		{
			exe: "/usr/bin/io.elementary.files", sig: "SIGSEGV", age: 3 * time.Minute, count: 7,
			backtrace: "#0  0x00007f2a1b2c3d40 in gtk_tree_view_get_path_at_pos ()\n" +
				"#1  0x00007f2a1b2c9a10 in pantheon_files_view_button_press ()\n" +
				"#2  0x00007f2a1a9f0022 in g_closure_invoke ()\n",
		},
		{
			exe: "/usr/bin/gala", sig: "SIGABRT", age: 40 * time.Minute, count: 2,
			backtrace: "#0  0x00007f88aa112233 in meta_workspace_manager_thaw_remove ()\n" +
				"#1  0x00007f88aa1187ab in workspace_removed_cb ()\n",
		},
		{
			exe: "/usr/bin/io.elementary.terminal", sig: "SIGSEGV", age: 26 * time.Hour, count: 1,
			backtrace: "#0  0x00007fd0cc001122 in vte_terminal_set_pty ()\n" +
				"#1  0x00007fd0cc0089ff in terminal_widget_spawn ()\n",
		},
	}

	now := time.Now()
	for _, d := range demo {
		top := topFrameOf(d.backtrace)
		last := now.Add(-d.age)
		for i := 0; i < d.count; i++ {
			at := last.Add(-time.Duration(i) * time.Hour)
			sourceKey := fmt.Sprintf("demo:%s:%d", d.exe, i)
			if _, err := store.recordCrash(d.exe, d.sig, top, sourceKey, "demo", at, 1000+i, 1000, d.backtrace); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// HTTP dashboard
// ---------------------------------------------------------------------------

const pageCSS = `
body { background: #1b1a24; color: #e8e6ef; font-family: -apple-system, "Inter", "Segoe UI", sans-serif; margin: 0; }
header { background: #26243a; padding: 16px 28px; border-bottom: 1px solid #3a3752; }
header h1 { margin: 0; font-size: 18px; font-weight: 600; }
header .sub { color: #918cb0; font-size: 13px; margin-top: 2px; }
main { max-width: 980px; margin: 24px auto; padding: 0 20px; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; color: #918cb0; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; padding: 8px 12px; border-bottom: 1px solid #3a3752; }
td { padding: 12px; border-bottom: 1px solid #2c2a40; vertical-align: top; }
tr:hover td { background: #23213a; }
a { color: #b9a6ff; text-decoration: none; }
a:hover { text-decoration: underline; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
.badge-sig { background: #4a2540; color: #ff9ecf; }
.badge-count { background: #2c3a52; color: #8fc4ff; }
.badge-resolved { background: #24402c; color: #86e29b; }
.exe { color: #918cb0; font-size: 12px; }
pre { background: #16151f; border: 1px solid #2c2a40; border-radius: 6px; padding: 14px; overflow-x: auto; font-size: 13px; line-height: 1.5; }
.meta { color: #918cb0; font-size: 13px; margin-bottom: 18px; }
.meta span { margin-right: 18px; }
.btn { display: inline-block; background: #3d3862; color: #e8e6ef; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; }
.btn:hover { background: #4c4680; }
.occ { margin-bottom: 18px; }
.occ .head { color: #918cb0; font-size: 12px; margin-bottom: 6px; }
.empty { color: #918cb0; padding: 40px; text-align: center; }
`

type issueView struct {
	ID, Executable, Signal, TopFrame string
	Count                            int
	FirstSeen, LastSeen              string
	Resolved                         bool
}

type indexData struct {
	Issues []issueView
}

type occurrenceView struct {
	Source, When, Backtrace string
	PID, UID                int
}

type issueDetail struct {
	issueView
	Occurrences []occurrenceView
}

var indexTmpl = template.Must(template.New("index").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>Crash Dashboard</title><style>` + pageCSS + `</style></head>
<body>
<header><h1>Crash Dashboard</h1><div class="sub">systemd-coredump + apport, grouped by executable / signal / top frame</div></header>
<main>
{{if not .Issues}}
<div class="empty">No crashes recorded yet.</div>
{{else}}
<table>
<tr><th>Issue</th><th>Signal</th><th>Events</th><th>Last seen</th><th>Status</th></tr>
{{range .Issues}}
<tr>
<td><a href="/issue/{{.ID}}">{{.TopFrame}}</a><div class="exe">{{.Executable}}</div></td>
<td><span class="badge badge-sig">{{.Signal}}</span></td>
<td><span class="badge badge-count">{{.Count}}</span></td>
<td>{{.LastSeen}}</td>
<td>{{if .Resolved}}<span class="badge badge-resolved">resolved</span>{{else}}open{{end}}</td>
</tr>
{{end}}
</table>
{{end}}
</main>
</body></html>`))

var issueTmpl = template.Must(template.New("issue").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>{{.TopFrame}} - Crash Dashboard</title><style>` + pageCSS + `</style></head>
<body>
<header><h1><a href="/">&larr; Crash Dashboard</a></h1></header>
<main>
<h2>{{.TopFrame}}</h2>
<div class="meta">
<span>Executable: {{.Executable}}</span>
<span>Signal: {{.Signal}}</span>
<span>Events: {{.Count}}</span>
<span>First seen: {{.FirstSeen}}</span>
<span>Last seen: {{.LastSeen}}</span>
</div>
<form method="post" action="/issue/{{.ID}}/resolve">
<button class="btn" type="submit">{{if .Resolved}}Reopen{{else}}Mark resolved{{end}}</button>
</form>
<h3>Recent occurrences</h3>
{{range .Occurrences}}
<div class="occ">
<div class="head">{{.When}} &middot; source={{.Source}} &middot; pid={{.PID}} uid={{.UID}}</div>
<pre>{{.Backtrace}}</pre>
</div>
{{else}}
<div class="empty">No occurrence detail recorded.</div>
{{end}}
</main>
</body></html>`))

func toIssueView(iss Issue) issueView {
	return issueView{
		ID: iss.ID, Executable: iss.Executable, Signal: iss.Signal, TopFrame: iss.TopFrame,
		Count: iss.Count, FirstSeen: humanTime(iss.FirstSeen), LastSeen: humanTime(iss.LastSeen),
		Resolved: iss.Resolved,
	}
}

func humanTime(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	case d < 30*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	default:
		return t.Format("2006-01-02")
	}
}

func newServer(store *Store) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		issues, err := store.listIssues()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var views []issueView
		for _, iss := range issues {
			views = append(views, toIssueView(iss))
		}
		if err := indexTmpl.Execute(w, indexData{Issues: views}); err != nil {
			log.Printf("render index: %v", err)
		}
	})

	mux.HandleFunc("GET /issue/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		iss, err := store.getIssue(id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		occs, err := store.listOccurrences(id)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var occViews []occurrenceView
		for _, o := range occs {
			occViews = append(occViews, occurrenceView{
				Source: o.Source, When: humanTime(o.OccurredAt), Backtrace: o.Backtrace,
				PID: o.PID, UID: o.UID,
			})
		}
		detail := issueDetail{issueView: toIssueView(iss), Occurrences: occViews}
		if err := issueTmpl.Execute(w, detail); err != nil {
			log.Printf("render issue: %v", err)
		}
	})

	mux.HandleFunc("POST /issue/{id}/resolve", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if err := store.toggleResolved(id); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, r, "/issue/"+id, http.StatusSeeOther)
	})

	return mux
}

// ---------------------------------------------------------------------------
// MCP server (stdio, JSON-RPC 2.0)
//
// A minimal Model Context Protocol server so an AI assistant can query
// collected crashes and mark them resolved after fixing them, without going
// through the web UI. Register it with Claude Code as:
//
//	claude mcp add crash-dashboard -- /path/to/crash-dashboard -mcp
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

var mcpToolDefs = []mcpTool{
	{
		Name: "list_crashes",
		Description: "List crash issues collected from coredumpctl/apport, grouped by " +
			"executable+signal+top stack frame. Defaults to unresolved issues only.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"include_resolved": map[string]any{
					"type":        "boolean",
					"description": "Include issues already marked resolved. Default false.",
				},
			},
		},
	},
	{
		Name:        "get_crash",
		Description: "Get full detail for one crash issue, including recent occurrences and their stack traces.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"id": map[string]any{
					"type":        "string",
					"description": "Issue ID as returned by list_crashes.",
				},
			},
			"required": []string{"id"},
		},
	},
	{
		Name:        "set_crash_resolved",
		Description: "Mark a crash issue as resolved after fixing it, or reopen it.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"id": map[string]any{
					"type":        "string",
					"description": "Issue ID as returned by list_crashes.",
				},
				"resolved": map[string]any{
					"type":        "boolean",
					"description": "true to mark resolved, false to reopen.",
				},
			},
			"required": []string{"id", "resolved"},
		},
	},
}

func runMCPServer(store *Store) {
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("mcp: read: %v", err)
			}
			return
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			log.Printf("mcp: malformed request: %v", err)
			continue
		}
		resp := handleMCPRequest(store, req)
		if resp == nil {
			continue // notification, no response expected
		}
		b, err := json.Marshal(resp)
		if err != nil {
			log.Printf("mcp: marshal response: %v", err)
			continue
		}
		os.Stdout.Write(b)
		os.Stdout.Write([]byte("\n"))
	}
}

func handleMCPRequest(store *Store, req rpcRequest) *rpcResponse {
	if strings.HasPrefix(req.Method, "notifications/") {
		return nil
	}
	switch req.Method {
	case "initialize":
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "crash-dashboard", "version": "0.1.0"},
		}}
	case "ping":
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
	case "tools/list":
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": mcpToolDefs}}
	case "tools/call":
		return handleMCPToolCall(store, req)
	default:
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
			Code: -32601, Message: "method not found: " + req.Method,
		}}
	}
}

type mcpToolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func handleMCPToolCall(store *Store, req rpcRequest) *rpcResponse {
	var p mcpToolCallParams
	if err := json.Unmarshal(req.Params, &p); err != nil {
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -32602, Message: "invalid params"}}
	}
	text, err := callMCPTool(store, p.Name, p.Arguments)
	if err != nil {
		return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
			"content": []map[string]any{{"type": "text", "text": err.Error()}},
			"isError": true,
		}}
	}
	return &rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
	}}
}

func callMCPTool(store *Store, name string, rawArgs json.RawMessage) (string, error) {
	switch name {
	case "list_crashes":
		var args struct {
			IncludeResolved bool `json:"include_resolved"`
		}
		_ = json.Unmarshal(rawArgs, &args)
		issues, err := store.listIssues()
		if err != nil {
			return "", err
		}
		filtered := issues[:0:0]
		for _, iss := range issues {
			if !args.IncludeResolved && iss.Resolved {
				continue
			}
			filtered = append(filtered, iss)
		}
		b, err := json.MarshalIndent(filtered, "", "  ")
		return string(b), err

	case "get_crash":
		var args struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil || args.ID == "" {
			return "", fmt.Errorf("id is required")
		}
		iss, err := store.getIssue(args.ID)
		if err != nil {
			return "", fmt.Errorf("issue not found: %s", args.ID)
		}
		occs, err := store.listOccurrences(args.ID)
		if err != nil {
			return "", err
		}
		out := struct {
			Issue       Issue        `json:"issue"`
			Occurrences []Occurrence `json:"occurrences"`
		}{iss, occs}
		b, err := json.MarshalIndent(out, "", "  ")
		return string(b), err

	case "set_crash_resolved":
		var args struct {
			ID       string `json:"id"`
			Resolved bool   `json:"resolved"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil || args.ID == "" {
			return "", fmt.Errorf("id is required")
		}
		if err := store.setResolved(args.ID, args.Resolved); err != nil {
			return "", err
		}
		return fmt.Sprintf("issue %s resolved=%v", args.ID, args.Resolved), nil

	default:
		return "", fmt.Errorf("unknown tool: %s", name)
	}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func defaultDBPath() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "crash-dashboard", "crashes.db")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "crashes.db"
	}
	return filepath.Join(home, ".local", "share", "crash-dashboard", "crashes.db")
}

func main() {
	addr := flag.String("addr", "127.0.0.1:9999", "address to serve the dashboard on")
	interval := flag.Duration("interval", 10*time.Second, "how often to poll for new crashes")
	dbPath := flag.String("db", defaultDBPath(), "path to the sqlite database file")
	demo := flag.Bool("demo", false, "seed sample crash data if the database is empty")
	mcpMode := flag.Bool("mcp", false, "run as an MCP server over stdio instead of the web dashboard")
	flag.Parse()

	store, err := openStore(*dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	if *demo {
		empty, err := store.isEmpty()
		if err != nil {
			log.Fatalf("check store: %v", err)
		}
		if empty {
			if err := seedDemoData(store); err != nil {
				log.Fatalf("seed demo data: %v", err)
			}
			log.Print("seeded demo crash data")
		}
	}

	if *mcpMode {
		runMCPServer(store)
		return
	}

	known, err := store.knownSourceKeys()
	if err != nil {
		log.Fatalf("load known crashes: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	haveCoredumpctl := coredumpctlAvailable()
	if !haveCoredumpctl {
		log.Print("coredumpctl not found in PATH; systemd-coredump collection disabled")
	}

	go func() {
		ticker := time.NewTicker(*interval)
		defer ticker.Stop()
		for {
			if haveCoredumpctl {
				pollCoredumpctl(ctx, store, known)
			}
			pollApport(store, known)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()

	srv := &http.Server{Addr: *addr, Handler: newServer(store)}
	go func() {
		log.Printf("crash dashboard listening on http://%s", *addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}
