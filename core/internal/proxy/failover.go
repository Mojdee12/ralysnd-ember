package proxy

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
)

const (
	// serverFailoverStrikes is how many counted failures of one
	// server move the upstream to another server of the location.
	// A rebuild counts once, and rebuilds are spaced (redials 0,
	// 10 s, 30 s; new passes 10 s apart and more), so a dead
	// server is left within about 10 to 40 seconds; one or two
	// failures are what a short network blip (a Wi-Fi roam, a
	// mobile handover) does, and must not move the server. It
	// matches the failure tracker's three distinct failing
	// targets.
	serverFailoverStrikes = 3

	// serverAvoidTime is how long a server that reached
	// serverFailoverStrikes is skipped. It outlasts several rounds of the
	// longest rebuild spacing (2 minutes), so the location's other servers
	// are tried before it, and is short enough that a server back from a
	// restart or a short outage returns to the choice within a quarter of
	// an hour.
	serverAvoidTime = 15 * time.Minute
)

// ServerFailover moves the upstream to another server of the chosen
// location when one server keeps failing: after serverFailoverStrikes
// failures to establish or keep a session on it (serverFault
// decides which failures are the server's; a success on that
// server clears its count), the server is avoided for
// serverAvoidTime and another server of the same city, else of the
// location's next city, is used and saved as the persisted choice. When
// every other server of the location is avoided, the upstream stays where
// it is and the usual retries go on; the location never changes.
//
// One per daemon: it outlives controllers and engines, so the wakes and
// the controllers of one location share the strikes and the avoided
// servers. A nil ServerFailover does nothing (a server set by hand).
type ServerFailover struct {
	// selectionFile is where a new choice is saved (selection.json); empty
	// saves nothing.
	selectionFile string
	// now is the clock; tests replace it.
	now func() time.Time
	// pending is set while a server has strikes, so Worked, called for
	// every tunnel, takes no lock otherwise.
	pending atomic.Bool

	mu sync.Mutex
	// strikes counts failures PER SERVER (canonical address),
	// shared by Failed and FailedFast (build 2105). Before
	// 2105 a single counter served the one failing server and
	// reset whenever a different server failed; a connect walk
	// alternates servers by construction, so that counter
	// could never reach the threshold, and two counters (one
	// per path) could neither sum nor clear each other. One
	// map: a server's count is cleared by Worked (a tunnel
	// opened through it) or by crossing the threshold into
	// avoidance. A count whose last failure is older than the
	// avoidance window is forgotten before the next increment,
	// so the threshold always means failures close in time —
	// never "3 failures ever" accumulated across weeks.
	strikes map[string]failoverStrike
	// avoided maps canonical addresses to the end of their avoidance.
	avoided map[string]time.Time
}

// failoverStrike is one server's recent failure count and
// when the last failure happened (see strikes on the struct).
type failoverStrike struct {
	count int
	last  time.Time
}

// NewServerFailover returns a failover that saves new choices in
// selectionFile.
func NewServerFailover(selectionFile string) *ServerFailover {
	return &ServerFailover{selectionFile: selectionFile, now: time.Now}
}

