package service

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/config"
	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
	"github.com/armanlife/firefox-vpn-client/core/internal/proxy"
	"github.com/armanlife/firefox-vpn-client/core/internal/serverlist"
)

// errNoAccounts reports that the service has no enabled account to use.
var errNoAccounts = errors.New("no enabled accounts")

// proxyEngine is one running instance of the proxy: the SOCKS5/HTTP
// listener, the upstream controller, and the location it was started for.
// Settings changes stop it and start a new one.
//
// An engine starts asleep (sleep.go): the listener opens at once, but
// nothing is sent to Mozilla until something needs the upstream (a client
// connection, a connection test, or a real-delay test). The first wake
// selects the server and connects (connectEngine); later wakes after
// proxy.idle_sleep reuse that server (reconnectEngine).
type proxyEngine struct {
	// controller is the upstream: nil while the proxy sleeps.
	// Use currentController or reserve, not the field.
	controller *proxy.Controller
	// cfg is the configuration the engine was started with.
	cfg config.Config
	// upstream is what a controller is built from when the proxy wakes.
	// Until the first wake (connected false) it has no server; the first
	// wake selects one. Both are guarded by idle.wakeMu.
	upstream  proxy.ControllerConfig
	connected bool
	// statusFile is the status.json path (fixed for the engine's life).
	statusFile string
	idle       idleState
	// routed is what clients connect through: the controller, or directly
	// for destinations the routing rules send there.
	routed   *proxy.RoutedOpener
	listener net.Listener
	// tunSOCKS serves the TUN listener's connections (tun.go).
	tunSOCKS  *proxy.SOCKSServer
	transport string
	// fellBackToH2 is set when HTTP/3 was configured but did not connect,
	// so the engine uses HTTP/2 (connectEngine).
	fellBackToH2 atomic.Bool
	startedAt    time.Time
	// selected and selectionSource are guarded by idle.mu: before the
	// first wake they show the expected choice (expectedSelection), which
	// the first wake replaces with the real one.
	selected        proxy.Candidate
	selectionSource string
}

// selection returns the engine's location and how it was chosen.
func (e *proxyEngine) selection() (proxy.Candidate, string) {
	e.idle.mu.Lock()
	defer e.idle.mu.Unlock()
	return e.selected, e.selectionSource
}

// selfEgressProxyURL is the http proxy URL of the engine's own
// listener (build 2114; mozilla-regression-plan.md mechanism 1):
// the controllers built from this engine renew their Guardian
// pass through the live tunnel via this endpoint. The address
// is the listener's own, loopback-normalised the way
// Daemon.ProxyEndpoint normalises it, and the configured proxy
// login rides along when one is set.
func selfEgressProxyURL(p config.Proxy, addr string) string {
	if host, port, err := net.SplitHostPort(addr); err == nil {
		if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
			addr = net.JoinHostPort("127.0.0.1", port)
		}
	}
	u := url.URL{Scheme: "http", Host: addr}
	if p.Username != "" {
		u.User = url.UserPassword(p.Username, p.Password)
	}
	return u.String()
}

