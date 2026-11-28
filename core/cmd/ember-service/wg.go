package main

// The WireGuard / AmneziaWG tunnel driver (audit C3).
// Dispatch: wg.start / wg.stop / wg.state are wired in server.go.
//
// VERIFIED CONTRACT — from the shipped 2040 Flutter Windows app,
// app/lib/xray/xray_platform_windows.dart (setOnAwg and helpers,
// lines ~574-760 and ~2232-2260), driving the binary the
// sidecar script ships (scripts/fetch-windows-sidecars.ps1,
// wireguard section: tools\sidecars\wireguard receives
// amneziawg.exe — extracted from the official AmneziaWG 3.1.0
// MSI — plus wintun.dll):
//
//   - amneziawg.exe is the AmneziaWG Windows client (the
//     wireguard-windows fork): a tunnel-service tool, NOT a
//     foreground daemon. It is never run bare.
//   - Install + start a tunnel:
//         amneziawg.exe /installtunnelservice <path-to.conf>
//     The tunnel's Windows service is named
//         AmneziaWGTunnel$<tunnelName>
//     where <tunnelName> derives from the profile name by
//     awgTunnelNameFor below (a verbatim port of the Dart
//     helper of the same name).
//   - An already-registered tunnel is started with
//         sc.exe start AmneziaWGTunnel$<tunnelName>
//   - State is the SCM state, read with
//         sc.exe query AmneziaWGTunnel$<tunnelName>
//     (STATE : <n> <WORD>); a query failure / error 1060 means
//     no such service is registered.
//   - Remove a tunnel:
//         amneziawg.exe /uninstalltunnelservice <tunnelName>
//     (the argument is the tunnel NAME, not the service name).
//   - Counters/handshake exist on the tunnel's UAPI pipe
//     (ProtectedPrefix\Administrators\AmneziaWG\<tunnelName>);
//     this driver deliberately does NOT report counters — SCM
//     state only — rather than fake figures it has not read.
//
// The service runs as LocalSystem, so the elevation the Dart
// code had to beg for is already held here; the verbs above
// are executed directly.
//
// Config store: wg.start writes confText to
// %ProgramData%\Ralysnd Ember\wireguard\<tunnelName>.conf
// (directory 0o700, file 0o600 as far as Go permissions map;
// on Windows writeConf additionally applies a restrictive
// DACL to the folder — see secureWGStoreDir — because POSIX
// modes set no Windows ACL. The file holds a WireGuard
// private key, so wg.stop deletes it once the tunnel service
// is removed).

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type wgStartParams struct {
	Name     string `json:"name"`
	ConfText string `json:"confText"`
	// Exe is accepted for wire compatibility with older
	// clients but confers NO authority (2042 adversarial
	// review C1): amneziawg.exe is resolved ONLY as
	// <registeredRoot>\wireguard\amneziawg.exe, and an Exe
	// param naming anything else is refused outright.
	Exe string `json:"exe,omitempty"`
}

type wgState struct {
	Name        string `json:"name"`
	TunnelName  string `json:"tunnelName"`
	ServiceName string `json:"serviceName"`
	// State is the SCM state, lower-cased: running, stopped,
	// start_pending, stop_pending, paused, absent (no such
	// service registered) or unknown. Never assumed: every
	// value here came from an `sc query` issued by state().
	State   string `json:"state"`
	Running bool   `json:"running"`
}

// wgRunner runs one external command and returns its combined
// output. Abstracted so tests can script sc.exe / amneziawg.exe.
type wgRunner interface {
	Run(name string, args ...string) (string, error)
}

type execWGRunner struct{ timeout time.Duration }

func (r execWGRunner) Run(name string, args ...string) (string, error) {
	to := r.timeout
	if to <= 0 {
		to = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), to)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(out), err
}

type wgManager struct {
	mu           sync.Mutex
	roots        *rootSet
	runner       wgRunner
	storeDir     string // config store; field so tests can redirect
	pollAttempts int    // post-start RUNNING polls
	pollDelay    time.Duration
	// exeByTunnel remembers the amneziawg.exe a start used, so
	// a stop in the same service lifetime need not re-derive
	// it from the (case-normalised) root set.
	exeByTunnel map[string]string
}

