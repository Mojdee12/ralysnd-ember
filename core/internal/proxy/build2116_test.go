package proxy

// Build 2116, batch B1 (core half):
//   - B1-3 renewal journaling: upstream failures are
//     counted by class, the renewal route is recorded,
//     and the counted classes log their lines.
//   - B1-6 (2105-R1): the session pool builds its slots
//     in parallel — a slow server no longer costs
//     size × the session timeout at connect.

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
)

func TestBuild2116UpstreamFailureCounts(t *testing.T) {
	c := &Controller{}
	c.noteUpstreamFailure(errors.New("dial tcp: connection refused"))
	c.noteUpstreamFailure(errors.New("dial tcp: connection refused"))
	c.noteUpstreamFailure(nil) // never counted
	if got := c.upstreamFailureSummary(); !strings.Contains(got, "=") {
		t.Fatalf("summary = %q, want counted classes", got)
	}
	c2 := &Controller{}
	if got := c2.upstreamFailureSummary(); got != "none" {
		t.Fatalf("empty summary = %q, want none", got)
	}
}

func TestBuild2116UpstreamFailureLogsFirstOfClass(t *testing.T) {
	var buf bytes.Buffer
	logx.SetOutput(&buf)
	defer logx.SetOutput(os.Stderr)
	c := &Controller{}
	c.noteUpstreamFailure(errors.New("boom"))
	if !strings.Contains(buf.String(), "upstream failure class=") ||
		!strings.Contains(buf.String(), "count=1") {
		t.Fatalf("log = %q, want the first-of-class line", buf.String())
	}
}

func TestBuild2116RenewalRouteRecorded(t *testing.T) {
	c := &Controller{}
	if got := c.renewalRoute(); got != "unknown" {
		t.Fatalf("route before any renewal = %q, want unknown", got)
	}
	c.setRenewalRoute("direct-fallback")
	if got := c.renewalRoute(); got != "direct-fallback" {
		t.Fatalf("route = %q, want direct-fallback", got)
	}
}

func TestBuild2116PoolBuildsInParallel(t *testing.T) {
	var inFlight atomic.Int32
	var maxInFlight atomic.Int32
	create := func() (proxySession, error) {
		n := inFlight.Add(1)
		for {
			m := maxInFlight.Load()
			if n <= m || maxInFlight.CompareAndSwap(m, n) {
				break
			}
		}
		time.Sleep(250 * time.Millisecond)
		inFlight.Add(-1)
		return &fakeProxySession{}, nil
	}
	start := time.Now()
	pool, err := newProxySessionPool(4, create)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()
	if got := maxInFlight.Load(); got < 2 {
		t.Fatalf("max in-flight creations = %d, want parallel (>1)", got)
	}
	if elapsed > 700*time.Millisecond {
		t.Fatalf("pool build took %s; serial would be ~1s, parallel ~250ms", elapsed)
	}
	live := 0
	for _, s := range pool.sessions {
		if s != nil {
			live++
		}
	}
	if live != 4 {
		t.Fatalf("live slots = %d, want 4", live)
	}
}

func TestBuild2116PoolPartialFailureStands(t *testing.T) {
	var calls atomic.Int32
	create := func() (proxySession, error) {
		if calls.Add(1) == 2 {
			return nil, errors.New("slot refused")
		}
		return &fakeProxySession{}, nil
	}
	pool, err := newProxySessionPool(3, create)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()
	live := 0
	for _, s := range pool.sessions {
		if s != nil {
			live++
		}
	}
	if live != 2 {
		t.Fatalf("live slots = %d, want 2 (partial success stands)", live)
	}
}