// startEngine opens the SOCKS5/HTTP listener and returns an engine that
// sleeps until first used; it sends nothing to Mozilla. It fails for a
// taken listen address, with no account, or when every account waits for
// a quota reset or a new sign-in (read from the local account state).
func (d *Daemon) startEngine() (*proxyEngine, error) {
	cfg := d.config()
	// A taken listen address is reported first, whatever the accounts.
	ln, err := listenTCP(ListenerProxy, cfg.Proxy.Listen)
	if err != nil {
		return nil, err
	}
	if d.mgr.Len() == 0 {
		_ = ln.Close()
		return nil, errNoAccounts
	}
	if _, err := d.mgr.Candidate(nil); err != nil {
		_ = ln.Close()
		return nil, err
	}

	engine := &proxyEngine{
		cfg: cfg,
		upstream: proxy.ControllerConfig{
			Guardian:   cfg.Network.GuardianEndpoint,
			Timeout:    connectTimeout,
			UseH3:      cfg.Proxy.Transport == "h3",
			UseH1:      cfg.Proxy.Transport == "h1",
			Sessions:   cfg.Proxy.UpstreamConnections,
			StatusFile: d.paths.Status,
			Accounts:   d.pool,
			SelfEgress: selfEgressProxyURL(cfg.Proxy, ln.Addr().String()),
		},
		statusFile: d.paths.Status,
		listener:   ln,
		transport:  cfg.Proxy.Transport,
		startedAt:  time.Now(),
	}
	engine.selected, engine.selectionSource = d.expectedSelection(cfg)
	engine.idle.lastUsed, engine.idle.sleeping = engine.startedAt, engine.startedAt
	routed := proxy.NewRoutedOpener(&engineUpstream{d: d, engine: engine})
	routed.SetRouter(d.currentRouter())
	engine.routed = routed
	socks := proxy.NewSOCKSServer(routed, config.HandshakeTimeout, config.IdleTimeout, cfg.Proxy.MaxConnections)
	socks.Auth = proxy.SOCKSCredentials(cfg.Proxy.Username, cfg.Proxy.Password)
	socks.Notices = d.notices
	socks.Conns, socks.Transport = d.conns, engine.currentTransport
	if socks.Auth == nil && !hostIsLoopbackListen(cfg.Proxy.Listen) {
		logx.Warn("the SOCKS5 proxy is reachable from other devices without a password; set proxy.username and proxy.password listen=%s", cfg.Proxy.Listen)
	}
	go proxy.ServeSOCKS(ln, socks)
	tunUser, tunPassword := d.tunCredentials()
	tunSOCKS := proxy.NewSOCKSServer(routed, config.HandshakeTimeout, config.IdleTimeout, tunMaxConnections)
	tunSOCKS.Auth = proxy.SOCKSCredentials(tunUser, tunPassword)
	tunSOCKS.Notices = d.notices
	tunSOCKS.Conns, tunSOCKS.Inbound, tunSOCKS.Transport = d.conns, "tun", engine.currentTransport
	tunSOCKS.Allow = d.TunnelAllows
	engine.tunSOCKS = tunSOCKS
	if err := proxy.WriteIdleStatus(engine.statusFile, proxy.StatusSleeping); err != nil {
		logx.Warn("writing status file failed path=%s err=%s", engine.statusFile, logx.Err(err))
	}
	logx.Info("SOCKS5 proxy started listen=%s transport=%s; it connects to Mozilla when a connection needs it", ln.Addr().String(), cfg.Proxy.Transport)
	return engine, nil
}

// chosenCountry reports whether the user chose a country: not the
// recommended location (an empty country), not the fastest one, and no
// server set by hand.
func chosenCountry(p config.Proxy) bool {
	country := strings.TrimSpace(p.Country)
	return strings.TrimSpace(p.Server) == "" && country != "" && !strings.EqualFold(country, proxy.FastestCountry)
}

// expectedSelection is the location the status shows before the first
// wake: the configured server, or the persisted choice when it suits the
// configured country. It reads only local files.
func (d *Daemon) expectedSelection(cfg config.Config) (proxy.Candidate, string) {
	if server := strings.TrimSpace(cfg.Proxy.Server); server != "" {
		return proxy.Candidate{Addr: server}, "configured_proxy"
	}
	country := strings.TrimSpace(cfg.Proxy.Country)
	if strings.EqualFold(country, proxy.FastestCountry) {
		return proxy.Candidate{}, ""
	}
	if persisted, ok := proxy.PersistedSelection(d.paths.Selection, country); ok {
		return persisted, "persisted"
	}
	return proxy.Candidate{}, ""
}

