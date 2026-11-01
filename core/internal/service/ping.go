package service

import (
	"context"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
	"github.com/armanlife/firefox-vpn-client/core/internal/proxy"
)

const (
	// pingReuseAge is how long a measurement is reused when the "fastest"
	// location is chosen at an engine start.
	pingReuseAge = 30 * time.Minute
)

// PingAll measures the current server list through the running proxy's
// pass and keeps the result for the dashboard and the terminal screen.
// codes limits the measurement to those country codes; empty measures
// every location. Without a running proxy (the phone app turned it off)
// it measures with a pass of its own (offPass). An engine that exists
// but cannot be woken — its last connect failed and the retry wait is
// still running, the state the desktop TUN mode reaches whenever the
// TUN session churns — falls back to the same offPass measurement
// instead of refusing the test outright: the measurement itself is a
// direct per-location session either way (proxy.TunnelMeter), and a
// refused test reads to the user as a broken ping while disconnected
// measuring works.
func (d *Daemon) PingAll(ctx context.Context, codes []string) ([]proxy.LocationPing, time.Time, error) {
	engine := d.currentEngine()
	if engine == nil {
		return d.pingWithOffPass(ctx, codes)
	}
	// A real-delay test wakes a sleeping proxy and keeps it awake.
	controller, release, err := d.useController(engine, wakeForPing)
	if err != nil {
		logx.Warn("ping: waking the proxy failed; measuring with a pass of its own err=%s", logx.Err(err))
		return d.pingWithOffPass(ctx, codes)
	}
	defer release()
	token := controller.CurrentToken()
	if token == "" {
		logx.Warn("ping: the woken proxy has no pass; measuring with a pass of its own")
		return d.pingWithOffPass(ctx, codes)
	}
	results, at := d.measureLocations(ctx, token, codes)
	return results, at, nil
}

// pingWithOffPass measures with a pass acquired for the test itself:
// the disconnected path of PingAll.
func (d *Daemon) pingWithOffPass(ctx context.Context, codes []string) ([]proxy.LocationPing, time.Time, error) {
	token, err := d.offPass(ctx)
	if err != nil {
		return nil, time.Time{}, err
	}
	results, at := d.measureLocations(ctx, token, codes)
	return results, at, nil
}

// offPassMargin is how long before its expiry a kept pass is replaced.
const offPassMargin = 2 * time.Minute

// offPass returns a pass for measurements while the proxy is off: the kept
// one while it is valid, else a new one from the account pool.
func (d *Daemon) offPass(ctx context.Context) (string, error) {
	d.pingMu.Lock()
	defer d.pingMu.Unlock()
	if p := d.pingPass; p != nil && time.Until(p.ExpiresAt()) > offPassMargin {
		return p.RawToken, nil
	}
	if d.mgr.Len() == 0 {
		return "", errNoAccounts
	}
	ctx, cancel := context.WithTimeout(ctx, proxy.PassRenewTimeout)
	defer cancel()
	_, pass, err := d.pool.AcquirePass(ctx, d.config().Network.GuardianEndpoint)
	if err != nil {
		return "", err
	}
	d.pingPass = pass
	return pass.RawToken, nil
}

// measureLocations measures the given locations (all when codes is
// empty) and merges the results into the kept measurement, so testing one
// tab keeps the other locations' earlier values.
func (d *Daemon) measureLocations(ctx context.Context, token string, codes []string) ([]proxy.LocationPing, time.Time) {
	d.pingMu.Lock()
	defer d.pingMu.Unlock()
	d.mu.Lock()
	countries := d.countries
	d.mu.Unlock()
	if len(countries) == 0 {
		countries = d.refreshLocations(d.config())
	}
	targets := proxy.FilterTargets(proxy.PingTargets(countries), codes)
	logx.Info("testing the real delay through the tunnel locations=%d target=%s", len(targets), proxy.PingTarget)
	results := proxy.PingLocations(ctx, targets, proxy.TunnelMeter(token))
	now := time.Now()
	d.mu.Lock()
	d.pings, d.pingedAt = proxy.MergePings(d.pings, results), now
	d.mu.Unlock()
	reachable := 0
	for _, r := range results {
		if r.OK() {
			reachable++
		}
	}
	if reachable > 0 {
		logx.Info("location latency measured locations=%d reachable=%d fastest=%s ping_ms=%d", len(results), reachable, results[0].Code, results[0].PingMS)
	} else {
		logx.Warn("location latency measured; no location answered locations=%d", len(results))
	}
	return results, now
}

// lastPings returns the most recent measurement, if any.
func (d *Daemon) lastPings() ([]proxy.LocationPing, time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]proxy.LocationPing(nil), d.pings...), d.pingedAt
}

// resolveFastestCountry returns the country code to use for
// proxy.country = "fastest": from a recent measurement, or measured now
// with token. It returns "" (the recommended location) when nothing could
// be measured.
func (d *Daemon) resolveFastestCountry(token string) string {
	results, at := d.lastPings()
	if time.Since(at) > pingReuseAge {
		results, _ = d.measureLocations(context.Background(), token, nil)
	}
	best, ok := proxy.FastestLocation(results)
	if !ok {
		logx.Warn("no location answered the latency check; using the recommended location")
		return ""
	}
	logx.Info("fastest location selected country_code=%s ping_ms=%d", best.Code, best.PingMS)
	return best.Code
}
