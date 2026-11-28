package main

// FIX-ADV regression locks (Phase-3 adversarial review):
//   B1 — ur.connect is asynchronous, the manager mutex is never
//        held across the exchange/poll, disconnect cancels and
//        wins, and ur.status carries the state machine.
//   L2 — ur.countries never answers for account B from account
//        A's live device; the ur.countries dispatch surfaces
//        malformed-params errors.
//   L3 — a failed device rebuild leaves the old device/session
//        alive (build-before-close in ensureDevice).

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// ---- B1 -------------------------------------------------------------

func TestURConnectReturnsPromptlyWhileExchangeIsSlow(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 1}
	slowExchange := func(ctx context.Context, apiKey string) (string, error) {
		select {
		case <-time.After(3 * time.Second):
			return fakeJWT(time.Now().Add(time.Hour)), nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		slowExchange,
	)
	start := time.Now()
	st, err := m.connect(urConnectParams{APIKey: "urn_key"})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("connect (async accept): %v", err)
	}
	if elapsed > 1500*time.Millisecond {
		t.Fatalf("connect took %s; the asynchronous accept must return promptly", elapsed)
	}
	if st.State != urStateConnecting {
		t.Fatalf("connect return state = %q; want %q", st.State, urStateConnecting)
	}
	waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnected })
}

func TestURManagerMutexFreeDuringProviderPoll(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 0, countries: []urCountry{{ID: "id-nl", Name: "Netherlands"}}} // never comes up
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	m.connectTimeout = 30 * time.Second // the poll would hold a naive lock for ages
	if _, err := m.connect(urConnectParams{APIKey: "urn_key"}); err != nil {
		t.Fatalf("connect (async accept): %v", err)
	}
	// Wait until the attempt has built its device.
	deadline := time.Now().Add(5 * time.Second)
	for {
		m.mu.Lock()
		built := m.device != nil
		m.mu.Unlock()
		if built {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the connect attempt never built its device")
		}
		time.Sleep(2 * time.Millisecond)
	}
	// While the provider poll is still running, status and
	// countries must answer promptly — neither may queue behind
	// the attempt.
	done := make(chan []urCountry, 1)
	go func() {
		_ = m.status()
		list, err := m.countries(urCountriesParams{})
		if err != nil {
			done <- nil
			return
		}
		done <- list
	}()
	select {
	case list := <-done:
		if len(list) != 1 || list[0].Name != "Netherlands" {
			t.Fatalf("countries during the poll = %+v", list)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("status/countries blocked behind the in-flight connect — the mutex is held across the poll")
	}
	if _, err := m.disconnect(); err != nil {
		t.Fatalf("disconnect: %v", err)
	}
}

func TestURDisconnectDuringConnectingWins(t *testing.T) {
	dev := &fakeURDevice{connectsToUp: 0} // provider search never completes
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	m.connectTimeout = 30 * time.Second
	if _, err := m.connect(urConnectParams{APIKey: "urn_key"}); err != nil {
		t.Fatalf("connect (async accept): %v", err)
	}
	waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnecting })
	// The destination exists only once the attempt has built
	// its device and issued Connect — wait for the build.
	deadline := time.Now().Add(5 * time.Second)
	for {
		m.mu.Lock()
		built := m.device != nil
		m.mu.Unlock()
		if built {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the connect attempt never built its device")
		}
		time.Sleep(2 * time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond) // let the attempt issue its Connect
	st, err := m.disconnect()
	if err != nil {
		t.Fatalf("disconnect: %v", err)
	}
	if st.State != urStateIdle {
		t.Fatalf("disconnect status = %+v; want state idle", st)
	}
	// Even if the SDK later reports a session, the cancelled
	// attempt must not resurrect the connection: disconnect won.
	dev.mu.Lock()
	dev.connected = true
	dev.mu.Unlock()
	time.Sleep(150 * time.Millisecond)
	if st := m.status(); st.State != urStateIdle {
		t.Fatalf("status after disconnect = %+v; the cancelled attempt published over the disconnect", st)
	}
	if !dev.disconnected {
		t.Fatal("disconnect must remove the SDK destination")
	}
}

// ---- L2 -------------------------------------------------------------