// connectEngine is the first wake: it fetches the server list and a pass
// (together), resolves "fastest" with that pass, selects the upstream, and
// builds the controller with its first H2/H3 session. idle.wakeMu is held.
func (d *Daemon) connectEngine(e *proxyEngine) (*proxy.Controller, error) {
	cfg := e.cfg
	server := strings.TrimSpace(cfg.Proxy.Server)
	country := strings.TrimSpace(cfg.Proxy.Country)

	listed := make(chan []serverlist.Country, 1)
	go func() { listed <- d.refreshLocations(cfg) }()
	ctx, cancel := context.WithTimeout(context.Background(), proxy.PassRenewTimeout)
	auth, pass, err := d.pool.AcquirePass(ctx, e.upstream.Guardian)
	cancel()
	if err != nil {
		return nil, err
	}
	// The pass is here: with a list from before (saved or fetched earlier)
	// the connection need not wait for the new one, which still replaces
	// it for the location choices when it arrives.
	var countries []serverlist.Country
	select {
	case countries = <-listed:
	default:
		d.mu.Lock()
		known := d.countries
		d.mu.Unlock()
		if len(known) == 0 || server != "" {
			countries = <-listed
		} else {
			logx.Debug("server list still loading; connecting with the one from before")
			countries = known
		}
	}
	proxy.LogPassTimeCorrection(pass)

	fastest := server == "" && strings.EqualFold(country, proxy.FastestCountry)
	if fastest {
		country = d.resolveFastestCountry(pass.RawToken)
	}
	selected, fromState, err := proxy.ResolveWithStateAndCountry(server, country, countries, d.paths.Selection, d.failover.Avoided)
	if err != nil {
		return nil, fmt.Errorf("selecting proxy: %w", err)
	}
	selectionSource := "single_available_location"
	switch {
	case server != "":
		selectionSource = "configured_proxy"
	case fromState:
		selectionSource = "persisted"
	case fastest:
		selectionSource = "fastest_location"
	case country != "":
		selectionSource = "configured_country"
	case selected.IsRecommended():
		selectionSource = "recommended_location"
	}
	proxyURL, err := proxy.NormalizeURL(selected.Addr)
	if err != nil {
		return nil, fmt.Errorf("invalid proxy %q: %w", selected.Addr, err)
	}

	sessionStart := time.Now()
	upstream := e.upstream
	upstream.ProxyURL = proxyURL
	upstream.ChosenLocation = chosenCountry(cfg.Proxy)
	upstream.Server = selected
	if server == "" {
		// A server set by hand stays; a selected one may move within its
		// location when it keeps failing.
		upstream.Location = proxy.LocationCandidates(countries, country)
		upstream.Failover = d.failover
	}
	withPass := upstream
	withPass.Auth, withPass.Pass = auth, pass
	// establish builds the controller for the server withPass names,
	// with the H3→H2 fallback every attempt gets: a network that
	// filters QUIC lets the same server through over TCP. Inside
	// the fast-failover walk the shared deadline also gates the
	// fallback: with under 250 ms of it left, the H3 error
	// stands and the walk moves on. The gate's margin was
	// 2 s while an establish could overrun the deadline by a
	// full per-attempt timeout; since build 2116
	// (establishWalk) bounds every attempt's COMPLETION by
	// the deadline, a started fallback is abandoned at the
	// deadline rather than overrunning, and the gate only
	// needs to keep a hopeless sliver from being spent.
	// lastUseH3 tracks the transport the LAST SUCCESSFUL attempt
	// actually used: an early walk attempt's H3→H2 fallback
	// mutates the captured configs above, but when a later server
	// wins over H3 the engine's config must say H3 again —
	// otherwise the engine persists an H2 upstream for an
	// H3-proven server while the status still reports h3.
	lastUseH3 := withPass.UseH3
	establish := func(cfg proxy.ControllerConfig, deadline time.Time) (*proxy.Controller, error) {
		controller, err := proxy.NewController(cfg)
		if err != nil && cfg.UseH3 {
			if !deadline.IsZero() && time.Until(deadline) < 250*time.Millisecond {
				return nil, err
			}
			logx.Warn("HTTP/3 did not connect; using HTTP/2 instead proxy=%s err=%s", cfg.Server.Addr, logx.Err(err))
			// The fallback is remembered on the engine's own
			// config, as before: a later wake does not pay the
			// H3 attempt again.
			upstream.UseH3, withPass.UseH3 = false, false
			cfg.UseH3 = false
			controller, err = proxy.NewController(cfg)
			if err == nil {
				e.fellBackToH2.Store(true)
			}
		}
		if err == nil {
			lastUseH3 = cfg.UseH3
		}
		return controller, err
	}
	// Build 2105 (proxy.fast_failover): with the flag on, a server
	// that does not answer is walked past inside THIS attempt (see
	// establishWalk); off, the failover argument is nil and the
	// walk is exactly the shipped single attempt.
	var walkFailover *proxy.ServerFailover
	if cfg.Proxy.FastFailover {
		walkFailover = upstream.Failover
	}
	deadline := sessionStart.Add(connectTimeout)
	controller, winner, fastWalked, _, err := establishWalk(
		func(c proxy.ControllerConfig, dl time.Time) (*proxy.Controller, error) { return establish(c, dl) },
		withPass, walkFailover, upstream.Location, deadline)
	if fastWalked && winner.Addr != selected.Addr {
		selectionSource = "server_failover"
	}
	if fastWalked {
		selected = winner
		upstream.Server = winner
		if winnerURL, urlErr := proxy.NormalizeURL(winner.Addr); urlErr == nil {
			upstream.ProxyURL = winnerURL
		}
	}
	if err != nil {
		// A server that keeps failing to connect gives way to another of
		// the location, saved as the persisted choice that the next wake
		// selects. When the fast walk already counted these failures
		// through FailedFast, Failed is not called again — the strikes
		// must not be counted twice.
		if !fastWalked {
			if next, ok := upstream.Failover.Failed(upstream.Location, selected, err); ok {
				e.serverSwitched(next)
			}
		}
		return nil, fmt.Errorf("establishing upstream proxy session: %w", err)
	}
	// The winning attempt's transport is the engine's (see
	// lastUseH3): an earlier attempt's fallback must not leave
	// the engine configured for H2 behind an H3 winner.
	upstream.UseH3 = lastUseH3
	if server == "" {
		if err := proxy.SaveSelection(d.paths.Selection, selected); err != nil {
			logx.Warn("saving proxy selection failed path=%s err=%s", d.paths.Selection, logx.Err(err))
		}
	}
	e.upstream, e.connected = upstream, true
	e.idle.mu.Lock()
	e.selected, e.selectionSource = selected, selectionSource
	e.idle.mu.Unlock()

	logx.Info("connected to Mozilla upstream=%s account=%s proxy_pass_exp=%s transport=%s upstream_conns=%d",
		selected.Addr, logx.Email(d.pool.ActiveName()), pass.ExpiresAt().Format(time.RFC3339), cfg.Proxy.Transport, cfg.Proxy.UpstreamConnections)
	logx.Info("upstream selected configured_country=%q configured_country_code=%s proxy=%s selection_source=%s upstream_session_establish_latency=%s",
		selected.CountryNameOrUnknown(), selected.CountryCodeOrUnknown(), selected.Addr, selectionSource, time.Since(sessionStart).Round(time.Millisecond))
	return controller, nil
}

