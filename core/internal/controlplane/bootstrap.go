package controlplane

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// Bootstrap egress (build 2034): the serverless answer to the
// Guardian HTTP 451 region block, after Kumiho's Prepare pattern.
// The daemon keeps ONE configured bootstrap egress — either the
// loopback SOCKS5 of another engine the app ran as a donor, or the
// user's path-form Cloudflare Worker relay. While a bootstrap
// egress window is open (WithBootstrapEgress), every control-plane
// request rides it; the window exists to fetch a Guardian ProxyPass
// (plus the token refresh, profile, and server list that ride
// along), and the fetched pass is persisted, so the window is
// needed only when no valid pass is stored. The data plane never
// uses it.

// BootstrapKind names the configured bootstrap egress.
type BootstrapKind string

const (
	BootstrapNone  BootstrapKind = ""
	BootstrapSocks BootstrapKind = "socks"
	BootstrapRelay BootstrapKind = "relay"
)

var (
	bootstrapMu     sync.Mutex
	bootstrapKind   BootstrapKind
	bootstrapSocks  string
	bootstrapRelay  *url.URL
	bootstrapKey    string
	egressMu        sync.Mutex
	egressCtxKey    = &struct{ name string }{"bootstrap-egress"}
	workerRelayHost = map[string]bool{
		// The allowlist of mozilla-relay/worker.js, mirrored: the
		// relay refuses anything else, so rewriting it would only
		// cost a round trip.
		"guardian.mozilla.org":       true,
		"accounts.firefox.com":       true,
		"oauth.accounts.firefox.com": true,
		"api.accounts.firefox.com":   true,
	}
)

// SetBootstrapSocks makes the donor SOCKS at addr (a validated
// loopback host:port) the bootstrap egress.
func SetBootstrapSocks(addr string) {
	bootstrapMu.Lock()
	defer bootstrapMu.Unlock()
	bootstrapKind = BootstrapSocks
	bootstrapSocks = strings.TrimSpace(addr)
	bootstrapRelay = nil
	bootstrapKey = ""
}

// SetBootstrapRelay makes the Worker relay at rawURL (validated
// https) with its shared key the bootstrap egress. URL and key must
// be set together; both empty clears the egress.
func SetBootstrapRelay(rawURL, key string) error {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" && strings.TrimSpace(key) == "" {
		ClearBootstrap()
		return nil
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	if u.Scheme != "https" || u.Host == "" {
		return errors.New("bootstrap relay must be an https:// URL")
	}
	bootstrapMu.Lock()
	defer bootstrapMu.Unlock()
	bootstrapKind = BootstrapRelay
	bootstrapRelay = u
	bootstrapKey = key
	bootstrapSocks = ""
	return nil
}

// ClearBootstrap removes the bootstrap egress.
func ClearBootstrap() {
	bootstrapMu.Lock()
	defer bootstrapMu.Unlock()
	bootstrapKind = BootstrapNone
	bootstrapSocks = ""
	bootstrapRelay = nil
	bootstrapKey = ""
}

// Bootstrap returns the configured egress kind.
func Bootstrap() BootstrapKind {
	bootstrapMu.Lock()
	defer bootstrapMu.Unlock()
	return bootstrapKind
}

// InBootstrapEgress reports whether ctx is already inside a
// bootstrap (or self) egress window, so a nested retry does not
// swap the transport twice — or deadlock on the egress lock.
func InBootstrapEgress(ctx context.Context) bool {
	return ctx.Value(egressCtxKey) != nil
}

