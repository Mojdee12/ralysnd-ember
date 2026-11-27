package proxy

import (
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
)

const maxOpenTunnelRebuildRetries = 3

type managedSession struct {
	session   proxySession
	rawToken  string
	expiresAt time.Time
	refs      int
	accepting bool
	// afterRefusal: the pass was fetched because Mozilla refused the one
	// before (refusedAgain); a renewed pass clears it.
	afterRefusal bool
	// server is the address of the proxy server the session is on.
	server string
}

type ControllerConfig struct {
	Guardian string
	ProxyURL *url.URL
	Timeout  time.Duration
	Auth     *runtimeAuth
	Pass     *guardian.ProxyPassInfo
	UseH3    bool
	// UseH1 (build 2105): sessions speak HTTP/1.1 CONNECT, one TLS
	// connection per tunnel (upstream_h1.go). Set only when the
	// configured transport is "h1"; UseH3 stays false then.
	UseH1      bool
	Sessions   int
	StatusFile string
	Accounts   *AccountPool // optional; multi-account mode with threshold failover
	// ChosenLocation is set when the user chose the location (a country,
	// not the recommended location or the fastest one): a refusal that a
	// new pass does not cure is then reported as LocationRefusedError.
	ChosenLocation bool
	// Server is the server ProxyURL points to, with its location data.
	Server Candidate
	// Location lists the servers of the selected location
	// (LocationCandidates), and Failover moves the upstream among them
	// when Server keeps failing. Both are unset for a server set by hand.
	Location []Candidate
	Failover *ServerFailover
	// SelfEgress is the http proxy URL of the engine's own local
	// listener (build 2114; mozilla-regression-plan.md mechanism
	// 1): a pass renewal exits through the live tunnel, so a
	// region that refuses the direct path (Guardian HTTP 451)
	// can still renew while the current pass lives. Empty (the
	// desktop, tests) renews direct, as before.
	SelfEgress string
}

type Controller struct {
	// OnSessionRebuilt, when set, runs after a failed upstream session was
	// replaced by a new one.
	OnSessionRebuilt func()
	// OnServerSwitched, when set, runs (renewMu held) after the failover
	// moved the upstream to another server of the location.
	OnServerSwitched func(Candidate)

	guardian string
	timeout  time.Duration
	// chosenLocation is ControllerConfig.ChosenLocation.
	chosenLocation bool
	// location and failover are ControllerConfig.Location and Failover.
	location []Candidate
	failover *ServerFailover

	sessionFactory func(token string) (proxySession, error)
	refreshSession func() error
	accounts       *AccountPool
	// selfEgress is ControllerConfig.SelfEgress.
	selfEgress string

	// trafficSinceCheck counts tunnel bytes since the last quota check;
	// crossing usageProbeBytes requests an early check on quotaCheckNow.
	trafficSinceCheck atomic.Int64
	// trafficSinceReading counts tunnel bytes since the quota in usage was
	// read: setUsage resets it together with usage, under mu, and
	// nearSwitch adds it to that reading.
	trafficSinceReading atomic.Int64
	quotaCheckNow       chan struct{}

	renewMu    sync.Mutex
	mu         sync.Mutex
	auth       *runtimeAuth
	current    *managedSession
	statusFile string
	closed     bool
	done       chan struct{}
	// server is the proxy server new sessions are opened to (guarded by
	// mu; sessionFactory dials proxyURL); the failover changes both.
	server   Candidate
	proxyURL *url.URL

	// Guarded by mu: the latest quota state and the outcome of the last
	// renewal, reported in the status file without any secret.
	usage          *guardian.ProxyUsage
	lastError      string
	lastRenewalErr error
	nextAttemptAt  time.Time
	lastRenewalAt  time.Time

	// The route the last renewal's pass fetch took (build
	// 2116, renewal journaling): "self-egress", "direct" or
	// "direct-fallback", guarded by mu. The renewal loop
	// logs it with every outcome — up to 2115 a degradation
	// at a renewal boundary left no trace of which route
	// the fetch took or whether it ran at all.
	lastRenewalRoute string

	// Upstream tunnel-open failures by FailureCode class
	// (build 2116): counted as openTunnel gives up on
	// them, summarised into the renewal loop's outcome
	// lines, so a mid-session upstream rot (the 502 shape)
	// is visible in the log with its class and count
	// instead of silence.
	upstreamFailuresMu sync.Mutex
	upstreamFailures   map[string]int

	// Established-session failures by FailureCode class
	// (build 2119, audit F-01): counted when a session
	// that was already established is judged dead —
	// the keepalive found it gone, or an open on it
	// failed at session level and it is marked unusable.
	// Build 2116 counted only the give-ups in
	// noteUpstreamFailure, so rot that a rebuild absorbed
	// (the request eventually served) left no count at
	// all. Guarded by upstreamFailuresMu.
	establishedFailures map[string]int

	// The last failure summary the timer loop emitted
	// (build 2119): it re-emits only on change, so a
	// quiet controller stays quiet. Guarded by
	// upstreamFailuresMu.
	lastFailureSummary string

	// The spacing of tunnel-triggered rebuilds: redials with the current
	// pass, and new passes.
	redialBackoff rebuildBackoff
	passBackoff   rebuildBackoff

	closeOnce sync.Once
	closeErr  error
}

