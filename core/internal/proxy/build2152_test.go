package proxy

// Build 2152 (GO-2): the renewal route ladder is completed —
// when the self-egress attempt and the direct fallback both
// fail, acquireRenewalPass makes exactly one more attempt
// through the configured bootstrap egress, whatever the earlier
// failures' class. Before 2152 the only bootstrap retry lived
// inside AccountPool.passFor and fired solely on a clean 451
// from the direct attempt, so a direct failure of any other
// class never reached the bootstrap egress at renewal time.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/accounts"
	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
)

// renewalBootstrapController builds a renewal controller whose
// self-egress is a dead loopback proxy (the live tunnel accepts
// nothing), holding a stored pass, like
// TestRenewalSelfEgressFallsBackDirect.
func renewalBootstrapController(t *testing.T, pool *AccountPool, accs map[string]accounts.Account) *Controller {
	t.Helper()
	storedToken := passJWT("a", time.Now().Add(10*time.Minute))
	stored := storedPassFor(t, storedToken)
	if err := pool.store.SavePass(accs["a"].ID, stored); err != nil {
		t.Fatal(err)
	}
	return renewalController(pool, guardian.DefaultEndpoint, "http://127.0.0.1:1", storedToken, stored)
}

// The direct fallback fails with an HTTP 400 — not a clean 451,
// so passFor's own bootstrap retry never fires — and the pass
// still lands, through the Worker-relay bootstrap egress, with
// the renewal route labelled "bootstrap" and exactly one relay
// fetch.
func TestRenewalFallsThroughToBootstrapEgress(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	fetchedToken := passJWT("a", time.Now().Add(9*time.Minute))
	var relayHits atomic.Int32
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		switch {
		case r.URL.Host == "vpn.mozilla.org":
			// The direct fallback: a non-451 failure.
			return coreResponse(r, http.StatusBadRequest, `{"error":"bad_request"}`, nil), nil
		case r.URL.Host == "relay.invalid" && strings.HasPrefix(r.URL.Path, "/guardian.mozilla.org/"):
			relayHits.Add(1)
			return coreResponse(r, http.StatusOK, `{"token":"`+fetchedToken+`"}`, quotaHeader(3)), nil
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	if err := controlplane.SetBootstrapRelay("https://relay.invalid", "test-key"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controlplane.ClearBootstrap)

	controller := renewalBootstrapController(t, pool, accs)
	_, pass, err := controller.acquireRenewalPass(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if pass.RawToken != fetchedToken {
		t.Fatal("the renewal did not return the bootstrap-fetched pass")
	}
	if got := relayHits.Load(); got != 1 {
		t.Fatalf("bootstrap relay fetches = %d, want exactly 1", got)
	}
	if got := controller.renewalRoute(); got != "bootstrap" {
		t.Fatalf("renewal route = %q, want %q", got, "bootstrap")
	}
}

// With no bootstrap egress configured, the ladder ends at the
// direct fallback: its failure stands and the route names it.
func TestRenewalWithoutBootstrapEndsAtDirectFallback(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "vpn.mozilla.org" {
			return coreResponse(r, http.StatusBadRequest, `{"error":"bad_request"}`, nil), nil
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	controlplane.ClearBootstrap()

	controller := renewalBootstrapController(t, pool, accs)
	if _, _, err := controller.acquireRenewalPass(context.Background()); err == nil {
		t.Fatal("expected the direct failure to stand with no bootstrap configured")
	}
	if got := controller.renewalRoute(); got != "direct-fallback" {
		t.Fatalf("renewal route = %q, want %q", got, "direct-fallback")
	}
}

// A failing bootstrap attempt does not mask the direct
// fallback's error: the original failure is the renewal's
// outcome, and the route stays "direct-fallback".
func TestRenewalBootstrapFailureKeepsDirectError(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	var relayHits atomic.Int32
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		switch {
		case r.URL.Host == "vpn.mozilla.org":
			return coreResponse(r, http.StatusBadRequest, `{"error":"bad_request"}`, nil), nil
		case r.URL.Host == "relay.invalid":
			relayHits.Add(1)
			return coreResponse(r, http.StatusBadRequest, `{"error":"bad_request"}`, nil), nil
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	if err := controlplane.SetBootstrapRelay("https://relay.invalid", "test-key"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controlplane.ClearBootstrap)

	controller := renewalBootstrapController(t, pool, accs)
	_, _, err := controller.acquireRenewalPass(context.Background())
	if err == nil {
		t.Fatal("expected the renewal to fail when every route fails")
	}
	var httpErr *guardian.HTTPError
	if !errors.As(err, &httpErr) || httpErr.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected the direct 400 failure to stand, got %v", err)
	}
	if got := relayHits.Load(); got != 1 {
		t.Fatalf("bootstrap relay fetches = %d, want exactly 1", got)
	}
	if got := controller.renewalRoute(); got != "direct-fallback" {
		t.Fatalf("renewal route = %q, want %q", got, "direct-fallback")
	}
}
