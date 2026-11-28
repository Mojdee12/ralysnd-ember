package main

import (
	"errors"
	"fmt"
	"regexp"
	"sync"
	"time"
)

// The process manager: owns every child process the service
// starts on the app's behalf — engine cores and helpers — with
// line-streamed output, exit records and plain state. It knows
// nothing about any engine's semantics; a child is a name, an
// executable from the allowlist under a registered app root, and
// arguments the app chose.

var (
	// The executables the service will ever start. Anything else
	// is refused: the pipe is reachable by the owner's user, and
	// the service runs as SYSTEM, so the allowlist plus the app
	// root confinement is what keeps the pipe from becoming a
	// general elevated launcher.
	allowedExes = map[string]bool{
		"lanternd.exe":         true,
		"aether.exe":           true,
		"usque.exe":            true,
		"sing-box.exe":         true,
		"openvpn.exe":          true,
		"ember-tun-bridge.exe": true,
		// The shell's own engine cores (electron ENGINE_CFG),
		// reconciled 2026-11-28 (2041 audit B-2/C1): without
		// these four every V2Ray/Mozilla/Psiphon/WireGuard
		// start was refused. TestAllowlistReconciledWithShell
		// keeps this map and the shell's table in lockstep.
		"xray.exe":             true,
		"firefox-vpn-core.exe": true,
		"psiphon-core.exe":     true,
		"amneziawg.exe":        true,
		// DPI Lab (2042 Phase 3): the shell's ByeDpiController
		// starts the shipped ciadpi.exe sidecar via proc.start.
		"ciadpi.exe": true,
		// lantern-bridge.exe is REMOVED: the 2041 package no
		// longer ships it (dead entry).
		// warp-plus.exe is RETIRED (scout verdict 2026-11-28):
		// WARP is a WireGuard profile on the WG engine now.
	}
	nameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)
)

