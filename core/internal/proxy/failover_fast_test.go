package proxy

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"
	"time"
)

// Build 2105: FailedFast — the connect-time failover. It must move
// on the FIRST establishment failure (that is the feature), keep
// Failed's strike bookkeeping (avoidance only at the third strike,
// persisted selection when the threshold moves the upstream), skip
// the servers the attempt already tried, and refuse the failures
// that are not the server's fault.

func fastLocation(t *testing.T) []Candidate {
	t.Helper()
	loc := LocationCandidates(failoverCountries(), "DE")
	if len(loc) != 3 {
		t.Fatalf("location has %d candidates, want 3 (Berlin A/B, Frankfurt C)", len(loc))
	}
	return loc
}

func candidateAt(t *testing.T, loc []Candidate, addr string) Candidate {
	t.Helper()
	for _, c := range loc {
		if c.Addr == addr {
			return c
		}
	}
	t.Fatalf("no candidate %s", addr)
	return Candidate{}
}

func TestFailedFastSwitchesOnTheFirstStrike(t *testing.T) {
	loc := fastLocation(t)
	f := NewServerFailover(filepath.Join(t.TempDir(), "selection.json"))
	next, ok, _ := f.FailedFast(loc, candidateAt(t, loc, serverA), errServerReset, nil)
	if !ok {
		t.Fatal("the first establishment failure must already move")
	}
	if next.Addr != serverB {
		t.Fatalf("moved to %s, want the same-city %s", next.Addr, serverB)
	}
	if f.Avoided(serverA) {
		t.Fatal("one strike must not avoid the server — avoidance stays a third-strike consequence")
	}
	if _, ok := PersistedSelection(f.selectionFile, ""); ok {
		t.Fatal("below the threshold nothing is persisted (the caller saves the server that answered)")
	}
}

func TestFailedFastSkipsTriedServers(t *testing.T) {
	loc := fastLocation(t)
	f := NewServerFailover(filepath.Join(t.TempDir(), "selection.json"))
	tried := map[string]bool{serverA: true}
	isTried := func(addr string) bool { return tried[addr] }
	next, ok, _ := f.FailedFast(loc, candidateAt(t, loc, serverA), errServerReset, isTried)
	if !ok || next.Addr != serverB {
		t.Fatalf("first move = %v/%v, want %s", next.Addr, ok, serverB)
	}
	tried[serverB] = true
	next, ok, _ = f.FailedFast(loc, candidateAt(t, loc, serverB), errServerReset, isTried)
	if !ok || next.Addr != serverC {
		t.Fatalf("second move = %v/%v, want the next city %s", next.Addr, ok, serverC)
	}
	tried[serverC] = true
	if _, ok, _ = f.FailedFast(loc, candidateAt(t, loc, serverC), errServerReset, isTried); ok {
		t.Fatal("with every server tried there is nowhere to move")
	}
}

func TestFailedFastRefusesNonServerFaults(t *testing.T) {
	loc := fastLocation(t)
	f := NewServerFailover(filepath.Join(t.TempDir(), "selection.json"))
	for name, err := range map[string]error{
		"cancelled":   context.Canceled,
		"connect 407": &proxyConnectHTTPError{statusCode: http.StatusProxyAuthRequired, status: "407 Proxy Authentication Required"},
		"connect 429": &proxyConnectHTTPError{statusCode: http.StatusTooManyRequests, status: "429 Too Many Requests"},
	} {
		if _, ok, _ := f.FailedFast(loc, candidateAt(t, loc, serverA), err, nil); ok {
			t.Errorf("%s: a non-server fault must not move the upstream", name)
		}
	}
	var nilFailover *ServerFailover
	if _, ok, _ := nilFailover.FailedFast(loc, candidateAt(t, loc, serverA), errServerReset, nil); ok {
		t.Error("a nil failover must not move")
	}
}