func NewController(cfg ControllerConfig) (*Controller, error) {
	var baseFactory func(target *url.URL, token string) (proxySession, error)
	switch {
	case cfg.UseH1:
		baseFactory = func(target *url.URL, token string) (proxySession, error) {
			return newH1ProxySession(target, token, cfg.Timeout)
		}
	case cfg.UseH3:
		baseFactory = func(target *url.URL, token string) (proxySession, error) {
			return newH3ProxySession(target, token, cfg.Timeout)
		}
	default:
		baseFactory = func(target *url.URL, token string) (proxySession, error) {
			return newH2ProxySession(target, token, cfg.Timeout)
		}
	}
	sessions := cfg.Sessions
	if sessions < 1 {
		sessions = defaultUpstreamConnections
	}
	// A pool stays on the server it was made for: after a failover, the
	// slots it replenishes belong to a session being drained.
	factory := func(target *url.URL, token string) (proxySession, error) {
		if sessions == 1 {
			return baseFactory(target, token)
		}
		var tokenMu sync.RWMutex
		createToken := token
		return newProxySessionPool(sessions, func() (proxySession, error) {
			tokenMu.RLock()
			currentToken := createToken
			tokenMu.RUnlock()
			return baseFactory(target, currentToken)
		}, func(newToken string) {
			tokenMu.Lock()
			createToken = newToken
			tokenMu.Unlock()
		})
	}

	session, err := factory(cfg.ProxyURL, cfg.Pass.RawToken)
	if err != nil {
		return nil, err
	}

	server := cfg.Server
	if server.Addr == "" {
		server.Addr = cfg.ProxyURL.Host
	}
	controller := &Controller{
		guardian:       cfg.Guardian,
		proxyURL:       cfg.ProxyURL,
		server:         server,
		timeout:        cfg.Timeout,
		auth:           cfg.Auth,
		statusFile:     cfg.StatusFile,
		accounts:       cfg.Accounts,
		selfEgress:     cfg.SelfEgress,
		chosenLocation: cfg.ChosenLocation,
		location:       cfg.Location,
		failover:       cfg.Failover,
		quotaCheckNow:  make(chan struct{}, 1),
		done:           make(chan struct{}),
		usage:          cfg.Pass.Usage,
		current: &managedSession{
			session:   session,
			rawToken:  cfg.Pass.RawToken,
			expiresAt: cfg.Pass.ExpiresAt(),
			accepting: true,
			server:    server.Addr,
		},
	}
	controller.notePoolAbsorbed(session)
	controller.sessionFactory = func(token string) (proxySession, error) {
		controller.mu.Lock()
		target := controller.proxyURL
		controller.mu.Unlock()
		return factory(target, token)
	}
	controller.writeStatus("startup")
	return controller, nil
}

func (c *Controller) OpenTunnel(authority string) (net.Conn, error) {
	return c.openTunnel(authority, "")
}

// countFailure adds err to one of the failure maps and
// returns its class and the class's new count.
func (c *Controller) countFailure(m map[string]int, err error) (string, int) {
	code := FailureCode(err)
	if code == "" {
		code = FailureOther
	}
	m[code]++
	return code, m[code]
}

