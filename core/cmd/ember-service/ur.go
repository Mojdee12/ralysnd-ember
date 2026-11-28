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
}

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
// inside urJWTLeeway of its `exp` claim; a token whose exp
// cannot be parsed is never cached.
type urJWTCache struct {
	mu  sync.Mutex
	now func() time.Time
	by  map[string]urJWTEntry
}

type urJWTEntry struct {
	token string
	exp   time.Time
}

const urJWTLeeway = 5 * time.Minute

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
	if !ok {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
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
	mu       sync.Mutex
	factory  func(jwt string) (urDevice, error)
	exchange urExchanger
	cache    *urJWTCache
	device   urDevice
	// pump is the live packet pump for device, or nil when no
	// pump is running (not connected, the device has no packet
	// plane, or this platform has no adapter). Owned by the
	// connect/disconnect paths under mu.
	pump *urPump
	// deviceJWT is the JWT the live device was built with, so a
	// connect carrying a different account's key rebuilds it.
	deviceJWT string
	// lastCountry is the country string of the live destination
	// request ("" = Best Available), for status reporting when
	// the SDK has not (yet) named an exit country.
	lastCountry string

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
// Caller must hold m.mu.
func (m *urManager) ensureDevice(ctx context.Context, apiKey string) (urDevice, error) {
	jwt, err := m.jwtFor(ctx, apiKey)
	if err != nil {
		return nil, err
	}
	if m.device != nil && m.deviceJWT == jwt {
		return m.device, nil
	}
	if m.device != nil {
		m.stopPumpLocked()
		m.device.Close()
		m.device = nil
		m.deviceJWT = ""
	}
	dev, err := m.factory(jwt)
	if err != nil {
		return nil, fmt.Errorf("ur: the SDK device could not be created: %w", err)
	}
	if err := dev.PinProvidingOff(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("ur: %w", err)
	}
	m.device = dev
	m.deviceJWT = jwt
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
	avail, reason := m.available()
	st := urStatus{Available: avail, Reason: reason}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.device != nil {
		connected, country := m.device.Connected()
		st.Connected = connected
		if country != "" {
			st.Country = country
		} else if connected {
			st.Country = m.lastCountry
		}
		st.Tunneled = connected && m.tunneledLocked()
	}
	return st
}

// connect exchanges/caches the JWT, builds the device with
// providing pinned OFF, sets the destination, and waits —
// bounded — for the SDK itself to report an established
// provider session. A timeout is an honest error, and the
// destination is removed again so status never claims a
// connection the SDK does not have.
func (m *urManager) connect(p urConnectParams) (urStatus, error) {
	if strings.TrimSpace(p.APIKey) == "" {
		return urStatus{}, fmt.Errorf("ur.connect needs the account API key")
	}
	if _, reason := m.available(); reason != "" {
		return urStatus{}, fmt.Errorf("ur: %s", reason)
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	dev, err := m.ensureDevice(ctx, p.APIKey)
	cancel()
	if err != nil {
		return urStatus{}, err
	}
	if err := dev.Connect(p.Country); err != nil {
		return urStatus{}, fmt.Errorf("ur: the SDK refused the connect: %w", err)
	}
	m.lastCountry = p.Country

	deadline := m.now().Add(m.connectTimeout)
	for {
		if connected, _ := dev.Connected(); connected {
			// The SDK session is established; now make it
			// carry traffic. A pump that cannot start fails
			// the connect and removes the destination, so
			// status never shows a connected-but-dead engine.
			if err := m.startPumpLocked(dev); err != nil {
				dev.Disconnect()
				m.lastCountry = ""
				return urStatus{}, fmt.Errorf("ur: the SDK established a provider session but the packet pump failed: %w", err)
			}
			return m.statusLocked(), nil
		}
		if !m.now().Before(deadline) {
			dev.Disconnect()
			m.lastCountry = ""
			return urStatus{}, fmt.Errorf("ur: timed out after %s waiting for the SDK to establish a provider session (no provider connected)", m.connectTimeout)
		}
		time.Sleep(m.pollDelay)
	}
}

// statusLocked is status() for a caller already holding m.mu.
func (m *urManager) statusLocked() urStatus {
	avail, reason := m.available()
	st := urStatus{Available: avail, Reason: reason}
	if m.device != nil {
		connected, country := m.device.Connected()
		st.Connected = connected
		if country != "" {
			st.Country = country
		} else if connected {
			st.Country = m.lastCountry
		}
		st.Tunneled = connected && m.tunneledLocked()
	}
	return st
}

func (m *urManager) disconnect() (urStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopPumpLocked()
	if m.device != nil {
		m.device.Disconnect()
	}
	m.lastCountry = ""
	return m.statusLocked(), nil
}

// countries returns the SDK's country list. It needs a device:
// the live one when present, else one built from the supplied
// key (which also performs the JWT exchange).
func (m *urManager) countries(p urCountriesParams) ([]urCountry, error) {
	if _, reason := m.available(); reason != "" {
		return nil, fmt.Errorf("ur: %s", reason)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	dev := m.device
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

// close drops the device (service shutdown).
func (m *urManager) close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopPumpLocked()
	if m.device != nil {
		m.device.Disconnect()
		m.device.Close()
		m.device = nil
		m.deviceJWT = ""
	}
}