func wgStoreDir() string {
	dir := os.Getenv("ProgramData")
	if dir == "" {
		dir = `C:\ProgramData`
	}
	return filepath.Join(dir, "Ralysnd Ember", "wireguard")
}

func newWGManager(roots *rootSet) *wgManager {
	return &wgManager{
		roots:        roots,
		runner:       execWGRunner{},
		storeDir:     wgStoreDir(),
		pollAttempts: 50, // 50 x 200ms = up to 10s to reach RUNNING
		pollDelay:    200 * time.Millisecond,
		exeByTunnel:  make(map[string]string),
	}
}

func wgServiceName(tunnelName string) string {
	return "AmneziaWGTunnel$" + tunnelName
}

// awgTunnelNameFor is a verbatim port of the Dart helper in
// xray_platform_windows.dart: the service is
// AmneziaWGTunnel$<name> and the config file <name>.conf, so
// the name is kept to the characters both accept — letters,
// digits and `_-.=+` — with anything else folded to `_`,
// capped at 40 characters, leading/trailing `.`/`_` trimmed;
// an empty result reads "ember".
func awgTunnelNameFor(profileName string) string {
	var b strings.Builder
	for _, ch := range strings.TrimSpace(profileName) {
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9',
			ch == '_', ch == '-', ch == '.', ch == '=', ch == '+':
			b.WriteRune(ch)
		default:
			b.WriteByte('_')
		}
	}
	name := b.String()
	if len(name) > 40 {
		name = name[:40]
	}
	name = strings.Trim(name, "._")
	if name == "" {
		return "ember"
	}
	return name
}

var scStateRe = regexp.MustCompile(`STATE\s*:\s*\d+\s+([A-Za-z_]+)`)

// parseSCQueryState extracts the SCM state word from
// `sc.exe query` output. ok=false when the output carries no
// STATE line (e.g. the 1060 "service does not exist" error).
func parseSCQueryState(out string) (state string, ok bool) {
	m := scStateRe.FindStringSubmatch(out)
	if m == nil {
		return "", false
	}
	return strings.ToLower(m[1]), true
}

// findExe locates amneziawg.exe: ONLY as
// <root>\wireguard\amneziawg.exe under a registered app root
// (the layout scripts/build-windows.ps1 packages and the Dart
// _awgExe getter reads: <app>\wireguard\amneziawg.exe), with
// the candidate validated through the same canonical
// confinement as proc.start (roots.checkExe). The
// client-supplied Exe param confers no authority whatsoever
// (review C1): when present it must name exactly that
// in-root resolution — canonically — or the start is
// refused. Before this fix the param was trusted after a
// basename + Stat check, which let any pipe client have this
// SYSTEM service execute an arbitrary file renamed to
// amneziawg.exe.
func (w *wgManager) findExe(p wgStartParams) (string, error) {
	// The only locations this service will ever run as the
	// tunnel tool: <root>\wireguard\amneziawg.exe for each
	// registered root, each validated through roots.checkExe
	// (allowlisted name + canonical under-root confinement).
	var candidates []string
	if w.roots != nil {
		for _, root := range w.roots.list() {
			// Roots are stored cleaned (forward slashes,
			// lower-cased); filepath.Join re-shapes the
			// candidate for the host OS.
			cand := filepath.Join(filepath.FromSlash(root), "wireguard", "amneziawg.exe")
			if w.roots.checkExe(cand) != nil {
				continue
			}
			candidates = append(candidates, cand)
		}
	}
	if p.Exe != "" {
		// The param must canonically name one of the
		// candidates — nothing else. (Canonical comparison
		// folds case and resolves ".." and symlinks, so the
		// returned path is the client's own spelling of the
		// one permitted file.)
		for _, cand := range candidates {
			if canonicalPath(p.Exe) == canonicalPath(cand) {
				if _, err := os.Stat(p.Exe); err != nil {
					return "", fmt.Errorf("amneziawg.exe not found at %s: %w", p.Exe, err)
				}
				return p.Exe, nil
			}
		}
		return "", fmt.Errorf("wg.start: exe %q is not the amneziawg.exe under a registered app folder — refused", p.Exe)
	}
	for _, cand := range candidates {
		if _, err := os.Stat(cand); err == nil {
			return cand, nil
		}
	}
	return "", fmt.Errorf("amneziawg.exe not found under any registered app folder's wireguard folder — the WireGuard sidecar is missing from this install")
}

