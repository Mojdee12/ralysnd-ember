package main

// The URnetwork (bringyour) REAL SDK engine driver — REPAIR 2042,
// workstream SVC-UR. Dispatch: ur.status / ur.connect /
// ur.disconnect / ur.countries are wired in server.go.
//
// Shape (proven on Android 2156/2157 and re-verified against the
// vendor Go SDK, github.com/urnetwork/sdk/v2026
// v2026.11.22-1105365180, MPL-2.0):
//
//   - The shell hands the service the account's `urn_` API key per
//     connect (the key lives in the shell's vault). The service
//     exchanges it ONCE via POST /network/auth-client at
//     https://api.bringyour.com (Bearer <key>) for a client JWT
//     (`by_client_jwt`, 30-day lifetime). The JWT is cached IN
//     MEMORY ONLY, keyed by a hash of the API key; the key itself
//     is never logged, never written to disk, and never retained
//     beyond the call that carried it. Re-exchange happens only
//     when the cached JWT is expired / inside the expiry leeway
//     (each exchange mints a NEW client on the account, so
//     exchanging per connect would burn the client limit).
//   - Connect = the SDK device's destination set to Best
//     Available (ConnectLocationId.BestAvailable) or to a chosen
//     country location. "Connected" is reported ONLY from the
//     SDK's own state query (the established, identity-verified
//     provider sessions, GetConnectedProviderLocations) — never
//     from "the connect request was accepted".
//   - Connect is ASYNCHRONOUS (FIX-ADV B1): ur.connect validates,
//     kicks the attempt off in a goroutine and returns the state
//     machine's current word at once; the shell follows progress
//     through ur.status (state: idle / connecting / connected /
//     failed, plus lastError). The manager mutex is never held
//     across the JWT exchange or the provider poll — it guards
//     state reads/writes only — and ur.disconnect cancels an
//     in-flight attempt (context cancel + generation bump) and
//     wins over it.
//   - PROVIDING IS PINNED OFF: immediately after construction
//     the binding sets ProvideModeNone and reads it back; if the
//     pin does not hold, connect refuses to proceed. The vendor's
//     ConnectViewController (which force-enables
//     ProvideModePublic) is never used — this driver talks to the
//     DeviceLocal API directly, exactly like the Android glue.
//
// TUN / data plane (SVC-UR2): the SDK device consumes/produces
// raw IP packets (SendPacket / AddReceivePacketCallback) — the
// host pumps packets between it and a TUN adapter. That pump
// now exists: ur_pump.go (lifecycle) + ur_pump_windows.go (a
// dedicated Wintun adapter, "Ralysnd Ember UR" — separate from
// the ember-tun-bridge helper, which forwards to a SOCKS proxy
// and exposes no raw packet fd). The manager starts the pump
// once the SDK reports an established provider session; a pump
// that fails to start fails the connect honestly rather than
// leaving a "connected" session that carries no traffic (the
// 2154 failure shape). ur.status.tunneled is the pump's own
// running state. Where no pump can exist (a build without the
// SDK, or a non-Windows build), tunneled stays false.
//
// The SDK itself sits behind the urDevice interface below. The
// real binding lives in ur_sdk.go behind the `ur_sdk` build tag
// (the SDK module requires Go >= 1.27.4; since SVC-UR2 this
// module pins go 1.27.4, requires the SDK, and the shipped
// service is built with the tag — see the build note in
// ur_sdk.go). Without the tag, urDeviceFactory is nil and every
// ur.* method answers truthfully: available=false with the
// reason.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ---- contract types -------------------------------------------------

type urConnectParams struct {
	APIKey string `json:"apiKey"`
	// Country is a location id from ur.countries, or a country
	// name; empty means Best Available.
	Country string `json:"country,omitempty"`
}

type urCountriesParams struct {
	// APIKey is optional: with a live device (post-connect) the
	// session's own API serves the list. Without a device, a key
	// is required to build one — the list is account API data,
	// not public data this service can invent.
	APIKey string `json:"apiKey,omitempty"`
}