// procSpec is one proc.start request.
type procSpec struct {
	Name    string            `json:"name"`
	Exe     string            `json:"exe"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	WorkDir string            `json:"workDir,omitempty"`
	Stdin   bool              `json:"stdin,omitempty"`
}

// procState is the recorded state of one named child.
type procState struct {
	Name      string `json:"name"`
	Running   bool   `json:"running"`
	PID       int    `json:"pid,omitempty"`
	ExitCode  int    `json:"exitCode"`
	Exited    bool   `json:"exited"`
	StartedAt int64  `json:"startedAtMs,omitempty"`
	LastError string `json:"lastError,omitempty"`
}

// child is one running process, abstracted so tests can fake it.
type child interface {
	PID() int
	// Lines delivers merged stdout/stderr lines until the child
	// exits; the channel closes after the final line.
	Lines() <-chan childLine
	WriteLine(s string) error
	CloseStdin() error
	Kill() error
	Wait() (int, error)
}

type childLine struct {
	Stream string // "stdout" or "stderr"
	Line   string
}

type launcher interface {
	Launch(spec procSpec) (child, error)
}

// broadcaster fans events out to every connected client.
type broadcaster struct {
	mu   sync.Mutex
	subs map[chan event]struct{}
}

func newBroadcaster() *broadcaster {
	return &broadcaster{subs: make(map[chan event]struct{})}
}

func (b *broadcaster) subscribe() chan event {
	ch := make(chan event, 256)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *broadcaster) unsubscribe(ch chan event) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

func (b *broadcaster) emit(ev event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs {
		select {
		case ch <- ev:
		default:
			// A slow client drops events rather than stalling
			// every engine's lifecycle. State is always
			// recoverable through proc.state / tun.state.
		}
	}
}

type procRecord struct {
	state procState
	child child
	done  chan struct{}
	stdin bool // the child was started with an open stdin pipe
}

type manager struct {
	mu    sync.Mutex
	procs map[string]*procRecord
	// starting holds the names with a start currently in
	// flight (review W4): the already-running check and the
	// launch used to be separated by an unlock, so two
	// concurrent starts for one name both launched and the
	// second record overwrote the first, orphaning its child.
	starting map[string]bool
	launcher launcher
	events   *broadcaster
	roots    *rootSet
	now      func() time.Time
	hooks    []func(name, stream, line string)
}

// addLineHook registers an internal observer of child output
// (the TUN manager parses the bridge helper's line protocol
// this way). Hooks run on the pump goroutine: keep them fast.
func (m *manager) addLineHook(h func(name, stream, line string)) {
	m.mu.Lock()
	m.hooks = append(m.hooks, h)
	m.mu.Unlock()
}

func newManager(l launcher, events *broadcaster, roots *rootSet) *manager {
	return &manager{
		procs:    make(map[string]*procRecord),
		starting: make(map[string]bool),
		launcher: l,
		events:   events,
		roots:    roots,
		now:      time.Now,
	}
}

func (m *manager) start(spec procSpec) (procState, error) {
	if !nameRe.MatchString(spec.Name) {
		return procState{}, fmt.Errorf("bad process name %q", spec.Name)
	}
	if err := m.roots.checkExe(spec.Exe); err != nil {
		return procState{}, err
	}
	// Claim the name BEFORE launching (review W4): the mark
	// is taken under the same lock as the already-running
	// check and held across the launch, so a concurrent start
	// for the same name is refused instead of launching a
	// second child the first record would orphan.
	m.mu.Lock()
	if rec, ok := m.procs[spec.Name]; ok && rec.state.Running {
		m.mu.Unlock()
		return procState{}, fmt.Errorf("%s is already running", spec.Name)
	}
	if m.starting == nil {
		m.starting = make(map[string]bool)
	}
	if m.starting[spec.Name] {
		m.mu.Unlock()
		return procState{}, fmt.Errorf("start already in progress for %s", spec.Name)
	}
	m.starting[spec.Name] = true
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		delete(m.starting, spec.Name)
		m.mu.Unlock()
	}()

	// A previous instance of the same executable that this
	// service does not own (the app or the service crashed
	// earlier) must not hold the engine's ports or identity.
	// Children the service DOES own (e.g. the other Aether
	// slot, same aether.exe) are never touched.
	m.mu.Lock()
	owned := make(map[int]bool)
	for _, rec := range m.procs {
		if rec.state.Running && rec.state.PID > 0 {
			owned[rec.state.PID] = true
		}
	}
	m.mu.Unlock()
	reapExePath(spec.Exe, owned)

	c, err := m.launcher.Launch(spec)
	if err != nil {
		return procState{}, fmt.Errorf("start %s: %w", spec.Name, err)
	}
	rec := &procRecord{
		state: procState{
			Name:      spec.Name,
			Running:   true,
			PID:       c.PID(),
			ExitCode:  -1,
			StartedAt: m.now().UnixMilli(),
		},
		child: c,
		done:  make(chan struct{}),
		stdin: spec.Stdin,
	}
	m.mu.Lock()
	m.procs[spec.Name] = rec
	m.mu.Unlock()

	go m.pump(rec)
	return rec.state, nil
}

// pump streams the child's lines as events and records its exit.
func (m *manager) pump(rec *procRecord) {
	for ln := range rec.child.Lines() {
		m.mu.Lock()
		hooks := m.hooks
		m.mu.Unlock()
		for _, h := range hooks {
			// A panicking line hook must not kill the pump
			// goroutine — and with it the whole service
			// (2041 audit A3). The line is still emitted.
			func() {
				defer func() { _ = recover() }()
				h(rec.state.Name, ln.Stream, ln.Line)
			}()
		}
		m.events.emit(event{V: protocolVersion, Event: "proc.output", Data: map[string]interface{}{
			"name":   rec.state.Name,
			"stream": ln.Stream,
			"line":   ln.Line,
		}})
	}
	code, werr := rec.child.Wait()
	m.mu.Lock()
	rec.state.Running = false
	rec.state.Exited = true
	rec.state.ExitCode = code
	if werr != nil && rec.state.LastError == "" {
		rec.state.LastError = werr.Error()
	}
	m.mu.Unlock()
	close(rec.done)
	m.events.emit(event{V: protocolVersion, Event: "proc.exit", Data: map[string]interface{}{
		"name": rec.state.Name,
		"code": code,
	}})
}

func (m *manager) state(name string) procState {
	m.mu.Lock()
	defer m.mu.Unlock()
	if rec, ok := m.procs[name]; ok {
		return rec.state
	}
	return procState{Name: name, ExitCode: -1}
}

func (m *manager) states() []procState {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]procState, 0, len(m.procs))
	for _, rec := range m.procs {
		out = append(out, rec.state)
	}
	return out
}

func (m *manager) write(name, line string) error {
	m.mu.Lock()
	rec, ok := m.procs[name]
	m.mu.Unlock()
	if !ok || !rec.state.Running {
		return fmt.Errorf("%s is not running", name)
	}
	return rec.child.WriteLine(line)
}

// closeStdin delivers EOF to a running child's stdin — the
// step that completes the config-fed flow (proc.start with
// stdin:true, proc.write lines, then proc.close-stdin): cores
// like Xray read their config until EOF before serving. Safe
// to call on any name: an unknown or stdin-less process gets a
// clear error, never a panic.
func (m *manager) closeStdin(name string) error {
	m.mu.Lock()
	rec, ok := m.procs[name]
	m.mu.Unlock()
	if !ok || !rec.state.Running {
		return fmt.Errorf("%s is not running", name)
	}
	if !rec.stdin {
		return fmt.Errorf("%s was started without stdin", name)
	}
	return rec.child.CloseStdin()
}

// stop closes stdin first (children like the TUN bridge end
// their session politely on stdin close), waits a grace period,
// then kills.
func (m *manager) stop(name string) (procState, error) {
	m.mu.Lock()
	rec, ok := m.procs[name]
	m.mu.Unlock()
	if !ok {
		return procState{Name: name, ExitCode: -1}, fmt.Errorf("%s is not running", name)
	}
	if !rec.state.Running {
		return rec.state, nil
	}
	_ = rec.child.CloseStdin()
	select {
	case <-rec.done:
	case <-time.After(1500 * time.Millisecond):
		_ = rec.child.Kill()
		select {
		case <-rec.done:
		case <-time.After(2 * time.Second):
		}
	}
	return m.state(name), nil
}

// stopAll ends every child; used on service shutdown so no
// engine outlives the service.
func (m *manager) stopAll() {
	m.mu.Lock()
	names := make([]string, 0, len(m.procs))
	for name, rec := range m.procs {
		if rec.state.Running {
			names = append(names, name)
		}
	}
	m.mu.Unlock()
	for _, name := range names {
		_, _ = m.stop(name)
	}
}

var errNoRoot = errors.New("executable is outside every registered app folder")

// rootSet is the set of app folders the service will run
// executables from. Roots are recorded ONLY at install time
// (install_windows.go, via loadRoots/saveRoots in config.go)
// plus the service exe's own parent folder (config.go). A
// hello handshake can never add one (2041 audit B-S1): any
// pipe client could otherwise register a folder it controls
// and have this SYSTEM service launch a same-named binary
// from it — a complete local privilege escalation.
type rootSet struct {
	mu    sync.Mutex
	roots []string // cleaned absolute paths
}

func newRootSet(roots []string) *rootSet {
	r := &rootSet{}
	for _, root := range roots {
		r.add(root)
	}
	return r
}

func (r *rootSet) add(root string) {
	if root == "" {
		return
	}
	clean := cleanPath(root)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, have := range r.roots {
		if have == clean {
			return
		}
	}
	r.roots = append(r.roots, clean)
}

func (r *rootSet) list() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.roots...)
}

// has reports whether root is already a recorded root,
// comparing canonical forms so spelling differences (case,
// separators, dot segments) cannot disguise a foreign folder
// as a recorded one or vice versa.
func (r *rootSet) has(root string) bool {
	want := canonicalPath(root)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, have := range r.roots {
		if canonicalPath(have) == want {
			return true
		}
	}
	return false
}

// checkExe confines a start to an allowlisted executable name
// under a registered root. Both sides are compared in
// canonical form (paths.go canonicalPath): ".." segments and
// symlinks are resolved before the separator-bounded prefix
// test, so a traversal like <root>\..\..\Temp\sing-box.exe —
// which the old string-prefix check waved through — is
// refused (2041 audit B-S3).
func (r *rootSet) checkExe(exe string) error {
	base := baseName(exe)
	if !allowedExes[base] {
		return fmt.Errorf("%s is not an Ember engine executable", base)
	}
	clean := canonicalPath(exe)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, root := range r.roots {
		if underRoot(clean, canonicalPath(root)) {
			return nil
		}
	}
	return errNoRoot
}
