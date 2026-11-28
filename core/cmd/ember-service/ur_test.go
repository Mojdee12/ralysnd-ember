package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- fakes ----------------------------------------------------------

type fakeURDevice struct {
	mu           sync.Mutex
	calls        []string
	pinErr       error
	connectErr   error
	connected    bool
	country      string
	connectsToUp int // Connected() turns true on the Nth poll; 0 = never
	polls        int
	countries    []urCountry
	countriesErr error
	closed       bool
	disconnected bool
}

func (f *fakeURDevice) record(call string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
}

func (f *fakeURDevice) PinProvidingOff() error {
	f.record("pin")
	return f.pinErr
}

func (f *fakeURDevice) Connect(country string) error {
	f.record("connect:" + country)
	return f.connectErr
}

func (f *fakeURDevice) Disconnect() {
	f.record("disconnect")
	f.mu.Lock()
	defer f.mu.Unlock()
	f.disconnected = true
	f.connected = false
}

func (f *fakeURDevice) Connected() (bool, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.polls++
	if f.connectsToUp > 0 && f.polls >= f.connectsToUp {
		f.connected = true
	}
	if f.connected {
		return true, f.country
	}
	return false, ""
}

func (f *fakeURDevice) Countries() ([]urCountry, error) {
	f.record("countries")
	return f.countries, f.countriesErr
}

func (f *fakeURDevice) Close() {
	f.record("close")
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
}

func (f *fakeURDevice) callLog() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func fakeJWT(exp time.Time) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	payload, _ := json.Marshal(map[string]int64{"exp": exp.Unix()})
	return header + "." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}

func newTestURManager(factory func(string) (urDevice, error), exchange urExchanger) *urManager {
	return &urManager{
		factory:        factory,
		exchange:       exchange,
		cache:          newURJWTCache(),
		connectTimeout: 2 * time.Second,
		pollDelay:      time.Millisecond,
		now:            time.Now,
	}
}

func okExchange(jwt string, counter *int) urExchanger {
	return func(ctx context.Context, apiKey string) (string, error) {
		if counter != nil {
			*counter++
		}
		return jwt, nil
	}
}