// exeForStop resolves amneziawg.exe for a stop: the copy the
// matching start used when known, else the root-set lookup.
// The remembered path is re-validated through findExe (C1):
// the map is only ever populated from findExe, but a stop
// must never run a path that would fail today's confinement.
func (w *wgManager) exeForStop(tunnel string) (string, error) {
	if exe, ok := w.exeByTunnel[tunnel]; ok && exe != "" {
		if validated, err := w.findExe(wgStartParams{Exe: exe}); err == nil {
			return validated, nil
		}
	}
	return w.findExe(wgStartParams{})
}

// queryState reads the tunnel service's SCM state. absent
// (ok=false in parse terms) is reported as state "absent",
// never as an error: callers branch on it.
func (w *wgManager) queryState(serviceName string) wgState {
	out, err := w.runner.Run("sc.exe", "query", serviceName)
	st := wgState{ServiceName: serviceName, State: "absent"}
	if word, ok := parseSCQueryState(out); ok {
		st.State = word
		st.Running = word == "running"
		return st
	}
	if err == nil {
		// sc answered but with no STATE line we can read:
		// say so instead of guessing.
		st.State = "unknown"
	}
	return st
}

// state reports the tunnel's SCM state for a profile name.
func (w *wgManager) state(name string) wgState {
	tunnel := awgTunnelNameFor(name)
	st := w.queryState(wgServiceName(tunnel))
	st.Name = name
	st.TunnelName = tunnel
	return st
}

// writeConf persists confText in the protected store and
// returns the config path handed to /installtunnelservice.
func (w *wgManager) writeConf(tunnelName, confText string) (string, error) {
	if err := os.MkdirAll(w.storeDir, 0o700); err != nil {
		return "", fmt.Errorf("create the WireGuard config store: %w", err)
	}
	// The store holds WireGuard private keys: on Windows the
	// POSIX modes above set no ACL, so lock the folder down
	// explicitly (review W10). Other OSes: no-op.
	if err := secureWGStoreDir(w.storeDir); err != nil {
		return "", fmt.Errorf("secure the WireGuard config store: %w", err)
	}
	path := filepath.Join(w.storeDir, tunnelName+".conf")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(confText), 0o600); err != nil {
		return "", fmt.Errorf("write the WireGuard config: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", fmt.Errorf("write the WireGuard config: %w", err)
	}
	return path, nil
}