// reconnectEngine wakes an engine that was connected before: a new pass
// and session for the same server (or the one the failover moved to),
// without selecting or measuring again. idle.wakeMu is held.
func (d *Daemon) reconnectEngine(e *proxyEngine) (*proxy.Controller, error) {
	ctx, cancel := context.WithTimeout(context.Background(), proxy.PassRenewTimeout)
	auth, pass, err := d.pool.AcquirePass(ctx, e.upstream.Guardian)
	cancel()
	if err != nil {
		return nil, err
	}
	if e.upstream.Failover != nil {
		if selected, _ := e.selection(); selected.Addr != "" && selected.Addr != e.upstream.Server.Addr {
			if proxyURL, err := proxy.NormalizeURL(selected.Addr); err == nil {
				e.upstream.Server, e.upstream.ProxyURL = selected, proxyURL
			}
		}
	}
	cfg := e.upstream
	cfg.Auth, cfg.Pass = auth, pass
	// Build 2105: the wake path walks too, when fast failover is
	// on. Fast failover that only worked on an engine's first-ever
	// connect would be off exactly when a sleeping proxy wakes —
	// the common case.
	var walkFailover *proxy.ServerFailover
	if d.fastFailoverEnabled() {
		walkFailover = cfg.Failover
	}
	controller, winner, walked, switchTo, err := establishWalk(
		func(c proxy.ControllerConfig, _ time.Time) (*proxy.Controller, error) { return proxy.NewController(c) },
		cfg, walkFailover, cfg.Location, time.Now().Add(connectTimeout))
	if err != nil {
		if walked && switchTo.Addr != "" && switchTo.Addr != cfg.Server.Addr {
			// The walk crossed a strike threshold: the
			// failover persisted the switch, and the engine
			// adopts it in memory too — otherwise every later
			// wake starts on the avoided server and pays its
			// failure again, and the wake backoff a selection
			// change waives never is.
			e.serverSwitched(switchTo)
		}
		if !walked && cfg.Failover != nil {
			if next, ok := cfg.Failover.Failed(cfg.Location, cfg.Server, err); ok {
				e.serverSwitched(next)
			}
		}
		return nil, err
	}
	if walked && winner.Addr != cfg.Server.Addr {
		e.serverSwitched(winner)
		if saveErr := proxy.SaveSelection(d.paths.Selection, winner); saveErr != nil {
			logx.Warn("saving proxy selection failed path=%s err=%s", d.paths.Selection, logx.Err(saveErr))
		}
	}
	return controller, nil
}

