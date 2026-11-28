package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Regression locks for the 2042 repair build (2041 audit
// A1/A3, B-S1, B-S3). Each test names the behaviour the fix
// protects; each was verified to FAIL against the pre-fix
// behaviour and pass after (critical_fix_regression_lock).

// stdinFakeChild is a fake child that records the lines written
// to it and observes stdin EOF: on CloseStdin it finishes, the
// way a config-fed core proceeds once its config is complete.
type stdinFakeChild struct {
	pid   int
	lines chan childLine
	done  chan struct{}

	mu      sync.Mutex
	written []string
	eof     bool
}

func newStdinFakeChild(pid int) *stdinFakeChild {
	return &stdinFakeChild{pid: pid, lines: make(chan childLine, 4), done: make(chan struct{})}
}

func (c *stdinFakeChild) PID() int                { return c.pid }
func (c *stdinFakeChild) Lines() <-chan childLine { return c.lines }
func (c *stdinFakeChild) WriteLine(s string) error {
	c.mu.Lock()
	c.written = append(c.written, s)
	c.mu.Unlock()
	return nil
}
func (c *stdinFakeChild) CloseStdin() error {
	c.mu.Lock()
	c.eof = true
	c.mu.Unlock()
	c.finish()
	return nil
}
func (c *stdinFakeChild) Kill() error { c.finish(); return nil }
func (c *stdinFakeChild) finish() {
	select {
	case <-c.done:
	default:
		close(c.done)
		close(c.lines)
	}
}
func (c *stdinFakeChild) Wait() (int, error) { <-c.done; return 0, nil }
func (c *stdinFakeChild) sawEOF() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.eof
}
func (c *stdinFakeChild) writtenLines() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.written...)
}

type stdinFakeLauncher struct{ child *stdinFakeChild }

func (l stdinFakeLauncher) Launch(procSpec) (child, error) { return l.child, nil }

func pipeServer(t *testing.T, l launcher, roots *rootSet) (*server, net.Listener) {
	t.Helper()
	events := newBroadcaster()
	mgr := newManager(l, events, roots)
	srv := &server{mgr: mgr, tun: newTunManager(mgr, events), ovpn: newOvpnManager(mgr, events), warp: newWarpManager(), roots: roots, events: events, startedAt: time.Now()}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go srv.serve(ln)
	t.Cleanup(func() { ln.Close() })
	return srv, ln
}

// A1: the config-fed flow — proc.start{stdin:true} →
// proc.write lines → proc.close-stdin — must deliver the
// lines and then EOF to the child. Before 2042 there was no
// proc.close-stdin method at all, so the flow could never
// complete.
func TestCloseStdinFlow(t *testing.T) {
	fc := newStdinFakeChild(999)
	_, ln := pipeServer(t, stdinFakeLauncher{child: fc}, newRootSet([]string{"/apps/ember"}))
	c := dial(t, ln)

	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "xray", "exe": "/apps/ember/xray/xray.exe", "stdin": true,
	}); err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{`{"inbounds":[]}`, `{"outbounds":[]}`} {
		if _, err := c.call("proc.write", map[string]interface{}{"name": "xray", "line": line}); err != nil {
			t.Fatal(err)
		}
	}
	if fc.sawEOF() {
		t.Fatal("child saw EOF before proc.close-stdin")
	}
	if _, err := c.call("proc.close-stdin", map[string]interface{}{"name": "xray"}); err != nil {
		t.Fatal(err)
	}
	if !fc.sawEOF() {
		t.Fatal("child never observed EOF after proc.close-stdin")
	}
	if got := fc.writtenLines(); len(got) != 2 || got[0] != `{"inbounds":[]}` || got[1] != `{"outbounds":[]}` {
		t.Fatalf("written lines = %v", got)
	}
	// The child proceeded (exited) once its config was complete.
	code, ok := c.waitExit("xray", 5*time.Second)
	if !ok || code != 0 {
		t.Fatalf("exit event code=%d ok=%v", code, ok)
	}
	// Unknown names get a clear error, never a panic.
	if _, err := c.call("proc.close-stdin", map[string]interface{}{"name": "nope"}); err == nil {
		t.Fatal("expected an error closing stdin of an unknown process")
	}
}

// A1 (manager half): closeStdin on a process started WITHOUT
// stdin is a clear error and must not touch the child.
func TestCloseStdinWithoutStdinRefused(t *testing.T) {
	fc := newStdinFakeChild(555)
	_, ln := pipeServer(t, stdinFakeLauncher{child: fc}, newRootSet([]string{"/apps/ember"}))
	c := dial(t, ln)
	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "xray", "exe": "/apps/ember/xray/xray.exe",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.call("proc.close-stdin", map[string]interface{}{"name": "xray"}); err == nil ||
		!strings.Contains(err.Error(), "without stdin") {
		t.Fatalf("close-stdin error = %v", err)
	}
	if fc.sawEOF() {
		t.Fatal("child stdin was closed despite the refusal")
	}
}

