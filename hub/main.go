// extra-sync hub: local web dashboard for the extra-sync convention.
//
// A single static binary (Go stdlib only) that serves an embedded web UI on
// 127.0.0.1 and exposes the existing sync.sh script over a small JSON API.
// It never re-implements sync logic: every mutating or diagnostic action is a
// thin wrapper around scripts/sync.sh, so the shell script stays the single
// source of behavior.
//
// Usage:
//
//	extra-sync-hub serve [--port N]   # default 8788
//	extra-sync-hub version
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "0.1.0"

//go:embed web
var webFS embed.FS

func home() string {
	h, _ := os.UserHomeDir()
	return h
}

func agentsConfigDir() string { return filepath.Join(home(), ".agents-config") }

func syncScript() string {
	return filepath.Join(agentsConfigDir(), "special", "claude", "plugins", "extra-sync", "scripts", "sync.sh")
}

func reportsDir() string { return filepath.Join(agentsConfigDir(), "reports") }

// ---------- sync.sh execution ----------

// runMu serializes sync.sh runs: the script mutates symlinks and JSON configs,
// so two concurrent invocations could race each other.
var runMu sync.Mutex

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

type runResult struct {
	OK       bool   `json:"ok"`
	ExitCode int    `json:"exit_code"`
	Output   string `json:"output"`
	Error    string `json:"error,omitempty"`
}

// runSync executes sync.sh with the given arguments and returns its combined
// output with ANSI colors stripped. Returns busy=true if another run holds the lock.
func runSync(timeout time.Duration, args ...string) (res runResult, busy bool) {
	if !runMu.TryLock() {
		return runResult{}, true
	}
	defer runMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/bash", append([]string{syncScript()}, args...)...)
	out, err := cmd.CombinedOutput()
	res.Output = ansiRe.ReplaceAllString(string(out), "")
	res.ExitCode = -1
	if cmd.ProcessState != nil {
		res.ExitCode = cmd.ProcessState.ExitCode()
	}
	res.OK = err == nil
	if ctx.Err() == context.DeadlineExceeded {
		res.Error = "timeout: sync.sh exceeded " + timeout.String()
	} else if err != nil {
		res.Error = err.Error()
	}
	return res, false
}

// ---------- report loading ----------

// latestReportPath returns the newest sync-report-*.json (names embed a
// sortable timestamp, so lexicographic order is chronological).
func latestReportPath() (string, error) {
	entries, err := os.ReadDir(reportsDir())
	if err != nil {
		return "", err
	}
	var names []string
	for _, e := range entries {
		n := e.Name()
		if strings.HasPrefix(n, "sync-report-") && strings.HasSuffix(n, ".json") {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return "", errors.New("no sync-report found")
	}
	sort.Strings(names)
	return filepath.Join(reportsDir(), names[len(names)-1]), nil
}

// ---------- remote-update output parsing ----------

type update struct {
	Kind   string `json:"kind"` // "plugin" | "skill"
	Name   string `json:"name"`
	Local  string `json:"local"`
	Remote string `json:"remote"`
}

// Local versions may be a commit hash, a semver string, or "unknown", so both
// sides of the arrow match any non-space token.
var (
	skillUpdateRe  = regexp.MustCompile(`Skill '([^']+)': update available \((\S+) -> (\S+)\)`)
	pluginUpdateRe = regexp.MustCompile(`(\S+): update available \((\S+) -> (\S+)\)`)
)

// parseUpdates extracts "update available" lines from sync.sh --remote output.
func parseUpdates(output string) []update {
	updates := []update{}
	for _, line := range strings.Split(output, "\n") {
		if m := skillUpdateRe.FindStringSubmatch(line); m != nil {
			updates = append(updates, update{Kind: "skill", Name: m[1], Local: m[2], Remote: m[3]})
			continue
		}
		if m := pluginUpdateRe.FindStringSubmatch(line); m != nil {
			updates = append(updates, update{Kind: "plugin", Name: m[1], Local: m[2], Remote: m[3]})
		}
	}
	return updates
}

// ---------- port handling ----------

type procInfo struct {
	pid     int
	command string
}

func portProcs(port int) []procInfo {
	out, err := exec.Command("/usr/sbin/lsof", "-nP", "-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN").Output()
	if err != nil {
		return nil
	}
	var procs []procInfo
	for _, line := range strings.Split(string(out), "\n")[1:] {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		if pid, err := strconv.Atoi(f[1]); err == nil {
			procs = append(procs, procInfo{pid: pid, command: f[0]})
		}
	}
	for i := range procs {
		if out, err := exec.Command("/bin/ps", "-p", strconv.Itoa(procs[i].pid), "-o", "command=").Output(); err == nil {
			if cmd := strings.TrimSpace(string(out)); cmd != "" {
				procs[i].command = cmd
			}
		}
	}
	return procs
}

// ensurePortFree kills stale extra-sync-hub instances holding the port, and
// reports a clear error (PID + command + release hint) for foreign occupants.
func ensurePortFree(port int) error {
	procs := portProcs(port)
	if len(procs) == 0 {
		return nil
	}
	var mine, others []procInfo
	for _, p := range procs {
		if strings.Contains(p.command, "extra-sync-hub") {
			mine = append(mine, p)
		} else {
			others = append(others, p)
		}
	}
	if len(mine) > 0 && len(others) == 0 {
		for _, p := range mine {
			fmt.Printf("stopping old extra-sync-hub instance (PID %d)…\n", p.pid)
			_ = syscall.Kill(p.pid, syscall.SIGTERM)
		}
		for i := 0; i < 30; i++ {
			if len(portProcs(port)) == 0 {
				return nil
			}
			time.Sleep(100 * time.Millisecond)
		}
		return errors.New("old instance did not stop; run: pkill -f 'extra-sync-hub serve'")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "port %d is in use:\n", port)
	for _, p := range others {
		fmt.Fprintf(&b, "  PID %d  %s\n", p.pid, p.command)
	}
	fmt.Fprintf(&b, "free it (lsof -ti:%d | xargs kill) or pick another port: extra-sync-hub serve --port N", port)
	return errors.New(b.String())
}

// ---------- HTTP server ----------

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func requirePost(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return false
	}
	return true
}