// errEstablishDeadline marks an establish attempt the
// shared connect deadline cut off (build 2116, 2105-R7).
var errEstablishDeadline = errors.New("establishing the proxy session exceeded the connect deadline")

// establishWalk builds a controller for cfg's server and, when
// failover is non-nil (proxy.fast_failover on), walks the
// location's other servers inside the same attempt when one does
// not answer (build 2105): same city first, at most three servers,
// and no new attempt started with under 5 s of the shared deadline
// left. Every failure — including the last server's — is counted
// exactly once, through FailedFast, so the strike bookkeeping, the
// 15-minute avoidance and the persisted selection stay exactly
// Failed's, and a caller whose walk ran must not call Failed for
// the same failure again. Each attempt keeps the standard
// per-attempt timeout: shrinking the winning attempt's timeout to
// the time left would be inherited by every session rebuild for
// the controller's whole life. A nil failover returns after the
// first attempt, walked=false.
//
// Build 2116 (2105-R7): the shared deadline bounds
// COMPLETIONS, not only starts — every establish, the
// first included, runs under it: an attempt still running
// at the deadline is abandoned (a late success is closed,
// never adopted) and counts as a failure of that server.
// Up to 2115 the first attempt ran with a zero deadline,
// so a connect could overrun its budget by a whole
// per-attempt timeout before the walk even started.
//
// On total failure the fourth result is the server the failover
// switched the persisted selection to when a strike threshold was
// crossed during the walk (zero when none was): FailedFast
// persists it, and a caller with a live engine must adopt it in
// memory too, or every later wake starts on the avoided server.
func establishWalk(
	establish func(cfg proxy.ControllerConfig, deadline time.Time) (*proxy.Controller, error),
	cfg proxy.ControllerConfig,
	failover *proxy.ServerFailover,
	location []proxy.Candidate,
	deadline time.Time,
) (*proxy.Controller, proxy.Candidate, bool, proxy.Candidate, error) {
	// runEstablish bounds one attempt's completion by the
	// shared deadline (build 2116, 2105-R7).
	runEstablish := func(c proxy.ControllerConfig) (*proxy.Controller, error) {
		if deadline.IsZero() {
			return establish(c, deadline)
		}
		type outcome struct {
			ctl *proxy.Controller
			err error
		}
		done := make(chan outcome, 1)
		go func() {
			ctl, err := establish(c, deadline)
			done <- outcome{ctl, err}
		}()
		timer := time.NewTimer(time.Until(deadline))
		defer timer.Stop()
		select {
		case o := <-done:
			return o.ctl, o.err
		case <-timer.C:
			go func() {
				if o := <-done; o.ctl != nil {
					_ = o.ctl.Close()
				}
			}()
			return nil, errEstablishDeadline
		}
	}
	controller, err := runEstablish(cfg)
	if err == nil || failover == nil {
		return controller, cfg.Server, false, proxy.Candidate{}, err
	}
	// Build 2116 (2105-R11): the tried-set keys on the
	// canonical host:port (the failover maps' own key), not
	// the raw address string — the same server spelled two
	// ways was retried as if it were two servers. An
	// address that does not canonicalise keys on itself,
	// which is the old behaviour for it.
	triedKey := func(addr string) string {
		if key, keyErr := proxy.CanonicalProxyAddr(addr); keyErr == nil {
			return key
		}
		return addr
	}
	tried := map[string]bool{triedKey(cfg.Server.Addr): true}
	current := cfg
	var thresholdNext proxy.Candidate
	for attempt := 0; attempt < 3 && err != nil; attempt++ {
		next, moved, crossed := failover.FailedFast(location, current.Server, err, func(addr string) bool {
			return tried[triedKey(addr)]
		})
		if moved && crossed {
			// This failure itself crossed the strike threshold:
			// next is the server FailedFast persisted as the
			// choice. The crossing is reported by FailedFast,
			// not inferred from Avoided state — the server may
			// already have been avoided by another path without
			// this call persisting anything (iteration 4).
			thresholdNext = next
		}
		if !moved || attempt == 2 {
			break
		}
		if time.Until(deadline) < 5*time.Second {
			break
		}
		nextURL, urlErr := proxy.NormalizeURL(next.Addr)
		if urlErr != nil {
			break
		}
		tried[triedKey(next.Addr)] = true
		current.Server, current.ProxyURL = next, nextURL
		controller, err = runEstablish(current)
	}
	// The switch is adopted only when its target is itself
	// usable: a later server of the same walk may have crossed
	// its own threshold after thresholdNext was persisted, and
	// adopting an avoided server would pin the engine to it.
	var switchTo proxy.Candidate
	if err != nil && thresholdNext.Addr != "" && !failover.Avoided(thresholdNext.Addr) {
		switchTo = thresholdNext
	}
	return controller, current.Server, true, switchTo, err
}