// Avoided reports whether the server at addr failed recently and is
// skipped by selection.
func (f *ServerFailover) Avoided(addr string) bool {
	if f == nil {
		return false
	}
	key, err := canonicalProxyAddr(addr)
	if err != nil {
		return false
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.avoidedLocked(key, f.now())
}

func (f *ServerFailover) avoidedLocked(key string, now time.Time) bool {
	until, ok := f.avoided[key]
	if ok && !now.Before(until) {
		delete(f.avoided, key)
		return false
	}
	return ok
}

// Worked forgets the strikes of the server at addr: a tunnel opened
// through it.
func (f *ServerFailover) Worked(addr string) {
	if f == nil || !f.pending.Load() {
		return
	}
	key, err := canonicalProxyAddr(addr)
	if err != nil {
		return
	}
	f.mu.Lock()
	delete(f.strikes, key)
	f.pending.Store(len(f.strikes) > 0)
	f.mu.Unlock()
}

// Failed counts err against server, one of location's servers, when the
// server is to blame (serverFault). At its serverFailoverStrikes-th
// counted failure the server is avoided for serverAvoidTime and Failed
// returns the server to use instead (nextServer), saved as the persisted
// choice. ok is false otherwise, also when every other server of the
// location is avoided: the caller then stays on server.
func (f *ServerFailover) Failed(location []Candidate, server Candidate, err error) (next Candidate, ok bool) {
	if f == nil || !serverFault(err) {
		return Candidate{}, false
	}
	key, keyErr := canonicalProxyAddr(server.Addr)
	if keyErr != nil {
		return Candidate{}, false
	}
	f.mu.Lock()
	now := f.now()
	if f.strikes == nil {
		f.strikes = make(map[string]failoverStrike)
	}
	s := f.strikes[key]
	if now.Sub(s.last) > serverAvoidTime {
		s.count = 0
	}
	s.count++
	s.last = now
	f.strikes[key] = s
	f.pending.Store(true)
	if s.count < serverFailoverStrikes {
		f.mu.Unlock()
		logx.Debug("upstream server failed proxy=%s failures=%d err=%s", server.Addr, s.count, logx.Err(err))
		return Candidate{}, false
	}
	delete(f.strikes, key)
	f.pending.Store(len(f.strikes) > 0)
	if f.avoided == nil {
		f.avoided = make(map[string]time.Time)
	}
	f.avoided[key] = now.Add(serverAvoidTime)
	next, ok = nextServer(location, server, func(addr string) bool {
		k, err := canonicalProxyAddr(addr)
		return err == nil && f.avoidedLocked(k, now)
	})
	f.mu.Unlock()

	if !ok {
		logx.Warn("upstream server failed %d times, and every other server of the location failed recently; staying on it proxy=%s err=%s",
			serverFailoverStrikes, server.Addr, logx.Err(err))
		return Candidate{}, false
	}
	logx.Info("upstream server failed %d times; switching to another server of the location from=%s to=%s city=%q avoid_for=%s err=%s",
		serverFailoverStrikes, server.Addr, next.Addr, next.CityNameOrUnknown(), serverAvoidTime, logx.Err(err))
	if f.selectionFile != "" {
		if err := SaveSelection(f.selectionFile, next); err != nil {
			logx.Warn("saving proxy selection failed path=%s err=%s", f.selectionFile, logx.Err(err))
		}
	}
	return next, true
}

// FailedFast is the connect-time variant of Failed (build 2105,
// proxy.fast_failover): a failure to ESTABLISH a session is counted
// under the same rules Failed counts it — same serverFault gate,
// same strike threshold, same 15-minute avoidance and persisted
// selection when the threshold is reached — but the next server of
// the location (same city first) is returned at once, on the first
// strike already, so the caller can retry inside the same connect
// attempt. Both paths count into the one per-server strike map
// (see strikes on the struct). tried reports the servers this
// connect attempt has already used; they are skipped like
// avoided ones, for this call only (no avoidance is recorded
// for them below the threshold).
// Mid-session failures never come here: Failed keeps its 3-strike
// patience for them, fast failover or not.
// crossed reports whether THIS call crossed the strike threshold
// (and so recorded avoidance and, when a next server exists,
// persisted it as the selection): a caller adopting a switch on
// total failure must use it rather than inferring the crossing
// from Avoided state, which an earlier path may have set for an
// unrelated reason (verification iteration 4, build 2105).
func (f *ServerFailover) FailedFast(location []Candidate, server Candidate, err error, tried func(addr string) bool) (next Candidate, ok bool, crossed bool) {
	if f == nil || !serverFault(err) {
		return Candidate{}, false, false
	}
	key, keyErr := canonicalProxyAddr(server.Addr)
	if keyErr != nil {
		return Candidate{}, false, false
	}
	f.mu.Lock()
	// The one per-server strike map, shared with Failed (see
	// strikes on the struct): the threshold, the avoidance and
	// the persistence below are Failed's, unchanged.
	now := f.now()
	if f.strikes == nil {
		f.strikes = make(map[string]failoverStrike)
	}
	s := f.strikes[key]
	if now.Sub(s.last) > serverAvoidTime {
		s.count = 0
	}
	s.count++
	s.last = now
	f.strikes[key] = s
	f.pending.Store(true)
	if s.count >= serverFailoverStrikes {
		delete(f.strikes, key)
		f.pending.Store(len(f.strikes) > 0)
		if f.avoided == nil {
			f.avoided = make(map[string]time.Time)
		}
		f.avoided[key] = now.Add(serverAvoidTime)
		crossed = true
	}
	next, ok = nextServer(location, server, func(addr string) bool {
		if tried != nil && tried(addr) {
			return true
		}
		k, err := canonicalProxyAddr(addr)
		return err == nil && f.avoidedLocked(k, now)
	})
	f.mu.Unlock()
	if !ok {
		return Candidate{}, false, crossed
	}
	if crossed && f.selectionFile != "" {
		// The persistence Failed performs when it moves the
		// upstream: the switch target becomes the saved choice.
		if err := SaveSelection(f.selectionFile, next); err != nil {
			logx.Warn("saving proxy selection failed path=%s err=%s", f.selectionFile, logx.Err(err))
		}
	}
	logx.Info("upstream server failed at connect; fast failover to another server of the location from=%s to=%s city=%q err=%s",
		server.Addr, next.Addr, next.CityNameOrUnknown(), logx.Err(err))
	return next, true, crossed
}

// nextServer picks the server to use instead of current: another server
// of current's city, else one of the location's first other city that has
// one, at random within the city (as pickInFirstCity does), skipping
// avoided servers.
func nextServer(location []Candidate, current Candidate, avoided func(addr string) bool) (Candidate, bool) {
	currentKey, _ := canonicalProxyAddr(current.Addr)
	usable := func(c Candidate) bool {
		key, err := canonicalProxyAddr(c.Addr)
		return err == nil && key != currentKey && !avoided(c.Addr)
	}
	if next, ok := pickInFirstCity(location, func(c Candidate) bool { return sameCity(c, current) && usable(c) }); ok {
		return next, true
	}
	return pickInFirstCity(location, usable)
}

// sameCity reports whether a and b are servers of one city.
func sameCity(a, b Candidate) bool {
	return strings.EqualFold(a.CountryCode, b.CountryCode) && a.CityCode == b.CityCode && a.CityName == b.CityName
}

// serverFault reports whether err, a failure to establish or keep a
// session on a Mozilla proxy server, can be blamed on that server. It
// cannot when this device has no network, when the account or its pass is
// the problem (Guardian's answers; a CONNECT 401, 403, 407, or 429), when
// the attempt was cancelled or did not happen (a rebuild cooling down, no
// session to use), or for a port Mozilla's proxy refuses (such a 502 never
// gets here: it neither rebuilds nor marks a session unhealthy).
func serverFault(err error) bool {
	if err == nil ||
		errors.Is(err, context.Canceled) ||
		errors.Is(err, errRebuildCoolingDown) ||
		errors.Is(err, ErrNoUsableSession) ||
		errors.Is(err, errSessionSaturated) {
		return false
	}
	switch FailureCode(err) {
	case FailureNoNetwork, FailureSignIn, FailureQuota, FailureNotEntitled, FailureRegion,
		FailureNoAccount, FailureServer, FailureLocationRefused:
		return false
	}
	var connectErr *proxyConnectHTTPError
	if errors.As(err, &connectErr) {
		switch connectErr.statusCode {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusProxyAuthRequired, http.StatusTooManyRequests:
			return false
		}
	}
	return true
}