// WithBootstrapEgress runs fn with the control-plane transport
// swapped to the configured bootstrap egress, restoring the
// previous transport afterwards. With no egress configured it runs
// fn unchanged — callers that require the egress check Bootstrap()
// first. Concurrent windows serialize: the control-plane client is
// process-wide.
func WithBootstrapEgress(ctx context.Context, fn func(context.Context) error) error {
	bootstrapMu.Lock()
	kind, socks, relay, key := bootstrapKind, bootstrapSocks, bootstrapRelay, bootstrapKey
	bootstrapMu.Unlock()
	if kind == BootstrapNone {
		return fn(ctx)
	}
	return withEgress(ctx, func(previous http.RoundTripper) (http.RoundTripper, error) {
		return bootstrapTransport(kind, socks, relay, key, previous)
	}, fn)
}

// WithSelfEgress runs fn with the control-plane transport proxied
// through this engine's own local listener (listenAddr is a
// host:port the proxy already listens on): control-plane renewals
// then exit through the live Mozilla tunnel instead of the local
// network, as Kumiho's tunnel-first control plane does.
func WithSelfEgress(ctx context.Context, listenAddr string, fn func(context.Context) error) error {
	return withEgress(ctx, func(http.RoundTripper) (http.RoundTripper, error) {
		transport := defaultTransport.Clone()
		transport.Proxy = http.ProxyURL(&url.URL{Scheme: "http", Host: listenAddr})
		return transport, nil
	}, fn)
}

// withEgress swaps the shared client's transport for fn's duration;
// the factory sees the transport it replaces (the relay rewrite
// rides it as its inner layer, so DNS and any API-relay routing
// underneath stay in force).
func withEgress(ctx context.Context, factory func(http.RoundTripper) (http.RoundTripper, error), fn func(context.Context) error) error {
	egressMu.Lock()
	defer egressMu.Unlock()
	previous := client.Transport
	transport, err := factory(previous)
	if err != nil {
		return err
	}
	client.Transport = transport
	defer func() { client.Transport = previous }()
	return fn(context.WithValue(ctx, egressCtxKey, true))
}

// bootstrapTransport builds the RoundTripper for one egress kind.
func bootstrapTransport(kind BootstrapKind, socks string, relay *url.URL, key string, inner http.RoundTripper) (http.RoundTripper, error) {
	switch kind {
	case BootstrapSocks:
		transport := defaultTransport.Clone()
		transport.Proxy = http.ProxyURL(&url.URL{Scheme: "socks5", Host: socks})
		return transport, nil
	case BootstrapRelay:
		if relay == nil {
			return nil, errors.New("bootstrap relay is not configured")
		}
		return &workerRelayTransport{base: relay, key: key, inner: inner}, nil
	default:
		return nil, errors.New("no bootstrap egress is configured")
	}
}

// workerRelayTransport implements the client side of
// mozilla-relay/worker.js: an allowlisted control-plane URL
// https://<host>/<path> is rewritten to <base>/<host>/<path> and
// carries the X-Relay-Key header; every other request passes
// through untouched (the Worker would refuse it anyway). The
// response keeps the original request, so cookies and redirects
// resolve against the target, as with the API relay in service.
// One honest limit of the contract: the Worker strips Set-Cookie
// from responses, so Fastly challenge cookies cannot be earned
// through it — a challenged FxA call may fail over the relay where
// the donor SOCKS (which preserves real URLs end to end) succeeds.
type workerRelayTransport struct {
	base  *url.URL
	key   string
	inner http.RoundTripper
}

func (t *workerRelayTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if !workerRelayHost[req.URL.Host] {
		return t.inner.RoundTrip(req)
	}
	target := *t.base
	target.Path = strings.TrimSuffix(t.base.Path, "/") + "/" + req.URL.Host + req.URL.EscapedPath()
	target.RawPath = ""
	target.RawQuery = req.URL.RawQuery
	out := req.Clone(req.Context())
	out.URL = &target
	out.Host = ""
	out.Header = req.Header.Clone()
	out.Header.Set("X-Relay-Key", t.key)
	resp, err := t.inner.RoundTrip(out)
	if err != nil {
		return nil, fmt.Errorf("bootstrap relay %s: %w", t.base.Host, err)
	}
	resp.Request = req
	return resp, nil
}