// A3 (dispatch half): a panicking handler returns an error
// frame and the SAME connection keeps serving requests.
func TestDispatchSurvivesPanic(t *testing.T) {
	srv, ln := testServer(t, nil)
	srv.dispatchHook = func(method string) {
		if method == "service.status" {
			panic("boom")
		}
	}
	c := dial(t, ln)
	if _, err := c.call("service.status", nil); err == nil ||
		!strings.Contains(err.Error(), "internal error") {
		t.Fatalf("panicking call error = %v", err)
	}
	out, err := c.call("hello", map[string]interface{}{"appRoot": "/apps/ember"})
	if err != nil {
		t.Fatalf("connection did not survive the panic: %v", err)
	}
	if !strings.Contains(string(out), "ralysnd-ember-service") {
		t.Fatalf("hello after panic = %s", out)
	}
}

// A3 (pump half): a panicking line hook must not kill the
// pump goroutine — the child's exit is still recorded.
func TestPumpSurvivesPanickingHook(t *testing.T) {
	fc := newFakeChild(31337, []childLine{{Stream: "stdout", Line: "hello"}}, 7)
	roots := newRootSet([]string{"/apps/ember"})
	mgr := newManager(fakeLauncher{children: map[string]*fakeChild{"aether.exe": fc}}, newBroadcaster(), roots)
	mgr.addLineHook(func(string, string, string) { panic("hook boom") })
	if _, err := mgr.start(procSpec{Name: "aether", Exe: "/apps/ember/aether/aether.exe"}); err != nil {
		t.Fatal(err)
	}
	go fc.finish()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := mgr.state("aether")
		if st.Exited {
			if st.ExitCode != 7 {
				t.Fatalf("exit code = %d", st.ExitCode)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("pump never recorded the exit: %+v", st)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// B-S1: hello must NOT register a root the installer never
// recorded. The handshake still succeeds (reply shape is
// unchanged for the real shell), the foreign root is ignored,
// and a start from it is refused.
func TestHelloForeignRootNotRegistered(t *testing.T) {
	srv, ln := testServer(t, nil)
	before := srv.roots.list()
	c := dial(t, ln)
	out, err := c.call("hello", map[string]interface{}{"appRoot": "/evil/root"})
	if err != nil {
		t.Fatal(err)
	}
	var hello struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(out, &hello); err != nil || hello.Name != "ralysnd-ember-service" {
		t.Fatalf("hello reply = %s err=%v", out, err)
	}
	if srv.roots.has("/evil/root") {
		t.Fatal("hello registered a foreign root")
	}
	if got := srv.roots.list(); len(got) != len(before) {
		t.Fatalf("roots changed by hello: %v -> %v", before, got)
	}
	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "aether", "exe": "/evil/root/aether.exe",
	}); err == nil {
		t.Fatal("expected refusal for a start from the foreign root")
	}
	// A hello naming an already-recorded root is fine.
	if _, err := c.call("hello", map[string]interface{}{"appRoot": "/apps/ember"}); err != nil {
		t.Fatal(err)
	}
}

// B-S3: confinement must resolve ".." and symlinks before the
// prefix test. The pre-fix string-prefix check waved a
// traversal straight through.
func TestCheckExeTraversalRefused(t *testing.T) {
	r := newRootSet([]string{`C:\Apps\Ember`})
	if err := r.checkExe(`C:\Apps\Ember\core\ember-tun-bridge.exe`); err != nil {
		t.Fatalf("legitimate in-root exe refused: %v", err)
	}
	if err := r.checkExe(`C:\Apps\Ember\..\..\Temp\sing-box.exe`); err == nil {
		t.Fatal("traversal path was accepted")
	}
	if err := r.checkExe(`C:\Windows\System32\aether.exe`); err == nil {
		t.Fatal("plain outside path was accepted")
	}
	// A sibling whose name merely extends the root's must not
	// pass the prefix test either.
	if err := r.checkExe(`C:\Apps\Ember2\xray.exe`); err == nil {
		t.Fatal("sibling-prefix path was accepted")
	}
}

// B-S3 (real filesystem): a symlink inside the root that
// points outside it resolves to its real target and is
// refused; a real in-root file is accepted.
func TestCheckExeSymlinkEscapeRefused(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "app")
	outside := filepath.Join(dir, "outside")
	if err := os.MkdirAll(filepath.Join(root, "core"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(root, "core", "xray.exe")
	if err := os.WriteFile(real, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(outside, "xray.exe")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The link's NAME is allowlisted (xray.exe), so the
	// confinement — not the allowlist — is what must refuse it.
	escape := filepath.Join(root, "core", "escape")
	if err := os.MkdirAll(escape, 0o755); err != nil {
		t.Fatal(err)
	}
	linked := filepath.Join(escape, "xray.exe")
	if err := os.Symlink(target, linked); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	r := newRootSet([]string{root})
	if err := r.checkExe(real); err != nil {
		t.Fatalf("legitimate in-root exe refused: %v", err)
	}
	if err := r.checkExe(linked); err == nil {
		t.Fatal("symlink escape was accepted")
	}
	if err := r.checkExe(filepath.Join(root, "..", "outside", "xray.exe")); err == nil {
		t.Fatal("dot-dot escape was accepted")
	}
}