// fastFailoverEnabled reports the live proxy.fast_failover setting
// (build 2105) for paths that do not receive the config directly.
func (d *Daemon) fastFailoverEnabled() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cfg.Proxy.FastFailover
}

// serverSwitched makes next, where the failover moved the upstream, the
// engine's server: the status shows it and the next wake connects to it
// (reconnectEngine).
func (e *proxyEngine) serverSwitched(next proxy.Candidate) {
	e.idle.mu.Lock()
	e.selected, e.selectionSource = next, "server_failover"
	e.idle.mu.Unlock()
}

// runController makes controller the engine's upstream and starts its
// renewal and quota loops. It returns false, closing controller, when the
// engine has stopped meanwhile.
func (d *Daemon) runController(engine *proxyEngine, controller *proxy.Controller) bool {
	// Set before the loops start, which may rebuild the session.
	controller.OnSessionRebuilt = func() {
		if engine.currentController() == controller && d.currentEngine() == engine {
			d.autoTest(engine, "session rebuilt")
		}
	}
	controller.OnServerSwitched = engine.serverSwitched
	engine.idle.mu.Lock()
	if engine.idle.stopped {
		engine.idle.mu.Unlock()
		_ = controller.Close()
		return false
	}
	engine.controller = controller
	engine.idle.sleeping = time.Time{}
	engine.idle.wakeErr, engine.idle.wakeCode, engine.idle.wakeFailedAt = nil, "", time.Time{}
	engine.idle.wakeRetryAt, engine.idle.wakeFailures, engine.idle.wakeLasting = time.Time{}, 0, false
	engine.idle.mu.Unlock()
	go controller.RunRenewalLoop()
	go controller.RunUpstreamFailureLoop()
	go controller.RunQuotaMonitorLoop()
	return true
}