// handleRun wraps a sync.sh invocation as an HTTP handler.
func handleRun(w http.ResponseWriter, timeout time.Duration, args ...string) (runResult, bool) {
	res, busy := runSync(timeout, args...)
	if busy {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "another sync.sh run is in progress, retry later"})
		return res, false
	}
	return res, true
}

func cmdServe(args []string) {
	port := 8788
	for i := 0; i < len(args); i++ {
		if args[i] == "--port" && i+1 < len(args) {
			if p, err := strconv.Atoi(args[i+1]); err == nil {
				port = p
			}
			i++
		}
	}

	if _, err := os.Stat(syncScript()); err != nil {
		fmt.Fprintln(os.Stderr, "sync.sh not found:", syncScript())
		os.Exit(1)
	}

	addr := "127.0.0.1:" + strconv.Itoa(port)
	if err := ensurePortFree(port); err != nil {
		fmt.Fprintln(os.Stderr, "startup failed:", err)
		os.Exit(1)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "startup failed:", err)
		os.Exit(1)
	}
	defer ln.Close()

	sub, _ := fs.Sub(webFS, "web")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(sub)))

	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"ok": "true", "version": version})
	})

	// GET: serve the newest cached report. POST: regenerate via sync.sh --report first.
	mux.HandleFunc("/api/report", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			if res, ok := handleRun(w, 2*time.Minute, "--report"); !ok {
				return
			} else if !res.OK {
				writeJSON(w, http.StatusInternalServerError, res)
				return
			}
		}
		path, err := latestReportPath()
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]string{
				"error": "no report yet — click refresh to generate the first one",
			})
			return
		}
		data, err := os.ReadFile(path)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Write(data)
	})

	// Read-only diagnosis. ok=false + exit_code=1 means broken (ERR) issues remain.
	mux.HandleFunc("/api/doctor", func(w http.ResponseWriter, r *http.Request) {
		if !requirePost(w, r) {
			return
		}
		if res, ok := handleRun(w, 2*time.Minute, "doctor"); ok {
			writeJSON(w, http.StatusOK, res)
		}
	})

	// Mutating repair; sync.sh backs up before overwriting. Optional {"scope":"claude"}.
	mux.HandleFunc("/api/fix", func(w http.ResponseWriter, r *http.Request) {
		if !requirePost(w, r) {
			return
		}
		var req struct {
			Scope string `json:"scope"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		args := []string{"fix"}
		if req.Scope == "claude" {
			args = append(args, "--scope", "claude")
		}
		if res, ok := handleRun(w, 5*time.Minute, args...); ok {
			writeJSON(w, http.StatusOK, res)
		}
	})

	// Remote update check (network: git ls-remote per plugin/skill).
	mux.HandleFunc("/api/remote", func(w http.ResponseWriter, r *http.Request) {
		if !requirePost(w, r) {
			return
		}
		res, ok := handleRun(w, 10*time.Minute, "--remote")
		if !ok {
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": res.OK, "exit_code": res.ExitCode, "output": res.Output,
			"error": res.Error, "updates": parseUpdates(res.Output),
		})
	})

	// Full sync (--all): pull + skills + plugins + remote + report.
	mux.HandleFunc("/api/sync", func(w http.ResponseWriter, r *http.Request) {
		if !requirePost(w, r) {
			return
		}
		res, ok := handleRun(w, 10*time.Minute, "--all")
		if !ok {
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": res.OK, "exit_code": res.ExitCode, "output": res.Output,
			"error": res.Error, "updates": parseUpdates(res.Output),
		})
	})

	fmt.Printf("extra-sync hub → http://%s\n", addr)
	fmt.Println("Ctrl+C to stop.")
	if err := http.Serve(ln, mux); err != nil {
		fmt.Fprintln(os.Stderr, "server exited:", err)
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: extra-sync-hub serve [--port N] | version")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "serve":
		cmdServe(os.Args[2:])
	case "version":
		fmt.Println("extra-sync-hub", version)
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", os.Args[1])
		os.Exit(1)
	}
}
