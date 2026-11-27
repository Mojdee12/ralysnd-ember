package proxy

// Build 2114 (mozilla-regression-plan.md): the renewal must
// fetch a fresh pass — through the live tunnel when the
// engine's listener is known — the persisted server choice
// expires after 24 h, and a saturated pool slot falls through
// to the next slot instead of failing the tunnel.

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
	"github.com/armanlife/firefox-vpn-client/core/internal/serverlist"
)

// passJWT builds a pass token like accountJWT but with an
// explicit expiry, so a stored pass and a fetched pass are
// guaranteed different strings.
func passJWT(sub string, exp time.Time) string {
	iat := exp.Add(-10 * time.Minute).Unix()
	claims := fmt.Sprintf(`{"sub":%q,"aud":"https://vpn.mozilla.org","iss":"https://vpn.mozilla.org","iat":%d,"nbf":%d,"exp":%d}`, sub, iat, iat, exp.Unix())
	return "e30." + base64.RawURLEncoding.EncodeToString([]byte(claims)) + ".local-only"
}

func storedPassFor(t *testing.T, token string) *guardian.ProxyPassInfo {
	t.Helper()
	pass, err := guardian.RestorePass(token, "53687091200", "48318382080", quotaReset.Format(time.RFC3339), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return pass
}

// A forced acquisition must fetch even while a stored pass is
// still valid: the renewal path (AcquirePassForced) exists
// because the unforced reuse margin (1 min) sits below the
// renewal lead (2 min), so a scheduled renewal re-adopted the
// expiring pass until its last minute.
func TestAcquirePassForcedFetchesFreshPass(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	storedToken := passJWT("a", time.Now().Add(10*time.Minute))
	fetchedToken := passJWT("a", time.Now().Add(9*time.Minute))
	var guardianCalls atomic.Int32
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		guardianCalls.Add(1)
		return coreResponse(r, http.StatusOK, `{"token":"`+fetchedToken+`"}`, quotaHeader(3)), nil
	})
	if err := pool.store.SavePass(accs["a"].ID, storedPassFor(t, storedToken)); err != nil {
		t.Fatal(err)
	}

	_, pass, err := pool.AcquirePassForced(context.Background(), "https://guardian.invalid")
	if err != nil {
		t.Fatal(err)
	}
	if guardianCalls.Load() == 0 {
		t.Fatal("AcquirePassForced made no Guardian call despite the forced fetch")
	}
	if pass.RawToken != fetchedToken {
		t.Fatalf("AcquirePassForced returned the stored pass, want the fetched one")
	}
}

// A renewal adopts the freshly fetched pass, not the stored
// one it replaces — the controller-level form of the margin
// inversion, with no self-egress configured (direct fetch).
func TestRenewalFetchesFreshPass(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	storedToken := passJWT("a", time.Now().Add(10*time.Minute))
	fetchedToken := passJWT("a", time.Now().Add(9*time.Minute))
	var guardianCalls atomic.Int32
	setCoreControlPlane(t, func(r *http.Request) (*http.Response, error) {
		guardianCalls.Add(1)
		return coreResponse(r, http.StatusOK, `{"token":"`+fetchedToken+`"}`, quotaHeader(3)), nil
	})
	stored := storedPassFor(t, storedToken)
	if err := pool.store.SavePass(accs["a"].ID, stored); err != nil {
		t.Fatal(err)
	}
	session := &fakeProxySession{}
	controller := &Controller{
		accounts: pool,
		guardian: "https://guardian.invalid",
		done:     make(chan struct{}),
		current: &managedSession{
			session:   session,
			rawToken:  storedToken,
			expiresAt: stored.ExpiresAt(),
			accepting: true,
		},
	}
	if err := controller.renewLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if guardianCalls.Load() == 0 {
		t.Fatal("the renewal made no Guardian call — it reused the stored pass")
	}
	if controller.current.rawToken != fetchedToken {
		t.Fatalf("the session still holds the stored pass after renewal")
	}
	if got := session.currentToken(); got != fetchedToken {
		t.Fatalf("the session token = %q, want the fetched pass", got)
	}
}