// noteUpstreamFailure counts a tunnel-open failure
// openTunnel gave up on, by FailureCode class (build
// 2116, renewal journaling): the first of a class and
// every twentieth are logged at once, and the counts
// ride the renewal outcome lines and the failure
// timer's summary (build 2119).
func (c *Controller) noteUpstreamFailure(err error) {
	if err == nil {
		return
	}
	c.upstreamFailuresMu.Lock()
	if c.upstreamFailures == nil {
		c.upstreamFailures = map[string]int{}
	}
	code, n := c.countFailure(c.upstreamFailures, err)
	c.upstreamFailuresMu.Unlock()
	if n == 1 || n%20 == 0 {
		logx.Warn("upstream failure class=%s count=%d err=%s", code, n, logx.Err(err))
	}
}

// noteEstablishedFailure counts a failure of a session
// that was already established (build 2119, audit F-01):
// the keepalive found it dead, or an open on it failed
// at session level and openTunnel marks it unusable.
// Build 2116 counted only tunnel-open give-ups, so rot
// a rebuild absorbed — the mid-session 502 shape, the
// request eventually served by a fresh session — left
// no count anywhere.
func (c *Controller) noteEstablishedFailure(err error) {
	if err == nil {
		return
	}
	c.upstreamFailuresMu.Lock()
	if c.establishedFailures == nil {
		c.establishedFailures = map[string]int{}
	}
	code, n := c.countFailure(c.establishedFailures, err)
	c.upstreamFailuresMu.Unlock()
	if n == 1 || n%20 == 0 {
		logx.Warn("established session failure class=%s count=%d err=%s", code, n, logx.Err(err))
	}
}

// failureSummary renders one failure map for a log line
// ("none" while nothing has failed).
func failureSummary(m map[string]int) string {
	if len(m) == 0 {
		return "none"
	}
	parts := make([]string, 0, len(m))
	for _, code := range slices.Sorted(maps.Keys(m)) {
		parts = append(parts, fmt.Sprintf("%s=%d", code, m[code]))
	}
	return strings.Join(parts, ",")
}

// upstreamFailureSummary renders the counted tunnel-open
// classes for a log line ("none" while nothing has failed).
func (c *Controller) upstreamFailureSummary() string {
	c.upstreamFailuresMu.Lock()
	defer c.upstreamFailuresMu.Unlock()
	return failureSummary(c.upstreamFailures)
}

// establishedFailureSummary renders the counted
// established-session classes for a log line.
func (c *Controller) establishedFailureSummary() string {
	c.upstreamFailuresMu.Lock()
	defer c.upstreamFailuresMu.Unlock()
	return failureSummary(c.establishedFailures)
}

// emitUpstreamFailureSummary logs both failure summaries
// when either has changed since the last emission
// (build 2119, audit F-01): the renewal loop's outcome
// lines were the only place the counts surfaced, on a
// ~8-minute cadence — a session dying at ~2 minutes
// never reached one. The timer loop calls this every
// minute; it reports whether a line was emitted.
func (c *Controller) emitUpstreamFailureSummary() bool {
	c.upstreamFailuresMu.Lock()
	summary := "open=" + failureSummary(c.upstreamFailures) +
		" established=" + failureSummary(c.establishedFailures)
	if summary == c.lastFailureSummary {
		c.upstreamFailuresMu.Unlock()
		return false
	}
	c.lastFailureSummary = summary
	c.upstreamFailuresMu.Unlock()
	logx.Info("upstream failure summary %s", summary)
	return true
}

// setRenewalRoute / renewalRoute: the route the last
// renewal's pass fetch took (build 2116).
func (c *Controller) setRenewalRoute(route string) {
	c.mu.Lock()
	c.lastRenewalRoute = route
	c.mu.Unlock()
}

func (c *Controller) renewalRoute() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.lastRenewalRoute == "" {
		return "unknown"
	}
	return c.lastRenewalRoute
}

func (c *Controller) OpenTunnelForClient(authority, clientKey string) (net.Conn, error) {
	return c.openTunnel(authority, clientKey)
}

