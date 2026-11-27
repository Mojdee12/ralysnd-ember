package service

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/config"
	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
	"github.com/armanlife/firefox-vpn-client/core/internal/resolver"
)

const apiRelayDialTimeout = 20 * time.Second

// resolverDialer dials through the configured DNS servers with a timeout.
type resolverDialer struct{ timeout time.Duration }

func (d resolverDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, d.timeout)
	defer cancel()
	return resolver.Dial(ctx, network, address)
}

func (d resolverDialer) Dial(network, address string) (net.Conn, error) {
	return d.DialContext(context.Background(), network, address)
}

// configureDNS installs the configured DNS servers for every connection
// this program opens itself.
func configureDNS(cfg config.DNS) error {
	// The resolver is built BEFORE the policy flips (build 2105,
	// verification iteration 2): if the new servers are invalid,
	// the old resolver AND the old policy stay installed together
	// — never the new policy over the old servers.
	r, err := resolver.New(cfg.Servers, cfg.FallbackToSystem)
	if err != nil {
		return err
	}
	// Build 2105: the IP version policy rides along with every DNS
	// (re)configuration, including the system-resolver path (the
	// policy still filters literal addresses there).
	resolver.SetIPVersion(cfg.IPVersion)
	if r.System() {
		resolver.Set(nil)
		logx.Info("DNS: system resolver")
		return nil
	}
	resolver.Set(r)
	logx.Info("DNS: servers=%s", r)
	return nil
}

// configureAPIRelay sends the control-plane requests through the user's
// relay at raw (config.Network.APIRelay); empty sends them directly. Only
// the Firefox Accounts, Guardian, server-list, geo-file, and flag requests
// are affected; the VPN traffic keeps talking to Mozilla's proxy directly.
func configureAPIRelay(raw string) error {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		// Only a relay this function set is taken away: another transport
		// (a test's fixture) stays, so starting a daemon never sends a
		// test's requests to the real services.
		if apiRelayTransport != nil && controlplane.Transport() == apiRelayTransport {
			controlplane.SetTransport(nil)
		}
		apiRelayTransport = nil
		return nil
	}
	if err := config.ValidateRelay(raw); err != nil {
		return err
	}
	relay, _ := url.Parse(raw)
	dialer := resolverDialer{timeout: apiRelayDialTimeout}
	transport := &relayTransport{relay: relay, base: &http.Transport{
		DialContext:     dialer.DialContext,
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}}
	controlplane.SetTransport(transport)
	apiRelayTransport = transport
	logx.Info("control plane API requests sent through relay=%s", relay.Host)
	return nil
}

// configureBootstrap installs the persisted bootstrap egress (build
// 2034) into the control plane: the Worker relay when one is saved,
// otherwise the donor SOCKS. The egress is only USED inside bootstrap
// windows (prepare calls and the one region retry) — installing it
// here changes no live traffic.
func configureBootstrap(cfg config.Network) error {
	if cfg.BootstrapRelayURL != "" {
		if err := config.ValidateBootstrapRelay(cfg.BootstrapRelayURL, cfg.BootstrapRelayKey); err != nil {
			return err
		}
		if err := controlplane.SetBootstrapRelay(cfg.BootstrapRelayURL, cfg.BootstrapRelayKey); err != nil {
			return err
		}
		logx.Info("bootstrap egress: Worker relay %s", cfg.BootstrapRelayURL)
		return nil
	}
	if err := config.ValidateBootstrapSocks(cfg.BootstrapSocks); err != nil {
		return err
	}
	if cfg.BootstrapSocks != "" {
		controlplane.SetBootstrapSocks(cfg.BootstrapSocks)
		logx.Info("bootstrap egress: donor SOCKS %s", cfg.BootstrapSocks)
		return nil
	}
	controlplane.ClearBootstrap()
	return nil
}

// apiRelayTransport is the transport configureAPIRelay installed; nil when
// no relay is set.
var apiRelayTransport http.RoundTripper

// relayTransport sends each request to the relay, with the target URL in
// the relay's url parameter (next to its own parameters, such as a key),
// and the method, headers, and body as they are; the relay forwards it and
// answers with the target's response. The response keeps the original
// request, so cookies and redirects resolve against the target. A relay
// that refuses (scripts/relay set X-Relay-Error) is an error that names
// the relay.
type relayTransport struct {
	relay *url.URL
	base  http.RoundTripper
}

func (t *relayTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	target := *t.relay
	query := target.Query()
	query.Set("url", req.URL.String())
	target.RawQuery = query.Encode()
	out := req.Clone(req.Context())
	out.URL = &target
	out.Host = ""
	resp, err := t.base.RoundTrip(out)
	if err != nil {
		return nil, fmt.Errorf("API relay %s: %w", t.relay.Host, err)
	}
	if reason := resp.Header.Get("X-Relay-Error"); reason != "" {
		resp.Body.Close()
		return nil, fmt.Errorf("API relay %s refused %s: %s", t.relay.Host, req.URL.Host, reason)
	}
	resp.Request = req
	return resp, nil
}