// waitURStatus polls the manager's status until pred holds or
// the deadline passes (connect is asynchronous since FIX-ADV
// B1 — tests follow ur.status exactly like the shell does).
func waitURStatus(t *testing.T, m *urManager, pred func(urStatus) bool) urStatus {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st := m.status()
		if pred(st) {
			return st
		}
		if time.Now().After(deadline) {
			t.Fatalf("status never satisfied the predicate; last = %+v", st)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// ---- JWT cache ------------------------------------------------------

func TestURJWTCacheReuseAndExpiry(t *testing.T) {
	c := newURJWTCache()
	now := time.Now()
	c.now = func() time.Time { return now }

	c.put("urn_key_a", fakeJWT(now.Add(time.Hour)))
	if tok, ok := c.get("urn_key_a"); !ok || tok == "" {
		t.Fatal("a fresh JWT must be served from cache")
	}
	// A different key must not see the first key's token.
	if _, ok := c.get("urn_key_b"); ok {
		t.Fatal("cache leaked a JWT across API keys")
	}
	// Inside the leeway the token counts as expired.
	c.put("urn_key_a", fakeJWT(now.Add(urJWTLeeway-time.Second)))
	if _, ok := c.get("urn_key_a"); ok {
		t.Fatal("a JWT inside the expiry leeway must not be reused")
	}
	// Unparseable tokens are cached only for the conservative
	// TTL (FIX-ADV L3): served inside it, gone beyond it —
	// never caching them would re-exchange (and mint a new
	// client) on every connect.
	c.put("urn_key_a", "not-a-jwt")
	if _, ok := c.get("urn_key_a"); !ok {
		t.Fatal("an unparseable JWT must be cached for the conservative TTL")
	}
	now = now.Add(urJWTUnparseableTTL + time.Minute)
	if _, ok := c.get("urn_key_a"); ok {
		t.Fatal("an unparseable JWT must not outlive the conservative TTL")
	}
	now = now.Add(-(urJWTUnparseableTTL + time.Minute))
	// Invalidate forces re-exchange.
	c.put("urn_key_a", fakeJWT(now.Add(time.Hour)))
	c.invalidate("urn_key_a")
	if _, ok := c.get("urn_key_a"); ok {
		t.Fatal("invalidate must drop the cached JWT")
	}
}

func TestURJWTCacheNeverStoresTheKey(t *testing.T) {
	c := newURJWTCache()
	c.put("urn_super_secret_key", fakeJWT(time.Now().Add(time.Hour)))
	for k := range c.by {
		if strings.Contains(k, "urn_super_secret_key") {
			t.Fatalf("cache map key %q contains the API key", k)
		}
	}
}

func TestJWTExpiryParsing(t *testing.T) {
	exp := time.Unix(1800000000, 0)
	got, ok := jwtExpiry(fakeJWT(exp))
	if !ok || !got.Equal(exp) {
		t.Fatalf("jwtExpiry = %v, %v; want %v, true", got, ok, exp)
	}
	if _, ok := jwtExpiry("a.b"); ok {
		t.Fatal("a two-segment token must not parse")
	}
	if _, ok := jwtExpiry("a.!!!.c"); ok {
		t.Fatal("a non-base64 payload must not parse")
	}
}

// ---- manager contract ----------------------------------------------

func TestURUnavailableWithoutSDK(t *testing.T) {
	m := newTestURManager(nil, okExchange(fakeJWT(time.Now().Add(time.Hour)), nil))
	st := m.status()
	if st.Available || st.Reason == "" || st.Connected {
		t.Fatalf("status without SDK = %+v; want available=false with a reason", st)
	}
	if _, err := m.connect(urConnectParams{APIKey: "urn_x"}); err == nil {
		t.Fatal("connect without the SDK must fail honestly, not fake success")
	}
	if _, err := m.countries(urCountriesParams{APIKey: "urn_x"}); err == nil {
		t.Fatal("countries without the SDK must fail honestly")
	}
}

func TestURConnectPinsProvidingBeforeConnect(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 1, country: "Netherlands"}
	exchanges := 0
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), &exchanges),
	)
	st, err := m.connect(urConnectParams{APIKey: "urn_key"})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	// Asynchronous (FIX-ADV B1): connect returns promptly with
	// the state machine's word; Connected arrives via status.
	if st.State != urStateConnecting && st.State != urStateConnected {
		t.Fatalf("connect return = %+v; want state connecting (or already connected)", st)
	}
	st = waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnected })
	if !st.Connected || st.Country != "Netherlands" {
		t.Fatalf("status after connect = %+v; want connected via the SDK's own report", st)
	}
	calls := dev.callLog()
	if len(calls) < 2 || calls[0] != "pin" || calls[1] != "connect:" {
		t.Fatalf("call order = %v; the providing pin must be applied before connect", calls)
	}
	if exchanges != 1 {
		t.Fatalf("exchanges = %d; want exactly 1", exchanges)
	}
}

func TestURConnectRefusesWhenProvidingPinFails(t *testing.T) {
	dev := &fakeURDevice{pinErr: errors.New("providing could not be pinned OFF")}
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	if _, err := m.connect(urConnectParams{APIKey: "urn_key"}); err != nil {
		t.Fatalf("connect (async accept): %v", err)
	}
	st := waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateFailed })
	if !strings.Contains(st.LastError, "providing could not be pinned OFF") {
		t.Fatalf("failed status = %+v; want the pin failure as lastError", st)
	}
	for _, c := range dev.callLog() {
		if strings.HasPrefix(c, "connect:") {
			t.Fatalf("Connect was called despite the failed pin: %v", dev.callLog())
		}
	}
	if !dev.closed {
		t.Fatal("a device whose pin failed must be closed, not kept")
	}
}