func (c *Controller) openTunnel(authority, clientKey string) (net.Conn, error) {
	// cause is the session's failure that rebuilds answer; lastErr may also
	// be a rebuild's own error.
	var lastErr, cause error
	for attempt := 0; attempt <= maxOpenTunnelRebuildRetries; attempt++ {
		var failedSession *managedSession
		ms, session, release, err := c.acquireSession()
		if err != nil {
			if c.isClosed() {
				return nil, err
			}
			if !errors.Is(err, ErrNoUsableSession) || lastErr == nil {
				lastErr = err
			}
			if cause == nil {
				cause = err
			}
		} else if !isSessionAlive(session) {
			// The keepalive already saw this session die; rebuild it instead of
			// spending a request to rediscover that.
			lastErr = errProxySessionUnhealthy
			cause = lastErr
			failedSession = ms
			c.noteEstablishedFailure(lastErr)
			c.markSessionUnusable(ms)
			release()
		} else {
			var conn net.Conn
			if affinitySession, ok := session.(clientAffinityTunnelOpener); ok {
				conn, err = affinitySession.OpenTunnelForClient(authority, clientKey)
			} else {
				conn, err = session.OpenTunnel(authority)
			}
			if err == nil {
				c.redialBackoff.opened()
				c.passBackoff.opened()
				c.failover.Worked(ms.server)
				return &managedTunnelConn{
					Conn:        conn,
					release:     release,
					traffic:     c.noteTraffic,
					noteFailure: c.noteEstablishedFailure,
				}, nil
			}
			if !shouldRebuildProxySession(err) {
				release()
				c.noteUpstreamFailure(err)
				return nil, err
			}
			if c.refusedAgain(ms, err) {
				release()
				if c.chosenLocation {
					err = &LocationRefusedError{Err: err}
				}
				c.noteUpstreamFailure(err)
				return nil, err
			}
			lastErr = err
			cause = err
			failedSession = ms
			c.noteEstablishedFailure(err)
			c.markSessionUnusable(ms)
			release()
		}

		if attempt == maxOpenTunnelRebuildRetries || c.isClosed() {
			break
		}

		logx.Warn("upstream tunnel open failed; rebuilding proxy session attempt=%d max=%d err=%s", attempt+1, maxOpenTunnelRebuildRetries, logx.Err(lastErr))
		if err := c.rebuildSession(failedSession, cause); err != nil {
			lastErr = fmt.Errorf("rebuilding upstream proxy session: %w", err)
		}
	}
	c.noteUpstreamFailure(lastErr)
	return nil, lastErr
}

// refusedAgain reports a CONNECT 403 or 407 on a session whose pass was
// fetched because Mozilla refused the one before: a new pass would be
// refused too (a location the account may not use, or a refused
// destination), so the client gets the refusal and the session goes on
// serving the others.
func (c *Controller) refusedAgain(ms *managedSession, err error) bool {
	var connectErr *proxyConnectHTTPError
	if !errors.As(err, &connectErr) ||
		(connectErr.statusCode != http.StatusForbidden && connectErr.statusCode != http.StatusProxyAuthRequired) {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return ms.afterRefusal
}

func (c *Controller) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// acquireSession takes a reference to the current session. The session is
// read under the lock and returned with it: Reconnect and Close clear
// ms.session while references are held, and the caller then works on the
// value it got (a closed session fails its calls, it does not vanish).
func (c *Controller) acquireSession() (*managedSession, proxySession, func(), error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil, nil, nil, ErrNoUsableSession
	}
	if c.current == nil || !c.current.accepting || c.current.session == nil {
		return nil, nil, nil, ErrNoUsableSession
	}
	if time.Now().After(c.current.expiresAt) {
		c.current.accepting = false
		c.maybeCloseLocked(c.current)
		return nil, nil, nil, ErrNoUsableSession
	}

	ms := c.current
	ms.refs++
	return ms, ms.session, func() { c.releaseSession(ms) }, nil
}

func (c *Controller) releaseSession(ms *managedSession) {
	c.mu.Lock()
	defer c.mu.Unlock()
	ms.refs--
	c.maybeCloseLocked(ms)
}

func (c *Controller) markSessionUnusable(ms *managedSession) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if ms == nil || c.current != ms {
		return
	}
	ms.accepting = false
	c.maybeCloseLocked(ms)
}

func (c *Controller) maybeCloseLocked(ms *managedSession) {
	if ms == nil || ms.accepting || ms.refs > 0 || ms.session == nil {
		return
	}
	_ = ms.session.Close()
	ms.session = nil
}

// notePoolAbsorbed installs the established-failure
// counter on a session pool (build 2123, audit F-01
// gap 1): slot failures the pool absorbs while serving
// a request from another slot are counted there, since
// the controller's own open path sees only success.
// Non-pool sessions need nothing.
func (c *Controller) notePoolAbsorbed(session proxySession) {
	if pool, ok := session.(*proxySessionPool); ok {
		pool.noteAbsorbed = c.noteEstablishedFailure
	}
}