type urCountry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type urStatus struct {
	Available bool   `json:"available"`
	Reason    string `json:"reason,omitempty"`
	Connected bool   `json:"connected"`
	Country   string `json:"country,omitempty"`
	// Tunneled reports whether system traffic is actually being
	// captured for this engine: the Wintun packet pump's own
	// running state (ur_pump.go), never inferred from Connected.
	// Present so the shell never has to guess it from Connected.
	Tunneled bool `json:"tunneled"`
	// State is the connect state machine's word (FIX-ADV B1):
	// idle | connecting | connected | failed. Connected above
	// still comes only from the SDK's own session query; State
	// is what the shell follows after the asynchronous
	// ur.connect returns.
	State string `json:"state"`
	// LastError carries the most recent connect failure's
	// message when State is "failed" (empty otherwise). No
	// secret material ever lands here — connect errors never
	// include the API key.
	LastError string `json:"lastError,omitempty"`
}

// The urStatus.State words (FIX-ADV B1).
const (
	urStateIdle       = "idle"
	urStateConnecting = "connecting"
	urStateConnected  = "connected"
	urStateFailed     = "failed"
)

const urUnavailableReason = "the URnetwork SDK engine is not compiled into this service build (build the service with the ur_sdk tag and Go >= 1.27.4 — see ur_sdk.go)"

// ---- SDK boundary ---------------------------------------------------

// urDevice is the slice of the vendor SDK device this driver
// uses. The real implementation is ur_sdk.go (build tag
// ur_sdk); tests substitute a fake. All state answers must come
// from the SDK itself — implementations must not cache a
// "connected" they invented.
type urDevice interface {
	// PinProvidingOff sets ProvideModeNone and verifies by
	// reading the mode back from the SDK. An error means the
	// pin did not hold and the device must not be connected.
	PinProvidingOff() error
	// Connect sets the destination: "" = Best Available,
	// otherwise a location id or country name to resolve.
	Connect(country string) error
	// Disconnect removes the destination.
	Disconnect()
	// Connected reports the SDK's own session state: true only
	// when at least one provider session is established, plus
	// the exit country the SDK reports for it.
	Connected() (connected bool, country string)
	// Countries lists the SDK's country locations (id + name).
	Countries() ([]urCountry, error)
	Close()
}

// urDeviceFactory builds a device from a client JWT. Set by
// ur_sdk.go's init when the SDK is compiled in; nil otherwise.
var urDeviceFactory func(jwt string) (urDevice, error)

// urExchanger turns an API key into a client JWT.
type urExchanger func(ctx context.Context, apiKey string) (string, error)

// ---- JWT cache (memory only) ---------------------------------------

// urJWTCache caches client JWTs by a SHA-256 of the API key.
// The key itself is never stored. A JWT is reused until it is
// inside urJWTLeeway of its `exp` claim. A token whose exp
// cannot be parsed is cached only for a short conservative TTL
// (FIX-ADV L3): never caching it at all would re-exchange on
// every connect, and each exchange mints a NEW client on the
// account — the exact burn this cache exists to prevent. The
// fallback is logged once (no token material in the log line).
type urJWTCache struct {
	mu  sync.Mutex
	now func() time.Time
	by  map[string]urJWTEntry
	// warnedUnparseable latches the one-time log line for the
	// unparseable-exp fallback above.
	warnedUnparseable bool
}

type urJWTEntry struct {
	token string
	exp   time.Time
}

const urJWTLeeway = 5 * time.Minute

// urJWTUnparseableTTL is the conservative cache lifetime for a
// client JWT whose `exp` claim cannot be parsed (FIX-ADV L3).
const urJWTUnparseableTTL = 10 * time.Minute

func newURJWTCache() *urJWTCache {
	return &urJWTCache{now: time.Now, by: map[string]urJWTEntry{}}
}

func urKeyHash(apiKey string) string {
	sum := sha256.Sum256([]byte(apiKey))
	return hex.EncodeToString(sum[:])
}

