package service

import (
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/proxy"
)

// Build 2105 (proxy.fast_failover): with the flag on, a wake whose
// persisted server is dead connects through the location's other
// server inside the SAME attempt — the first connection test
// already succeeds — and the dead server is NOT avoided (one
// strike is not three). The flag off keeps the shipped behaviour,
// pinned by TestWakeMovesToAnotherServerOfTheLocation.
func TestWakeFastFailoverConnectsOnFirstAttempt(t *testing.T) {
	d := newTestDaemon(t)
	f := newLazyFixture(t)
	addTestAccount(t, d, "user")
	select { // the account change asked for a start; Run starts anyway
	case <-d.restart:
	default:
	}
	noExitCheck(t)
	d.mu.Lock()
	d.cfg.Dashboard.Listen = "127.0.0.1:0"
	d.cfg.Proxy.FastFailover = true
	d.mu.Unlock()
	if controlplane.Transport() != f.controlPlane {
		t.Fatal("the fixture control plane is not installed; requests could reach real endpoints")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := ln.Addr().String()
	_ = ln.Close()
	f.deadServer.Store(&dead)
	if err := proxy.SaveSelection(d.paths.Selection, proxy.Candidate{Addr: dead, CountryCode: "NL", CountryName: "Netherlands", CityCode: "ams", CityName: "Amsterdam"}); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- d.Run() }()
	t.Cleanup(func() {
		d.Shutdown()
		<-done
	})
	waitMessage(t, d, PhaseRunning, "Proxy running")

	client := newDashboardClient(t, d)
	if rec := client.do(http.MethodPost, "/api/test", nil); rec.Code != http.StatusOK {
		t.Fatalf("the first connection test must connect through the other server: %s", rec.Body)
	}
	if d.failover.Avoided(dead) {
		t.Fatal("one failed attempt must not avoid the server — avoidance stays a third-strike consequence")
	}
	view, _ := d.StatusView()
	if view.Proxy == nil || view.Proxy.Upstream != f.upstream {
		t.Fatalf("connected: %+v, want the fixture upstream %s", view.Proxy, f.upstream)
	}
}

// Verification iteration 1 (build 2105): the walk must count
// every failure exactly once. A one-server location whose only
// server is dead has nowhere to move to; counting its failure
// twice per attempt (FailedFast, then Failed again in the tail)
// avoided it after two wakes instead of three, and the last
// server of an exhausted walk was counted nowhere. Here each
// walk is one wake's worth: avoidance must arrive on the third.
func TestEstablishWalkCountsEachFailureOnce(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := ln.Addr().String()
	_ = ln.Close()
	// A real refusal, classified exactly as a dead server's
	// failure is in production.
	_, refused := net.DialTimeout("tcp", dead, time.Second)
	if refused == nil {
		t.Fatal("the dead address answered")
	}
	server := proxy.Candidate{Addr: dead, CountryCode: "NL", CountryName: "Netherlands", CityCode: "ams", CityName: "Amsterdam"}
	location := []proxy.Candidate{server}
	failover := proxy.NewServerFailover(filepath.Join(t.TempDir(), "selection.json"))
	cfg := proxy.ControllerConfig{Server: server}
	calls := 0
	establish := func(proxy.ControllerConfig, time.Time) (*proxy.Controller, error) {
		calls++
		return nil, refused
	}
	for wake := 1; wake <= 3; wake++ {
		calls = 0
		_, _, walked, _, err := establishWalk(establish, cfg, failover, location, time.Now().Add(20*time.Second))
		if err == nil {
			t.Fatal("the walk must fail when the only server is dead")
		}
		if !walked {
			t.Fatal("a walk that ran must say so — the caller must not count the failure again")
		}
		if calls != 1 {
			t.Fatalf("wake %d: establish called %d times, want 1 (nowhere to move to)", wake, calls)
		}
		if avoided := failover.Avoided(dead); avoided != (wake == 3) {
			t.Fatalf("after wake %d: avoided = %v, want %v — one strike per wake, avoidance on the third", wake, avoided, wake == 3)
		}
	}
}

// Verification iteration 2 (build 2105): when a walk crosses a
// server's strike threshold, FailedFast persists the switch —
// the walk must also SURFACE it, or a live engine keeps its
// in-memory selection on the avoided server and every later
// wake starts there (paying its failure again, and never
// earning the wake-backoff waiver a selection change grants).
// Iteration 3: the surfaced target must itself be usable — a
// server the same walk avoided after the switch was persisted
// is not adopted.
func TestEstablishWalkSurfacesTheThresholdSwitch(t *testing.T) {
	deadAddr := func() string {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		_ = ln.Close()
		return addr
	}
	mk := func() proxy.Candidate {
		return proxy.Candidate{Addr: deadAddr(), CountryCode: "NL", CountryName: "Netherlands", CityCode: "ams", CityName: "Amsterdam"}
	}
	a, b, c := mk(), mk(), mk()
	_, refused := net.DialTimeout("tcp", a.Addr, time.Second)
	if refused == nil {
		t.Fatal("the dead address answered")
	}
	location := []proxy.Candidate{a, b, c}
	selection := filepath.Join(t.TempDir(), "selection.json")
	failover := proxy.NewServerFailover(selection)
	cfg := proxy.ControllerConfig{Server: a}
	establish := func(proxy.ControllerConfig, time.Time) (*proxy.Controller, error) {
		return nil, refused
	}
	// A already carries two counted failures; B and C carry
	// none. The walk below is the attempt that crosses A: A is
	// avoided, the failover persists its choice (B or C), the
	// walk tries the other two and counts each of them once —
	// neither crosses. The surfaced switch must be the
	// persisted choice, and the two must agree.
	for i := 0; i < 2; i++ {
		if _, ok, _ := failover.FailedFast(location, a, refused, nil); !ok {
			t.Fatal("the pre-load failures must move within the location")
		}
	}
	_, _, walked, switchTo, err := establishWalk(establish, cfg, failover, location, time.Now().Add(20*time.Second))
	if err == nil || !walked {
		t.Fatalf("walked=%v err=%v", walked, err)
	}
	if !failover.Avoided(a.Addr) {
		t.Fatal("A must be avoided after its third counted failure")
	}
	if switchTo.Addr == "" || switchTo.Addr == a.Addr {
		t.Fatalf("switchTo = %q, want the failover's persisted choice (not A, not empty)", switchTo.Addr)
	}
	if failover.Avoided(switchTo.Addr) {
		t.Fatalf("switchTo = %q is itself avoided — an avoided target must not be surfaced", switchTo.Addr)
	}
	if persisted, ok := proxy.PersistedSelection(selection, ""); !ok || persisted.Addr != switchTo.Addr {
		t.Fatalf("persisted selection = %q/%v, surfaced switch = %q — they must agree", persisted.Addr, ok, switchTo.Addr)
	}
}