func (c *Controller) swapSession(newSession proxySession, rawToken string, expiresAt time.Time) bool {
	c.notePoolAbsorbed(newSession)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = newSession.Close()
		return false
	}
	old := c.current
	c.current = &managedSession{
		session:   newSession,
		rawToken:  rawToken,
		expiresAt: expiresAt,
		accepting: true,
		server:    c.server.Addr,
	}
	if old != nil {
		old.accepting = false
		c.maybeCloseLocked(old)
	}
	c.mu.Unlock()
	c.writeStatus("session_swapped")
	return true
}

func (c *Controller) disableExpiredSession(now time.Time) {
	c.mu.Lock()
	changed := false
	if c.current != nil && c.current.accepting && !now.Before(c.current.expiresAt) {
		c.current.accepting = false
		c.maybeCloseLocked(c.current)
		changed = true
	}
	c.mu.Unlock()
	if changed {
		c.writeStatus("expired")
	}
}

// RetryNow forgets the waits that failures left behind (the spacing of
// rebuilds, and a pass renewal that failed for want of a network or an
// answer), so the next tunnel tries at once: the network came back, or the
// user is looking.
func (c *Controller) RetryNow() {
	c.renewMu.Lock()
	c.redialBackoff.reset()
	c.passBackoff.reset()
	c.renewMu.Unlock()
	c.mu.Lock()
	if code := FailureCode(c.lastRenewalErr); code == FailureNoNetwork || code == FailureUnreachable {
		c.nextAttemptAt = time.Time{}
	}
	c.mu.Unlock()
}

// Reconnect opens a new upstream session with the current pass and makes it
// current, closing the old one: after a network change the old session's
// connection belongs to a network that is gone, and finding that out
// request by request takes time. No new pass is needed.
func (c *Controller) Reconnect() error {
	c.mu.Lock()
	old := c.current
	if c.closed || old == nil || old.rawToken == "" || !time.Now().Before(old.expiresAt) {
		c.mu.Unlock()
		return ErrNoUsableSession
	}
	token, expiresAt := old.rawToken, old.expiresAt
	c.mu.Unlock()
	session, err := c.sessionFactory(token)
	if err != nil {
		return err
	}
	// Swap only if nothing replaced or renewed the session meanwhile (a
	// renewal, a rebuild, or a second Reconnect): the new session would
	// otherwise carry an older pass than the one it replaces.
	c.mu.Lock()
	if c.closed || c.current != old || old.rawToken != token {
		c.mu.Unlock()
		_ = session.Close()
		if c.isClosed() {
			return ErrNoUsableSession
		}
		return nil
	}
	c.mu.Unlock()
	if !c.swapSession(session, token, expiresAt) {
		return ErrNoUsableSession
	}
	c.mu.Lock()
	if old.session != nil {
		_ = old.session.Close()
		old.session = nil
	}
	c.mu.Unlock()
	return nil
}

// currentServer returns the server new sessions are opened to.
func (c *Controller) currentServer() Candidate {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.server
}

// failOver counts err, a failure to open or keep a session on the server
// from, against that server, and moves the controller to another server of
// the location when the failover says so (ServerFailover.Failed). It
// reports whether it moved. renewMu is held.
func (c *Controller) failOver(from Candidate, err error) bool {
	if c.failover == nil || err == nil || c.isClosed() {
		return false
	}
	next, ok := c.failover.Failed(c.location, from, err)
	if !ok {
		return false
	}
	target, parseErr := NormalizeURL(next.Addr)
	if parseErr != nil {
		logx.Warn("cannot switch to the next upstream server proxy=%s err=%s", next.Addr, logx.Err(parseErr))
		return false
	}
	c.mu.Lock()
	c.server, c.proxyURL = next, target
	c.mu.Unlock()
	// The new server starts with the quick redial steps.
	c.redialBackoff.reset()
	if c.OnServerSwitched != nil {
		c.OnServerSwitched(next)
	}
	return true
}

// CurrentToken returns the proxy pass of the current session.
func (c *Controller) CurrentToken() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil {
		return ""
	}
	return c.current.rawToken
}

func (c *Controller) currentExpiry() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil {
		return time.Time{}
	}
	return c.current.expiresAt
}