// jwtExpiry extracts the `exp` claim from a JWT without
// verifying the signature (the token came straight from the
// vendor API over TLS; expiry is a cache hint, not auth).
func jwtExpiry(token string) (time.Time, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp <= 0 {
		return time.Time{}, false
	}
	return time.Unix(claims.Exp, 0), true
}

func (c *urJWTCache) get(apiKey string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.by[urKeyHash(apiKey)]
	if !ok {
		return "", false
	}
	if !c.now().Before(e.exp.Add(-urJWTLeeway)) {
		delete(c.by, urKeyHash(apiKey))
		return "", false
	}
	return e.token, true
}

func (c *urJWTCache) put(apiKey, token string) {
	exp, ok := jwtExpiry(token)
	c.mu.Lock()
	defer c.mu.Unlock()
	if !ok {
		// Unparseable exp: cache conservatively instead of not
		// at all (FIX-ADV L3 — see the type comment). The log
		// line fires once and carries no token material.
		if !c.warnedUnparseable {
			c.warnedUnparseable = true
			log.Printf("ember-service: ur: a client JWT's expiry could not be parsed; caching it for %s only", urJWTUnparseableTTL)
		}
		exp = c.now().Add(urJWTUnparseableTTL)
	}
	c.by[urKeyHash(apiKey)] = urJWTEntry{token: token, exp: exp}
}

// invalidate drops a cached JWT (e.g. after the SDK rejected
// it), forcing the next connect to re-exchange.
func (c *urJWTCache) invalidate(apiKey string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.by, urKeyHash(apiKey))
}

// ---- the auth-client exchange --------------------------------------

const urAPIBase = "https://api.bringyour.com"

