package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

// A scripted fake child for the manager/TUN tests: emits the
// lines it is given, then exits with the given code when its
// lines are drained (or when killed / stdin closed).

type fakeChild struct {
	pid    int
	lines  chan childLine
	done   chan struct{}
	code   int
	killed bool
}

func newFakeChild(pid int, script []childLine, code int) *fakeChild {
	c := &fakeChild{pid: pid, lines: make(chan childLine, len(script)+1), code: code, done: make(chan struct{})}
	for _, ln := range script {
		c.lines <- ln
	}
	return c
}

func (c *fakeChild) PID() int                 { return c.pid }
func (c *fakeChild) Lines() <-chan childLine  { return c.lines }
func (c *fakeChild) WriteLine(string) error   { return nil }
func (c *fakeChild) CloseStdin() error        { c.finish(); return nil }
func (c *fakeChild) Kill() error              { c.killed = true; c.finish(); return nil }
func (c *fakeChild) finish() {
	select {
	case <-c.done:
	default:
		close(c.done)
		close(c.lines)
	}
}
func (c *fakeChild) Wait() (int, error) { <-c.done; return c.code, nil }

type fakeLauncher struct {
	children map[string]*fakeChild // keyed by exe base name
}

func (f fakeLauncher) Launch(spec procSpec) (child, error) {
	if c, ok := f.children[baseName(spec.Exe)]; ok {
		return c, nil
	}
	c := newFakeChild(4242, nil, 0)
	go func() { time.Sleep(10 * time.Millisecond); c.finish() }()
	return c, nil
}

func testServer(t *testing.T, children map[string]*fakeChild) (*server, net.Listener) {
	t.Helper()
	roots := newRootSet([]string{"/apps/ember"})
	events := newBroadcaster()
	mgr := newManager(fakeLauncher{children: children}, events, roots)
	srv := &server{mgr: mgr, tun: newTunManager(mgr, events), ovpn: newOvpnManager(mgr, events), warp: newWarpManager(), roots: roots, events: events, startedAt: time.Now()}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go srv.serve(ln)
	t.Cleanup(func() { ln.Close() })
	return srv, ln
}

func dial(t *testing.T, ln net.Listener) *pipeClient {
	t.Helper()
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c := &pipeClient{conn: conn, sc: bufio.NewScanner(conn)}
	c.sc.Buffer(make([]byte, 4096), 1<<20)
	t.Cleanup(func() { conn.Close() })
	return c
}

func TestHelloAndConfinement(t *testing.T) {
	_, ln := testServer(t, nil)
	c := dial(t, ln)
	out, err := c.call("hello", map[string]interface{}{"appRoot": "/apps/ember"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "ralysnd-ember-service") {
		t.Fatalf("hello = %s", out)
	}
	// An executable outside the allowlist is refused.
	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "evil", "exe": "/apps/ember/notepad.exe",
	}); err == nil {
		t.Fatal("expected refusal for a non-allowlisted exe")
	}
	// An allowlisted exe outside every root is refused.
	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "aether", "exe": "/elsewhere/aether.exe",
	}); err == nil {
		t.Fatal("expected refusal for an exe outside the roots")
	}
}

func TestProcLifecycleAndEvents(t *testing.T) {
	child := newFakeChild(777, []childLine{
		{Stream: "stdout", Line: "ready"},
		{Stream: "stderr", Line: "warn"},
	}, 3)
	_, ln := testServer(t, map[string]*fakeChild{"aether.exe": child})
	c := dial(t, ln)
	st, err := c.call("proc.start", map[string]interface{}{
		"name": "aether-masque", "exe": "/apps/ember/aether/aether.exe",
	})
	if err != nil {
		t.Fatal(err)
	}
	var started procState
	if err := json.Unmarshal(st, &started); err != nil || !started.Running || started.PID != 777 {
		t.Fatalf("start state = %s err=%v", st, err)
	}
	go child.finish()
	code, ok := c.waitExit("aether-masque", 5*time.Second)
	if !ok || code != 3 {
		t.Fatalf("exit event code=%d ok=%v", code, ok)
	}
	st, err = c.call("proc.state", map[string]interface{}{"name": "aether-masque"})
	if err != nil {
		t.Fatal(err)
	}
	var ended procState
	if err := json.Unmarshal(st, &ended); err != nil || ended.Running || !ended.Exited || ended.ExitCode != 3 {
		t.Fatalf("end state = %s", st)
	}
	// Output lines were streamed as events.
	found := false
	for _, ev := range c.events {
		if ev.Event == "proc.output" && ev.Data["line"] == "ready" {
			found = true
		}
	}
	if !found {
		t.Fatal("proc.output event for 'ready' not seen")
	}
}

func TestTunSessionLifecycle(t *testing.T) {
	bridge := newFakeChild(888, []childLine{
		{Stream: "stdout", Line: "UP Ember index=7 luid=1 proxy=127.0.0.1:12080"},
	}, 0)
	_, ln := testServer(t, map[string]*fakeChild{"ember-tun-bridge.exe": bridge})
	c := dial(t, ln)
	st, err := c.call("tun.start", map[string]interface{}{
		"name": "lantern", "exe": "/apps/ember/core/ember-tun-bridge.exe",
		"socksPort": 12080, "skip": []string{"lanternd.exe"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var ts tunState
	if err := json.Unmarshal(st, &ts); err != nil || ts.State != "starting" {
		t.Fatalf("tun start = %s", st)
	}
	// The UP line turns the session up with the adapter named.
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := c.call("tun.state", nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(st, &ts); err == nil && ts.State == "up" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("tun never came up: %s", st)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if ts.Adapter != "Ember" {
		t.Fatalf("adapter = %q", ts.Adapter)
	}
	// A second session while one is held is refused plainly.
	if _, err := c.call("tun.start", map[string]interface{}{
		"name": "xray", "exe": "/apps/ember/core/ember-tun-bridge.exe", "socksPort": 10808,
	}); err == nil {
		t.Fatal("expected refusal for a second TUN session")
	}
	// Stop ends the session (stdin close finishes the fake).
	if _, err := c.call("tun.stop", nil); err != nil {
		t.Fatal(err)
	}
	st, _ = c.call("tun.state", nil)
	if err := json.Unmarshal(st, &ts); err != nil || ts.State != "idle" {
		t.Fatalf("after stop = %s", st)
	}
}

func TestRootSetChecks(t *testing.T) {
	r := newRootSet([]string{`C:\Program Files\Ralysnd Ember`})
	if err := r.checkExe(`C:\Program Files\Ralysnd Ember\core\ember-tun-bridge.exe`); err != nil {
		t.Fatal(err)
	}
	if err := r.checkExe(`C:\Windows\System32\aether.exe`); err == nil {
		t.Fatal("expected refusal outside the root")
	}
	if err := r.checkExe(`C:\Program Files\Ralysnd Ember\evil.exe`); err == nil {
		t.Fatal("expected refusal for a non-allowlisted exe")
	}
}