func TestFailedFastThirdStrikeAvoidsAndPersists(t *testing.T) {
	loc := fastLocation(t)
	selection := filepath.Join(t.TempDir(), "selection.json")
	f := NewServerFailover(selection)
	a := candidateAt(t, loc, serverA)
	// Three separate connect attempts, each starting on A and
	// failing there: the strikes accumulate across attempts,
	// exactly as Failed's do.
	for i := 1; i <= 3; i++ {
		next, ok, crossed := f.FailedFast(loc, a, errServerReset, nil)
		if !ok || next.Addr != serverB {
			t.Fatalf("attempt %d moved to %v/%v, want %s", i, next.Addr, ok, serverB)
		}
		if crossed != (i == 3) {
			t.Fatalf("attempt %d: crossed = %v, want %v (only the threshold strike reports its own crossing)", i, crossed, i == 3)
		}
		if avoided := f.Avoided(serverA); avoided != (i == 3) {
			t.Fatalf("after attempt %d, A avoided = %v", i, avoided)
		}
	}
	persisted, ok := PersistedSelection(selection, "")
	if !ok || persisted.Addr != serverB {
		t.Fatalf("persisted = %v/%v, want %s (the threshold move saves its target, as Failed does)", persisted.Addr, ok, serverB)
	}
}

// Verification iteration 3 (build 2105): Failed and FailedFast
// count into ONE per-server strike map. Two counters that
// neither summed nor cleared each other let a server fail
// twice on each path and never be avoided — and left stale
// counts behind an avoidance that re-avoided it on one later
// failure.
func TestFailedAndFailedFastShareOneStrikeCount(t *testing.T) {
	loc := fastLocation(t)
	selection := filepath.Join(t.TempDir(), "selection.json")
	f := NewServerFailover(selection)
	a := candidateAt(t, loc, serverA)
	if _, ok := f.Failed(loc, a, errServerReset); ok {
		t.Fatal("the first failure must not move the upstream")
	}
	if _, ok := f.Failed(loc, a, errServerReset); ok {
		t.Fatal("the second failure must not move the upstream")
	}
	if f.Avoided(serverA) {
		t.Fatal("two counted failures must not avoid the server")
	}
	next, ok, _ := f.FailedFast(loc, a, errServerReset, nil)
	if !ok || next.Addr != serverB {
		t.Fatalf("the third counted failure moved to %v/%v, want %s", next.Addr, ok, serverB)
	}
	if !f.Avoided(serverA) {
		t.Fatal("the third counted failure — on either path — must avoid the server")
	}
}

// Verification iteration 4 (build 2105): strikes older than the
// avoidance window are forgotten. A walk that tried a server
// once weeks ago must not leave it one blip away from avoidance
// today: the threshold means failures close in time.
func TestStrikesDecayAfterTheAvoidWindow(t *testing.T) {
	loc := fastLocation(t)
	f := NewServerFailover(filepath.Join(t.TempDir(), "selection.json"))
	a := candidateAt(t, loc, serverA)
	now := time.Now()
	f.now = func() time.Time { return now }
	if _, ok := f.Failed(loc, a, errServerReset); ok {
		t.Fatal("the first failure must not move the upstream")
	}
	now = now.Add(2 * serverAvoidTime)
	if _, ok := f.Failed(loc, a, errServerReset); ok {
		t.Fatal("a failure after the window restarts the count; it must not move the upstream")
	}
	if _, ok := f.Failed(loc, a, errServerReset); ok {
		t.Fatal("two failures inside the window must not move the upstream")
	}
	if f.Avoided(serverA) {
		t.Fatal("stale strikes accumulated across the avoidance window")
	}
	if _, ok := f.Failed(loc, a, errServerReset); !ok {
		t.Fatal("the third failure inside the window must move the upstream")
	}
	if !f.Avoided(serverA) {
		t.Fatal("the third failure inside the window must avoid the server")
	}
}