// exchangeURJWT is the production exchanger: POST
// /network/auth-client with the API key as the Bearer
// credential — the exact key-only flow proven live in the
// Android spike (HTTP 200 -> {by_client_jwt, client_id}).
// The key is used for this request only and never logged.
func exchangeURJWT(ctx context.Context, apiKey string) (string, error) {
	body, err := json.Marshal(map[string]string{
		"description": "Ralysnd Ember (Windows service)",
		"device_spec": "windows",
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, urAPIBase+"/network/auth-client", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("ur: auth-client exchange failed: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("ur: auth-client exchange failed: %w", err)
	}
	var out struct {
		ByClientJWT string `json:"by_client_jwt"`
		Error       *struct {
			Message string `json:"message"`
		} `json:"error,omitempty"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", fmt.Errorf("ur: auth-client exchange returned an unreadable response (HTTP %d)", resp.StatusCode)
	}
	if out.Error != nil && out.Error.Message != "" {
		return "", fmt.Errorf("ur: auth-client refused the API key: %s", out.Error.Message)
	}
	if resp.StatusCode != http.StatusOK || out.ByClientJWT == "" {
		return "", fmt.Errorf("ur: auth-client exchange failed (HTTP %d) — the API key was not accepted", resp.StatusCode)
	}
	return out.ByClientJWT, nil
}

// ---- the manager -----------------------------------------------------

type urManager struct {
	// mu guards ONLY the state below (device/pump pointers and
	// the state machine). It is never held across the JWT
	// exchange, a device build, or the provider poll (FIX-ADV
	// B1) — those run unlocked and take mu briefly to publish
	// their outcome.
	mu       sync.Mutex
	factory  func(jwt string) (urDevice, error)
	exchange urExchanger
	cache    *urJWTCache
	device   urDevice
	// pump is the live packet pump for device, or nil when no
	// pump is running (not connected, the device has no packet
	// plane, or this platform has no adapter).
	pump *urPump
	// deviceJWT is the JWT the live device was built with, so a
	// connect carrying a different account's key rebuilds it.
	deviceJWT string
	// deviceKeyHash is urKeyHash of the API key the live device
	// was built for, so ur.countries can tell whether a key it
	// was handed belongs to the live device's account (L2).
	deviceKeyHash string
	// lastCountry is the country string of the live destination
	// request ("" = Best Available), for status reporting when
	// the SDK has not (yet) named an exit country.
	lastCountry string
	// The connect state machine (FIX-ADV B1): state is one of
	// the urState* words, lastError the latest failure's
	// message, cancel cancels the in-flight attempt, and
	// attempt is a generation counter — a connect goroutine may
	// publish its outcome only while its generation is current,
	// so a disconnect (which bumps it) always wins.
	state     string
	lastError string
	cancel    context.CancelFunc
	attempt   uint64

	connectTimeout time.Duration
	pollDelay      time.Duration
	now            func() time.Time
}

func newURManager() *urManager {
	return &urManager{
		factory:        urDeviceFactory,
		exchange:       exchangeURJWT,
		cache:          newURJWTCache(),
		connectTimeout: 90 * time.Second,
		pollDelay:      500 * time.Millisecond,
		now:            time.Now,
	}
}

func (m *urManager) available() (bool, string) {
	if m.factory == nil {
		return false, urUnavailableReason
	}
	return true, ""
}

// jwtFor returns a cached JWT or exchanges the key for one.
func (m *urManager) jwtFor(ctx context.Context, apiKey string) (string, error) {
	if tok, ok := m.cache.get(apiKey); ok {
		return tok, nil
	}
	tok, err := m.exchange(ctx, apiKey)
	if err != nil {
		return "", err
	}
	m.cache.put(apiKey, tok)
	return tok, nil
}

// ensureDevice returns the live device, building (or rebuilding
// on account change) it from the key's JWT. The providing pin
// is applied and verified on every fresh device, before any
// connect can be issued against it.
//
// The manager mutex is NOT held across the exchange or the
// device build (FIX-ADV B1). The replacement device is built
// FULLY — factory + providing pin — before the existing device
// is touched (FIX-ADV L3): if building the replacement fails,
// the old device and its session survive untouched.
func (m *urManager) ensureDevice(ctx context.Context, apiKey string) (urDevice, error) {
	jwt, err := m.jwtFor(ctx, apiKey)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	if m.device != nil && m.deviceJWT == jwt {
		dev := m.device
		m.mu.Unlock()
		return dev, nil
	}
	m.mu.Unlock()

	dev, err := m.factory(jwt)
	if err != nil {
		return nil, fmt.Errorf("ur: the SDK device could not be created: %w", err)
	}
	if err := dev.PinProvidingOff(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("ur: %w", err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.device != nil && m.deviceJWT == jwt {
		// A concurrent caller built the same account's device
		// while this one was being built — keep theirs.
		dev.Close()
		return m.device, nil
	}
	old := m.device
	m.device = dev
	m.deviceJWT = jwt
	m.deviceKeyHash = urKeyHash(apiKey)
	if old != nil {
		m.stopPumpLocked()
		old.Close()
	}
	return dev, nil
}

// startPumpLocked starts the packet pump for dev when this
// build and platform have one: the device must expose the
// packet plane (urPumpDevice — the real SDK binding does) and
// a platform adapter opener must be registered (Windows
// only). Otherwise no pump is created and tunneled simply
// stays false — the honest state for a session this host
// cannot capture traffic for. Caller must hold m.mu.
func (m *urManager) startPumpLocked(dev urDevice) error {
	if m.pump != nil && m.pump.Running() {
		// A re-connect on the same live device (e.g. a country
		// switch) reuses the running pump — the device, and
		// therefore the packet plane, did not change.
		return nil
	}
	m.stopPumpLocked() // a dead pump from an earlier session
	pd, ok := dev.(urPumpDevice)
	if !ok || urPumpOpener == nil {
		return nil
	}
	p := newURPump(pd)
	if err := p.Start(); err != nil {
		return err
	}
	m.pump = p
	return nil
}

// stopPumpLocked stops and drops the live pump, if any.
// Caller must hold m.mu.
func (m *urManager) stopPumpLocked() {
	if m.pump != nil {
		m.pump.Stop()
		m.pump = nil
	}
}

// tunneledLocked reports the pump's own running state.
// Caller must hold m.mu.
func (m *urManager) tunneledLocked() bool {
	return m.pump != nil && m.pump.Running()
}

func (m *urManager) status() urStatus {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statusLocked()
}

// statusLocked is status() for a caller already holding m.mu.
// Connected/Tunneled/Country come from the SDK device itself;
// State/LastError come from the connect state machine. If the
// machine believes a session is connected but the SDK no
// longer reports one, the returned state reads "failed" — the
// copy is adjusted, the machine's fields are left for the
// connect/disconnect paths to own.
func (m *urManager) statusLocked() urStatus {
	avail, reason := m.available()
	st := urStatus{Available: avail, Reason: reason, State: m.state, LastError: m.lastError}
	if st.State == "" {
		st.State = urStateIdle
	}
	if m.device != nil {
		connected, country := m.device.Connected()
		st.Connected = connected
		if country != "" {
			st.Country = country
		} else if connected {
			st.Country = m.lastCountry
		}
		st.Tunneled = connected && m.tunneledLocked()
		if st.State == urStateConnected && !connected {
			st.State = urStateFailed
			if st.LastError == "" {
				st.LastError = "ur: the SDK session ended"
			}
		}
	}
	return st
}

// connect validates the request, kicks the connect attempt off
// in a goroutine, and returns the state machine's current word
// PROMPTLY (FIX-ADV B1 — asynchronous connect). The attempt
// itself (runConnect) exchanges/caches the JWT, builds the
// device with providing pinned OFF, sets the destination, and
// waits — bounded — for the SDK itself to report an established
// provider session; its outcome is published into the state
// machine for ur.status, never into this call's return beyond
// the synchronous validation errors below. A new connect
// supersedes any in-flight attempt.
func (m *urManager) connect(p urConnectParams) (urStatus, error) {
	if strings.TrimSpace(p.APIKey) == "" {
		return urStatus{}, fmt.Errorf("ur.connect needs the account API key")
	}
	if _, reason := m.available(); reason != "" {
		return urStatus{}, fmt.Errorf("ur: %s", reason)
	}
	m.mu.Lock()
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.attempt++
	attempt := m.attempt
	m.cancel = cancel
	m.state = urStateConnecting
	m.lastError = ""
	m.lastCountry = p.Country
	st := m.statusLocked()
	m.mu.Unlock()
	go m.runConnect(ctx, attempt, p)
	return st, nil
}

// runConnect is the asynchronous connect attempt kicked off by
// connect(). It may publish its outcome only while its
// generation is still current: disconnect() and a superseding
// connect() bump the generation (and cancel the context), and
// their outcome wins. The manager mutex is taken only for the
// brief state publications — never across the JWT exchange or
// the provider poll.
func (m *urManager) runConnect(ctx context.Context, attempt uint64, p urConnectParams) {
	// fail publishes a failure unless this attempt has been
	// superseded or cancelled (in which case the canceller owns
	// the state and this attempt changes nothing).
	fail := func(err error) {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.attempt != attempt {
			return
		}
		m.state = urStateFailed
		m.lastError = err.Error()
		m.cancel = nil
		m.lastCountry = ""
	}

	ectx, ecancel := context.WithTimeout(ctx, 30*time.Second)
	dev, err := m.ensureDevice(ectx, p.APIKey)
	ecancel()
	if err != nil {
		if ctx.Err() == nil {
			fail(err)
		}
		return
	}
	if ctx.Err() != nil {
		return // cancelled while the device was being built
	}
	if err := dev.Connect(p.Country); err != nil {
		fail(fmt.Errorf("ur: the SDK refused the connect: %w", err))
		return
	}

	deadline := m.now().Add(m.connectTimeout)
	for {
		select {
		case <-ctx.Done():
			// Disconnect (or a superseding connect) won. The
			// destination this attempt set must not linger.
			dev.Disconnect()
			return
		default:
		}
		if connected, _ := dev.Connected(); connected {
			// The SDK session is established; now make it
			// carry traffic. A pump that cannot start fails
			// the connect and removes the destination, so
			// status never shows a connected-but-dead engine.
			m.mu.Lock()
			if m.attempt != attempt {
				m.mu.Unlock()
				return
			}
			if err := m.startPumpLocked(dev); err != nil {
				dev.Disconnect()
				m.lastCountry = ""
				m.state = urStateFailed
				m.lastError = fmt.Errorf("ur: the SDK established a provider session but the packet pump failed: %w", err).Error()
				m.cancel = nil
				m.mu.Unlock()
				return
			}
			m.state = urStateConnected
			m.lastError = ""
			m.cancel = nil
			m.mu.Unlock()
			return
		}
		if !m.now().Before(deadline) {
			dev.Disconnect()
			fail(fmt.Errorf("ur: timed out after %s waiting for the SDK to establish a provider session (no provider connected)", m.connectTimeout))
			return
		}
		select {
		case <-ctx.Done():
			dev.Disconnect()
			return
		case <-time.After(m.pollDelay):
		}
	}
}

func (m *urManager) disconnect() (urStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	// Cancel any in-flight connect attempt and invalidate its
	// generation: disconnect wins (FIX-ADV B1).
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.attempt++
	m.stopPumpLocked()
	if m.device != nil {
		m.device.Disconnect()
	}
	m.lastCountry = ""
	m.state = urStateIdle
	m.lastError = ""
	return m.statusLocked(), nil
}

// countries returns the SDK's country list. It needs a device:
// the live one when it belongs to the key's account, else one
// built from the supplied key (which also performs the JWT
// exchange). The manager mutex is never held across the
// exchange, a device build, or the SDK lookup (FIX-ADV B1).
//
// Account correctness (FIX-ADV L2): when a live device exists
// but the supplied key belongs to a DIFFERENT account, the list
// is NOT answered from that device — a throwaway device is
// exchanged/built from the supplied key, asked, and closed, so
// the live session is never disturbed and the answer is the
// requested account's own.
func (m *urManager) countries(p urCountriesParams) ([]urCountry, error) {
	if _, reason := m.available(); reason != "" {
		return nil, fmt.Errorf("ur: %s", reason)
	}
	m.mu.Lock()
	dev := m.device
	devKeyHash := m.deviceKeyHash
	m.mu.Unlock()

	if p.APIKey != "" && dev != nil && urKeyHash(p.APIKey) != devKeyHash {
		return m.countriesViaTempDevice(p.APIKey)
	}
	if dev == nil {
		if strings.TrimSpace(p.APIKey) == "" {
			return nil, fmt.Errorf("ur.countries needs an API key before the first connect (the location list comes from the account API session)")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		var err error
		dev, err = m.ensureDevice(ctx, p.APIKey)
		cancel()
		if err != nil {
			return nil, err
		}
	}
	list, err := dev.Countries()
	if err != nil {
		return nil, fmt.Errorf("ur: the SDK location lookup failed: %w", err)
	}
	return list, nil
}

// countriesViaTempDevice answers a countries query for an
// account other than the live device's (FIX-ADV L2): exchange
// the given key, build a throwaway device (providing pinned
// OFF, like every device this service builds), ask it, close
// it. The live device is never touched.
func (m *urManager) countriesViaTempDevice(apiKey string) ([]urCountry, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	jwt, err := m.jwtFor(ctx, apiKey)
	cancel()
	if err != nil {
		return nil, err
	}
	dev, err := m.factory(jwt)
	if err != nil {
		return nil, fmt.Errorf("ur: the SDK device could not be created: %w", err)
	}
	defer dev.Close()
	if err := dev.PinProvidingOff(); err != nil {
		return nil, fmt.Errorf("ur: %w", err)
	}
	list, err := dev.Countries()
	if err != nil {
		return nil, fmt.Errorf("ur: the SDK location lookup failed: %w", err)
	}
	return list, nil
}

// close drops the device (service shutdown).
func (m *urManager) close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.attempt++
	m.stopPumpLocked()
	if m.device != nil {
		m.device.Disconnect()
		m.device.Close()
		m.device = nil
		m.deviceJWT = ""
		m.deviceKeyHash = ""
	}
	m.state = urStateIdle
	m.lastError = ""
}