// guardianServer is a real (loopback HTTP) Guardian endpoint
// answering every pass fetch with token; hits counts requests.
func guardianServer(t *testing.T, token string, hits *atomic.Int32) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		for k, vs := range quotaHeader(3) {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"token":"`+token+`"}`)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// renewalController builds a controller whose session holds
// the stored pass, renewing against guardianURL.
func renewalController(pool *AccountPool, guardianURL, selfEgress, storedToken string, stored *guardian.ProxyPassInfo) *Controller {
	return &Controller{
		accounts:   pool,
		guardian:   guardianURL,
		selfEgress: selfEgress,
		done:       make(chan struct{}),
		current: &managedSession{
			session:   &fakeProxySession{},
			rawToken:  storedToken,
			expiresAt: stored.ExpiresAt(),
			accepting: true,
		},
	}
}

// With a self-egress endpoint configured, the renewal's
// Guardian fetch rides the engine's own listener (the fake
// proxy here) instead of going direct: the proxy sees the
// request, and the fetched pass is adopted.
func TestRenewalThroughSelfEgress(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	storedToken := passJWT("a", time.Now().Add(10*time.Minute))
	fetchedToken := passJWT("a", time.Now().Add(9*time.Minute))
	stored := storedPassFor(t, storedToken)
	if err := pool.store.SavePass(accs["a"].ID, stored); err != nil {
		t.Fatal(err)
	}
	var guardianHits atomic.Int32
	guardianSrv := guardianServer(t, fetchedToken, &guardianHits)

	var proxyHits atomic.Int32
	proxySrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxyHits.Add(1)
		out, err := http.NewRequestWithContext(r.Context(), r.Method, r.URL.String(), r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		out.Header = r.Header.Clone()
		resp, err := http.DefaultTransport.RoundTrip(out)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		for k, vs := range resp.Header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
	}))
	t.Cleanup(proxySrv.Close)

	controller := renewalController(pool, guardianSrv.URL, proxySrv.URL, storedToken, stored)
	if err := controller.renewLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if proxyHits.Load() == 0 {
		t.Fatal("the renewal never used the self-egress proxy")
	}
	if guardianHits.Load() == 0 {
		t.Fatal("the Guardian endpoint was never reached")
	}
	if controller.current.rawToken != fetchedToken {
		t.Fatal("the session still holds the stored pass after the self-egress renewal")
	}
}

// When the self-egress path fails (a dead listener — the pass
// already expired and the tunnel accepts nothing), the
// renewal falls back to the direct fetch instead of failing.
func TestRenewalSelfEgressFallsBackDirect(t *testing.T) {
	pool, accs := newTestAccountPool(t, "a")
	storedToken := passJWT("a", time.Now().Add(10*time.Minute))
	fetchedToken := passJWT("a", time.Now().Add(9*time.Minute))
	stored := storedPassFor(t, storedToken)
	if err := pool.store.SavePass(accs["a"].ID, stored); err != nil {
		t.Fatal(err)
	}
	var guardianHits atomic.Int32
	guardianSrv := guardianServer(t, fetchedToken, &guardianHits)

	controller := renewalController(pool, guardianSrv.URL, "http://127.0.0.1:1", storedToken, stored)
	if err := controller.renewLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if guardianHits.Load() == 0 {
		t.Fatal("the renewal never fell back to the direct fetch")
	}
	if controller.current.rawToken != fetchedToken {
		t.Fatal("the session still holds the stored pass after the fallback renewal")
	}
}

// A persisted selection older than the TTL is not reused: the
// resolver picks afresh from the server list. Within the TTL
// the persisted choice still stands.
func TestSelectionPersistTTL(t *testing.T) {
	t.Parallel()

	countries := []serverlist.Country{{
		Name: "Japan",
		Code: "JP",
		Cities: []serverlist.City{{
			Name: "Tokyo",
			Code: "TYO",
			Servers: []serverlist.Server{
				{Hostname: "one.example", Port: 443},
				{Hostname: "two.example", Port: 443},
			},
		}},
	}}
	persisted := Candidate{
		Addr:        "one.example:443",
		CountryName: "Japan",
		CountryCode: "JP",
		CityName:    "Tokyo",
		CityCode:    "TYO",
	}

	write := func(age time.Duration) string {
		path := filepath.Join(t.TempDir(), "selection.json")
		if err := SaveSelection(path, persisted); err != nil {
			t.Fatal(err)
		}
		when := time.Now().Add(-age)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
		return path
	}

	got, fromState, err := ResolveWithStateAndCountry("", "", countries, write(23*time.Hour), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !fromState || got.Addr != persisted.Addr {
		t.Fatalf("a %s-old selection must still be reused: got %#v fromState=%v", 23*time.Hour, got, fromState)
	}

	got, fromState, err = ResolveWithStateAndCountry("", "", countries, write(25*time.Hour), nil)
	if err != nil {
		t.Fatal(err)
	}
	if fromState {
		t.Fatalf("a %s-old selection must not be reused, got %#v", 25*time.Hour, got)
	}
	if got.Addr != "one.example:443" && got.Addr != "two.example:443" {
		t.Fatalf("the fresh pick is not a server-list entry: %#v", got)
	}
}

// A saturated first slot no longer fails the tunnel: the pool
// tries the next slot, and the saturated session is neither
// retired nor closed — it is busy, not dead. Only when every
// slot is saturated does the saturation error stand.
func TestPoolSaturatedSlotFallsThrough(t *testing.T) {
	t.Parallel()

	saturated := &fakeProxySession{openErr: fmt.Errorf("%w: no free stream", errSessionSaturated)}
	live := &fakeProxySession{}
	sessions := []proxySession{saturated, live}
	var created atomic.Int32
	pool, err := newProxySessionPool(len(sessions), func() (proxySession, error) {
		return sessions[int(created.Add(1))-1], nil
	})
	if err != nil {
		t.Fatalf("newProxySessionPool returned error: %v", err)
	}
	defer pool.Close()

	// The first probe starts at slot 0 (round-robin start) —
	// the saturated one.
	conn, err := pool.OpenTunnel("example.com:443")
	if err != nil {
		t.Fatalf("OpenTunnel returned error: %v", err)
	}
	_ = conn.Close()
	if got := live.openCount.Load(); got != 1 {
		t.Fatalf("the live slot opened %d tunnels, want 1", got)
	}
	if got := saturated.closeCount.Load(); got != 0 {
		t.Fatalf("the saturated session was closed %d times; saturation must not retire it", got)
	}

	// Both slots saturated: the saturation error stands.
	saturated2 := &fakeProxySession{openErr: errSessionSaturated}
	live.openErr = errSessionSaturated
	pool2, err := newProxySessionPool(2, func() (proxySession, error) {
		if created.Add(1)%2 == 1 {
			return saturated2, nil
		}
		return live, nil
	})
	if err != nil {
		t.Fatalf("newProxySessionPool returned error: %v", err)
	}
	defer pool2.Close()
	if _, err := pool2.OpenTunnel("example.com:443"); !errors.Is(err, errSessionSaturated) {
		t.Fatalf("all slots saturated: got %v, want errSessionSaturated", err)
	}
}