func (c *Controller) hasUsableSessionOtherThan(failedSession *managedSession, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed || c.current == nil || !c.current.accepting {
		return false
	}
	if failedSession != nil && c.current == failedSession {
		return false
	}
	return now.Before(c.current.expiresAt)
}

func (c *Controller) updateCurrentSessionToken(token string, expiresAt time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.current == nil || !c.current.accepting || !time.Now().Before(c.current.expiresAt) {
		return ErrNoUsableSession
	}
	updater, ok := c.current.session.(proxySessionTokenUpdater)
	if !ok {
		return fmt.Errorf("upstream session does not support token update")
	}
	if err := updater.UpdateToken(token); err != nil {
		return err
	}
	c.current.rawToken = token
	c.current.expiresAt = expiresAt
	c.current.afterRefusal = false
	return nil
}

func (c *Controller) Close() error {
	c.closeOnce.Do(func() {
		if c.done != nil {
			close(c.done)
		}

		c.mu.Lock()
		defer c.mu.Unlock()

		c.closed = true
		if c.current != nil {
			c.current.accepting = false
			if c.current.session != nil {
				c.closeErr = c.current.session.Close()
				c.current.session = nil
			}
		}
	})
	c.writeStatus("closed")
	return c.closeErr
}

// noteTraffic counts tunnel bytes toward the usage since the last quota
// reading and, near the switch point, requests an early quota check after
// every usageProbeBytes, so a heavy transfer cannot run far past the
// account switch threshold between pass renewals.
func (c *Controller) noteTraffic(n int) {
	if n <= 0 {
		return
	}
	c.trafficSinceReading.Add(int64(n))
	if c.trafficSinceCheck.Add(int64(n)) < usageProbeBytes {
		return
	}
	c.trafficSinceCheck.Store(0)
	if !c.nearSwitch() {
		return
	}
	select {
	case c.quotaCheckNow <- struct{}{}:
	default:
	}
}

// nearSwitch reports whether the active account's usage, as last read plus
// the tunnel traffic since then, is within quotaProbeMargin of its switch
// point: the switch threshold with an account pool (the service always has
// one, also when no other account could take over), the end of the quota
// without one. Unknown and unlimited quotas are never near.
func (c *Controller) nearSwitch() bool {
	c.mu.Lock()
	usage, since := c.usage, c.trafficSinceReading.Load()
	c.mu.Unlock()
	if usage == nil || usage.Unlimited || usage.Limit <= 0 {
		return false
	}
	switchAt := usage.Limit
	if c.accounts != nil {
		switchAt = int64(float64(usage.Limit) * c.accounts.mgr.Policy().ThresholdPercent / 100)
	}
	used := usage.Limit - usage.Remaining + since
	return switchAt-used <= quotaProbeMargin
}

type managedTunnelConn struct {
	net.Conn
	release func()
	traffic func(int)
	once    sync.Once
	// Build 2123 (audit F-01, gap 1): mid-stream death
	// evidence. A tunnel that dies after opening used to
	// be counted nowhere and logged nowhere — Read/Write
	// only counted bytes. The first non-EOF stream error
	// is now reported to the established-failure counter,
	// once per tunnel; a clean EOF and errors after a
	// local Close are normal endings, not deaths.
	noteFailure func(error)
	failureOnce sync.Once
	closedFlag  atomic.Bool
}

func (c *managedTunnelConn) noteStreamFailure(err error) {
	if err == nil || errors.Is(err, io.EOF) || c.closedFlag.Load() {
		return
	}
	if c.noteFailure != nil {
		c.failureOnce.Do(func() { c.noteFailure(err) })
	}
}

func (c *managedTunnelConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.noteStreamFailure(err)
	if c.traffic != nil {
		c.traffic(n)
	}
	return n, err
}

func (c *managedTunnelConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.noteStreamFailure(err)
	if c.traffic != nil {
		c.traffic(n)
	}
	return n, err
}

func (c *managedTunnelConn) Close() error {
	var err error
	c.once.Do(func() {
		c.closedFlag.Store(true)
		err = c.Conn.Close()
		if c.release != nil {
			c.release()
		}
	})
	return err
}

func (c *managedTunnelConn) CloseRead() error {
	if closeReader, ok := c.Conn.(interface{ CloseRead() error }); ok {
		return closeReader.CloseRead()
	}
	return nil
}

func (c *managedTunnelConn) CloseWrite() error {
	if closeWriter, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return closeWriter.CloseWrite()
	}
	return nil
}