func TestURConnectTimeoutIsHonest(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 0} // never comes up
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	m.connectTimeout = 30 * time.Millisecond
	if _, err := m.connect(urConnectParams{APIKey: "urn_key"}); err != nil {
		t.Fatalf("connect (async accept): %v", err)
	}
	st := waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateFailed })
	if !strings.Contains(st.LastError, "timed out") {
		t.Fatalf("failed status = %+v; want the timeout as lastError", st)
	}
	if !dev.disconnected {
		t.Fatal("a timed-out connect must remove the destination again")
	}
	if st.Connected {
		t.Fatal("status must not claim connected after a timeout")
	}
}

func TestURConnectReusesCachedJWTAndDevice(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 1}
	exchanges := 0
	builds := 0
	m := newTestURManager(
		func(jwt string) (urDevice, error) { builds++; return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), &exchanges),
	)
	for i := 0; i < 2; i++ {
		if _, err := m.connect(urConnectParams{APIKey: "urn_key", Country: "Germany"}); err != nil {
			t.Fatalf("connect %d: %v", i, err)
		}
		waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnected })
		if _, err := m.disconnect(); err != nil {
			t.Fatalf("disconnect %d: %v", i, err)
		}
	}
	if exchanges != 1 || builds != 1 {
		t.Fatalf("exchanges=%d builds=%d; want 1/1 — the JWT is exchanged once and cached", exchanges, builds)
	}
}

func TestURConnectNeedsKey(t *testing.T) {
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return &fakeURDevice{}, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	if _, err := m.connect(urConnectParams{}); err == nil {
		t.Fatal("connect without an API key must fail")
	}
}

func TestURCountriesNeedsKeyBeforeFirstConnect(t *testing.T) {
	dev := &fakeURDevice{countries: []urCountry{{ID: "id-nl", Name: "Netherlands"}}}
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	if _, err := m.countries(urCountriesParams{}); err == nil {
		t.Fatal("countries with no device and no key must fail honestly")
	}
	list, err := m.countries(urCountriesParams{APIKey: "urn_key"})
	if err != nil {
		t.Fatalf("countries with a key: %v", err)
	}
	if len(list) != 1 || list[0].Name != "Netherlands" || list[0].ID != "id-nl" {
		t.Fatalf("countries = %+v", list)
	}
	// With a live device, no key is needed.
	if _, err := m.countries(urCountriesParams{}); err != nil {
		t.Fatalf("countries with a live device: %v", err)
	}
}

func TestURStatusConnectedOnlyFromSDK(t *testing.T) {
	dev := &fakeURDevice{} // destination never set, SDK reports nothing
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	if _, err := m.countries(urCountriesParams{APIKey: "urn_key"}); err != nil {
		t.Fatal(err)
	}
	if st := m.status(); st.Connected {
		t.Fatal("status claimed connected when the SDK reports no provider session")
	}
	if st := m.status(); st.Tunneled {
		t.Fatal("tunneled must stay false until a packet pump exists")
	}
}

// ---- dispatch --------------------------------------------------------

func TestURDispatchShapes(t *testing.T) {
	s := &server{ur: newURManager(), startedAt: time.Now()}
	resp := s.dispatch(request{V: protocolVersion, ID: 7, Method: "ur.status"})
	if !resp.OK {
		t.Fatalf("ur.status dispatch failed: %s", resp.Error)
	}
	raw, err := json.Marshal(resp.Result)
	if err != nil {
		t.Fatal(err)
	}
	var st urStatus
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatalf("ur.status result does not decode as urStatus: %v", err)
	}
	if st.Available {
		t.Fatal("the default (no ur_sdk tag) build must report available=false")
	}
	if st.State != urStateIdle {
		t.Fatalf("ur.status state = %q; want %q (the B1 state machine word is always present)", st.State, urStateIdle)
	}
	resp = s.dispatch(request{V: protocolVersion, ID: 8, Method: "ur.connect", Params: json.RawMessage(`{"apiKey":"urn_x"}`)})
	if resp.OK {
		t.Fatal("ur.connect must fail in a build without the SDK, not fake a connection")
	}
	resp = s.dispatch(request{V: protocolVersion, ID: 9, Method: "ur.disconnect"})
	if !resp.OK {
		t.Fatalf("ur.disconnect with no session must be a clean no-op: %s", resp.Error)
	}
}