// stop closes the listener and the upstream sessions; open tunnels end.
// A wake that finishes afterwards closes its controller (runController).
func (e *proxyEngine) stop() {
	_ = e.listener.Close()
	e.idle.mu.Lock()
	e.idle.stopped = true
	c := e.controller
	e.controller = nil
	e.idle.mu.Unlock()
	if c != nil {
		_ = c.Close()
	} else if err := proxy.WriteIdleStatus(e.statusFile, proxy.StatusClosed); err != nil {
		logx.Warn("writing status file failed path=%s err=%s", e.statusFile, logx.Err(err))
	}
	e.routed.Close()
}

// refreshLocations fetches and filters the server list (unless an exact
// server is configured) and keeps it for the dashboard's location choices.
func (d *Daemon) refreshLocations(cfg config.Config) []serverlist.Country {
	if strings.TrimSpace(cfg.Proxy.Server) != "" {
		return nil
	}
	// The Firefox version the records are evaluated for is looked up
	// while the list downloads.
	version := make(chan string, 1)
	go func() { version <- d.firefoxVersion() }()
	ctx, cancel := context.WithTimeout(context.Background(), proxy.APIRequestTimeout)
	countries, err := serverlist.Fetch(ctx)
	cancel()
	if err == nil && len(countries) > 0 {
		if err := serverlist.SaveCache(d.paths.ServerList, countries); err != nil {
			logx.Warn("saving the server list failed err=%s", logx.Err(err))
		}
	} else {
		// The list changes rarely: the last one fetched does.
		logx.Warn("fetching server list failed: %v", err)
		if cached, savedAt, cacheErr := serverlist.LoadCache(d.paths.ServerList); cacheErr == nil {
			logx.Info("using the server list saved %s", savedAt.Local().Format("2006-01-02 15:04"))
			countries = cached
		}
	}
	var dropped []serverlist.FilteredRecord
	countries, dropped = serverlist.Filter(countries, serverlist.Environment{FirefoxVersion: <-version})
	for _, record := range dropped {
		logx.Debug("server-list record skipped country_code=%s filter=%q reason=%s", record.Code, record.Expression, record.Reason)
	}
	if len(countries) > 0 {
		d.mu.Lock()
		d.countries = countries
		d.mu.Unlock()
	}
	return countries
}

// latestFirefoxVersion fetches the newest Firefox version; tests replace it.
var latestFirefoxVersion = serverlist.LatestFirefoxVersion

// knownFirefoxVersion returns the version the server list was last
// evaluated for, without fetching.
func (d *Daemon) knownFirefoxVersion() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.ffVersion == "" {
		return serverlist.DefaultFirefoxVersion
	}
	return d.ffVersion
}

// firefoxVersionRefresh is how long a fetched Firefox version is used.
const firefoxVersionRefresh = 12 * time.Hour

// firefoxVersion returns the newest Firefox version, fetched from Mozilla
// and refreshed twice a day, so version-gated server-list records apply as
// they do for current Firefox. Without a fetch it keeps the last value, or
// serverlist.DefaultFirefoxVersion.
func (d *Daemon) firefoxVersion() string {
	d.mu.Lock()
	version, at := d.ffVersion, d.ffVersionAt
	d.mu.Unlock()
	if version != "" && time.Since(at) < firefoxVersionRefresh {
		return version
	}
	ctx, cancel := context.WithTimeout(context.Background(), proxy.APIRequestTimeout)
	latest, err := latestFirefoxVersion(ctx)
	cancel()
	switch {
	case err == nil:
		if latest != version {
			logx.Info("server list evaluated for Firefox %s (latest)", latest)
		}
		version = latest
	case version == "":
		logx.Warn("reading the latest Firefox version failed; using %s err=%s", serverlist.DefaultFirefoxVersion, logx.Err(err))
		version = serverlist.DefaultFirefoxVersion
	default:
		logx.Debug("reading the latest Firefox version failed; keeping %s err=%s", version, logx.Err(err))
	}
	d.mu.Lock()
	d.ffVersion, d.ffVersionAt = version, time.Now()
	d.mu.Unlock()
	return version
}

// currentTransport is the transport the engine uses: proxy.transport, or
// "h2" after HTTP/3 did not connect.
func (e *proxyEngine) currentTransport() string {
	if e.fellBackToH2.Load() {
		return "h2"
	}
	return e.transport
}