func TestURCountriesKeyMismatchUsesTempDevice(t *testing.T) {
	jwtA := fakeJWT(time.Now().Add(time.Hour))
	jwtB := fakeJWT(time.Now().Add(2 * time.Hour))
	devA := &fakeURDevice{connectsToUp: 1, countries: []urCountry{{ID: "id-a", Name: "A-land"}}}
	devB := &fakeURDevice{countries: []urCountry{{ID: "id-b", Name: "B-land"}}}
	m := newTestURManager(
		func(jwt string) (urDevice, error) {
			if jwt == jwtB {
				return devB, nil
			}
			return devA, nil
		},
		func(ctx context.Context, apiKey string) (string, error) {
			if apiKey == "urn_b" {
				return jwtB, nil
			}
			return jwtA, nil
		},
	)
	if _, err := m.connect(urConnectParams{APIKey: "urn_a"}); err != nil {
		t.Fatalf("connect: %v", err)
	}
	waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnected })

	// A countries call FOR account B must not be answered from
	// account A's live device.
	list, err := m.countries(urCountriesParams{APIKey: "urn_b"})
	if err != nil {
		t.Fatalf("countries for B: %v", err)
	}
	if len(list) != 1 || list[0].Name != "B-land" {
		t.Fatalf("countries for B = %+v; want B's own list from a temp device", list)
	}
	for _, c := range devA.callLog() {
		if c == "countries" {
			t.Fatal("the live device of account A was asked for account B's countries")
		}
	}
	if !devB.closed {
		t.Fatal("the temp device must be closed after answering")
	}
	// The live session is undisturbed, and a call for A (or with
	// no key) is answered from the live device as before.
	if st := m.status(); !st.Connected {
		t.Fatal("the temp-device countries call disturbed the live session")
	}
	list, err = m.countries(urCountriesParams{APIKey: "urn_a"})
	if err != nil || len(list) != 1 || list[0].Name != "A-land" {
		t.Fatalf("countries for A = %+v, %v; want the live device's list", list, err)
	}
}

func TestURCountriesDispatchSurfacesParamsError(t *testing.T) {
	s := &server{ur: newURManager(), startedAt: time.Now()}
	resp := s.dispatch(request{V: protocolVersion, ID: 11, Method: "ur.countries",
		Params: json.RawMessage(`{"apiKey":123}`)})
	if resp.OK {
		t.Fatal("ur.countries with a malformed apiKey must fail, not degrade to a misleading key error")
	}
	if strings.Contains(resp.Error, "needs an API key") {
		t.Fatalf("ur.countries error = %q; the params error must surface, not the no-key error", resp.Error)
	}
}

// ---- L3 -------------------------------------------------------------

func TestURFailedAccountSwitchKeepsOldDevice(t *testing.T) {
	jwtA := fakeJWT(time.Now().Add(time.Hour))
	jwtB := fakeJWT(time.Now().Add(2 * time.Hour))
	devA := &fakeURDevice{connectsToUp: 1, country: "Netherlands"}
	m := newTestURManager(
		func(jwt string) (urDevice, error) {
			if jwt == jwtB {
				return nil, errors.New("factory boom")
			}
			return devA, nil
		},
		func(ctx context.Context, apiKey string) (string, error) {
			if apiKey == "urn_b" {
				return jwtB, nil
			}
			return jwtA, nil
		},
	)
	if _, err := m.connect(urConnectParams{APIKey: "urn_a"}); err != nil {
		t.Fatalf("connect A: %v", err)
	}
	waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateConnected })

	// Switching to account B fails at the factory: the attempt
	// reports failed, but account A's device/session survives —
	// the replacement is built fully before the old one closes.
	if _, err := m.connect(urConnectParams{APIKey: "urn_b"}); err != nil {
		t.Fatalf("connect B (async accept): %v", err)
	}
	st := waitURStatus(t, m, func(s urStatus) bool { return s.State == urStateFailed })
	if !strings.Contains(st.LastError, "could not be created") {
		t.Fatalf("failed status = %+v; want the factory failure as lastError", st)
	}
	if devA.closed {
		t.Fatal("a failed account switch closed the previously working device")
	}
	if !st.Connected {
		t.Fatalf("status = %+v; account A's SDK session must still be reported", st)
	}
}