// start raises the tunnel for one profile, following the
// Dart flow exactly: an existing non-running tunnel service
// is started with sc; a missing one (or a failed sc start)
// is installed from the config with /installtunnelservice
// (which also starts it). Success is only claimed after the
// SCM reports RUNNING — the state returned is the SCM's.
func (w *wgManager) start(p wgStartParams) (wgState, error) {
	if strings.TrimSpace(p.Name) == "" {
		return wgState{}, fmt.Errorf("wg.start needs a profile name")
	}
	conf := strings.TrimSpace(p.ConfText)
	if !strings.Contains(conf, "[Interface]") || !strings.Contains(conf, "[Peer]") {
		return wgState{}, fmt.Errorf("wg.start: the config text carries no [Interface]/[Peer] sections — not a WireGuard config")
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	tunnel := awgTunnelNameFor(p.Name)
	svcName := wgServiceName(tunnel)

	// A RUNNING tunnel's config is never silently overwritten
	// (review W5): the old flow wrote the new conf first and
	// then "started" the already-running old tunnel, reporting
	// the new profile connected while the old one carried the
	// traffic. Same config on a running tunnel is an
	// idempotent success; a different one is refused — the
	// caller stops the tunnel first, then starts.
	if before := w.queryState(svcName); before.Running {
		stored, rerr := os.ReadFile(filepath.Join(w.storeDir, tunnel+".conf"))
		if rerr == nil && string(stored) == p.ConfText {
			st := w.state(p.Name)
			return st, nil
		}
		return wgState{}, fmt.Errorf("tunnel is running — stop it before changing its config (%s)", p.Name)
	}

	exe, err := w.findExe(p)
	if err != nil {
		return wgState{}, err
	}
	if w.exeByTunnel == nil {
		w.exeByTunnel = make(map[string]string)
	}
	w.exeByTunnel[tunnel] = exe
	confPath, err := w.writeConf(tunnel, p.ConfText)
	if err != nil {
		return wgState{}, err
	}

	existing := w.queryState(svcName)
	var failure string
	if existing.State != "absent" && existing.State != "running" {
		if out, err := w.runner.Run("sc.exe", "start", svcName); err != nil {
			failure = lastLine(out, err)
		}
	}
	if existing.State == "absent" || failure != "" {
		if out, err := w.runner.Run(exe, "/installtunnelservice", confPath); err != nil {
			return wgState{}, fmt.Errorf("amneziawg could not install the tunnel service for %s: %s", p.Name, lastLine(out, err))
		}
	}

	// Verify against the SCM — never assume the verbs worked.
	for i := 0; i < w.pollAttempts; i++ {
		st := w.state(p.Name)
		if st.Running {
			return st, nil
		}
		if i+1 < w.pollAttempts {
			time.Sleep(w.pollDelay)
		}
	}
	st := w.state(p.Name)
	return st, fmt.Errorf("the tunnel service for %s did not reach RUNNING (SCM state: %s)", p.Name, st.State)
}

// stop removes the tunnel: sc stop first, then
// /uninstalltunnelservice <tunnelName> (the task contract —
// wg.stop removes the tunnel service; the stored config,
// which holds the private key, is deleted with it). A tunnel
// that was never installed is a successful no-op stop.
func (w *wgManager) stop(name string) (wgState, error) {
	if strings.TrimSpace(name) == "" {
		return wgState{}, fmt.Errorf("wg.stop needs a profile name")
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	tunnel := awgTunnelNameFor(name)
	svcName := wgServiceName(tunnel)
	before := w.queryState(svcName)
	if before.State == "absent" {
		_ = os.Remove(filepath.Join(w.storeDir, tunnel+".conf"))
		return w.state(name), nil
	}
	if before.Running {
		// A refused stop is not fatal yet: uninstall is the
		// fallback the Dart code used for the same case.
		_, _ = w.runner.Run("sc.exe", "stop", svcName)
	}
	exe, err := w.exeForStop(tunnel)
	if err != nil {
		// Without the tunnel tool the SCM's own delete is the
		// remaining removal verb; use it rather than strand a
		// registered tunnel service.
		if out, derr := w.runner.Run("sc.exe", "delete", svcName); derr != nil {
			return wgState{}, fmt.Errorf("remove the tunnel service for %s: %s (and %v)", name, lastLine(out, derr), err)
		}
	} else if out, err := w.runner.Run(exe, "/uninstalltunnelservice", tunnel); err != nil {
		return wgState{}, fmt.Errorf("amneziawg could not uninstall the tunnel service for %s: %s", name, lastLine(out, err))
	}
	after := w.state(name)
	if after.State != "absent" && after.Running {
		return after, fmt.Errorf("the tunnel service for %s is still running after uninstall", name)
	}
	_ = os.Remove(filepath.Join(w.storeDir, tunnel+".conf"))
	return after, nil
}

// lastLine reduces a failed command's output to its last
// meaningful line (the Dart _runAwg convention), falling back
// to the error itself.
func lastLine(out string, err error) string {
	lines := strings.FieldsFunc(out, func(r rune) bool { return r == '\n' || r == '\r' })
	for i := len(lines) - 1; i >= 0; i-- {
		if s := strings.TrimSpace(lines[i]); s != "" {
			return s
		}
	}
	if err != nil {
		return err.Error()
	}
	return "unknown error"
}
