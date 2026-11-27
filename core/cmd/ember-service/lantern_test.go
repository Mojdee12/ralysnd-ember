package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"testing"
)

// The Lantern proxy, exercised end to end against a real
// HTTP server — the wire shape the radiance daemon speaks
// (plain HTTP over its pipe; a loopback listener stands in
// for the pipe in the test).
func TestLanternCallAllowlistAndAuth(t *testing.T) {
	roots := newRootSet([]string{"/apps/ember"})
	events := newBroadcaster()
	mgr := newManager(fakeLauncher{children: map[string]*fakeChild{
		"lanternd.exe": newFakeChild(555, nil, 0),
	}}, events, roots)
	lm := newLanternManager(mgr)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		_ = http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"path":%q,"method":%q}`, r.URL.Path, r.Method)
		}))
	}()

	var authedPID int
	lm.authenticate = func(pid int, exePath string) error {
		authedPID = pid
		if exePath != "/apps/ember/lantern/lanternd.exe" {
			return fmt.Errorf("unexpected exe %q", exePath)
		}
		return nil
	}
	lm.dial = func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "tcp", ln.Addr().String())
	}

	if _, err := lm.start(lanternStartParams{Exe: "/apps/ember/lantern/lanternd.exe"}); err != nil {
		t.Fatal(err)
	}
	res, err := lm.call(lanternCallParams{Method: "GET", Path: "/vpn/status"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != 200 || authedPID != 555 {
		t.Fatalf("call = %+v authedPID=%d", res, authedPID)
	}
	if got := string(res.Body); got != `{"path":"/vpn/status","method":"GET"}` {
		t.Fatalf("body = %s", got)
	}
	// Not on the allowlist: refused before any dial.
	if _, err := lm.call(lanternCallParams{Method: "DELETE", Path: "/vpn/status"}); err == nil {
		t.Fatal("expected allowlist refusal")
	}
	if _, err := lm.call(lanternCallParams{Method: "GET", Path: "/admin/config"}); err == nil {
		t.Fatal("expected allowlist refusal for /admin/config")
	}
	// A failed authentication refuses the call.
	lm.mu.Lock()
	lm.client = nil
	lm.authedPID = 0
	lm.mu.Unlock()
	lm.authenticate = func(pid int, exePath string) error { return fmt.Errorf("impostor") }
	if _, err := lm.call(lanternCallParams{Method: "GET", Path: "/servers"}); err == nil {
		t.Fatal("expected authentication refusal")
	}
}
