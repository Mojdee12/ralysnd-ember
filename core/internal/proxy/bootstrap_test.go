package proxy

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
)

// A stored, still-valid pass must be served without any Guardian
// call: that is the prepared-pass contract the whole bootstrap
// exists for.
func TestAcquirePassUsesStoredPass(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	var guardianCalls atomic.Int32
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		guardianCalls.Add(1)
		return nil, fmt.Errorf("unexpected control-plane request %s", r.URL)
	})

	stored, err := guardian.RestorePass(accountJWT("a"), "53687091200", "48318382080", quotaReset.Format(time.RFC3339), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := pool.store.SavePass(accs["a"].ID, stored); err != nil {
		t.Fatal(err)
	}

	_, pass, err := pool.AcquirePass(context.Background(), "https://guardian.invalid")
	if err != nil {
		t.Fatal(err)
	}
	if pass.RawToken != stored.RawToken {
		t.Fatal("AcquirePass did not return the stored pass")
	}
	if guardianCalls.Load() != 0 {
		t.Fatalf("Guardian was called %d times despite a valid stored pass", guardianCalls.Load())
	}
}

// A pass fetched directly is persisted for the next start.
func TestAcquirePassPersistsFetchedPass(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		return coreResponse(r, http.StatusOK, `{"token":"`+accountJWT("a")+`"}`, quotaHeader(3)), nil
	})

	if _, _, err := pool.AcquirePass(context.Background(), "https://guardian.invalid"); err != nil {
		t.Fatal(err)
	}
	stored, ok, err := pool.store.LoadPass(accs["a"].ID)
	if err != nil || !ok {
		t.Fatalf("LoadPass after fetch: ok=%v err=%v", ok, err)
	}
	if stored.Claims.Sub != "a" {
		t.Fatalf("stored pass sub = %q, want a", stored.Claims.Sub)
	}
}

// The region retry: Guardian answers 451 directly; through the
// Worker-relay egress the same fetch is rewritten to the relay
// (path form + relay key, Guardian at the contract's host) and
// succeeds — and the pass lands in the store.
func TestAcquirePassRetriesThroughBootstrapRelay(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	var sawRelayKey atomic.Value
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		switch {
		case r.URL.Host == "vpn.mozilla.org":
			// The direct fetch: region-blocked.
			return coreResponse(r, http.StatusUnavailableForLegalReasons, `{"error":"unavailable_in_region"}`, nil), nil
		case r.URL.Host == "relay.invalid" && strings.HasPrefix(r.URL.Path, "/guardian.mozilla.org/"):
			sawRelayKey.Store(r.Header.Get("X-Relay-Key"))
			return coreResponse(r, http.StatusOK, `{"token":"`+accountJWT("a")+`"}`, quotaHeader(3)), nil
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	if err := controlplane.SetBootstrapRelay("https://relay.invalid", "test-key"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controlplane.ClearBootstrap)

	_, pass, err := pool.AcquirePass(context.Background(), guardian.DefaultEndpoint)
	if err != nil {
		t.Fatal(err)
	}
	if pass.Claims.Sub != "a" {
		t.Fatalf("pass sub = %q, want a", pass.Claims.Sub)
	}
	if key, _ := sawRelayKey.Load().(string); key != "test-key" {
		t.Fatalf("relay key header = %q, want test-key", key)
	}
	if _, ok, err := pool.store.LoadPass(accs["a"].ID); err != nil || !ok {
		t.Fatalf("bootstrap-fetched pass was not stored: ok=%v err=%v", ok, err)
	}
}

// Without a bootstrap egress, a 451 stays a 451 — no silent retry.
func TestAcquirePassRegionBlockedWithoutBootstrap(t *testing.T) {
	pool, _ := newTestAccountPool(t, "a")
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		return coreResponse(r, http.StatusUnavailableForLegalReasons, `{"error":"unavailable_in_region"}`, nil), nil
	})
	controlplane.ClearBootstrap()

	_, _, err := pool.AcquirePass(context.Background(), guardian.DefaultEndpoint)
	if err == nil {
		t.Fatal("expected the region error to surface")
	}
	if got := FailureCode(err); got != FailureRegion {
		t.Fatalf("failure code = %q, want %q (err=%v)", got, FailureRegion, err)
	}
}
