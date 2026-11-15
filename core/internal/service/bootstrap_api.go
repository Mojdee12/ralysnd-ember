package service

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/config"
	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
)

// Bootstrap endpoints (build 2034): the app-driven half of the
// serverless Guardian-451 bootstrap. The app picks an egress (a
// donor engine's loopback SOCKS, or the saved Worker relay), keeps
// that route alive, and calls prepare; the daemon fetches a fresh
// ProxyPass through the egress and persists it, after which the app
// stops the donor and connects Mozilla directly on the stored pass.

// bootstrapView is the status view's bootstrap block: which egress
// the daemon would use, and whether relay credentials are saved
// (the key itself is never reported).
type bootstrapView struct {
	Egress      string `json:"egress"`
	RelayURL    string `json:"relay_url,omitempty"`
	RelayKeySet bool   `json:"relay_key_set"`
}

// updateBootstrapConfig applies mutate to the network config,
// validates the whole config, saves it, and swaps it in — the
// focused counterpart of updateSettings for the bootstrap fields,
// so the app never has to round-trip the full config.
func (d *Daemon) updateBootstrapConfig(mutate func(*config.Network)) (config.Config, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	next := d.cfg
	mutate(&next.Network)
	if err := next.Validate(); err != nil {
		return config.Config{}, err
	}
	if err := config.Save(d.paths.Config, next); err != nil {
		return config.Config{}, err
	}
	d.cfg = next
	return next, nil
}

// handleBootstrapRelay saves (or clears) the Worker relay pair as a
// bootstrap egress: POST /api/bootstrap/relay {"url","key"} — both
// empty clears. The daemon validates and persists them; the key is
// stored in the owner-only config, beside the dashboard password
// hash, and is never echoed back.
func (s *dashboardServer) handleBootstrapRelay(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URL string `json:"url"`
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	body.URL = strings.TrimSpace(body.URL)
	if err := config.ValidateBootstrapRelay(body.URL, body.Key); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	next, err := s.d.updateBootstrapConfig(func(n *config.Network) {
		n.BootstrapRelayURL = body.URL
		n.BootstrapRelayKey = body.Key
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := configureBootstrap(next.Network); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	logx.Info("bootstrap relay saved set=%v", body.URL != "")
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"relay_url":     next.Network.BootstrapRelayURL,
		"relay_key_set": next.Network.BootstrapRelayKey != "",
	})
}

// handleBootstrapPrepare runs the prepare handoff:
// POST /api/bootstrap/prepare {"socks": "127.0.0.1:1080"} for a
// donor egress, or {"relay": true} for the saved Worker relay. The
// server list is refreshed and a fresh pass is fetched and
// persisted, all inside one bootstrap egress window; the answer
// carries the stored pass's expiry.
func (s *dashboardServer) handleBootstrapPrepare(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Socks string `json:"socks"`
		Relay bool   `json:"relay"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	cfg := s.d.config()
	switch {
	case body.Socks != "":
		if err := config.ValidateBootstrapSocks(body.Socks); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		next, err := s.d.updateBootstrapConfig(func(n *config.Network) {
			n.BootstrapSocks = body.Socks
		})
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = next
		controlplane.SetBootstrapSocks(body.Socks)
	case body.Relay:
		if cfg.Network.BootstrapRelayURL == "" || cfg.Network.BootstrapRelayKey == "" {
			writeError(w, http.StatusBadRequest, "no Worker relay is saved; save the relay URL and key first")
			return
		}
		if err := controlplane.SetBootstrapRelay(cfg.Network.BootstrapRelayURL, cfg.Network.BootstrapRelayKey); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	default:
		writeError(w, http.StatusBadRequest, "choose a bootstrap egress: a donor socks address or the saved relay")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	var expires time.Time
	err := controlplane.WithBootstrapEgress(ctx, func(ctx context.Context) error {
		// Best-effort: the locations ride the same window, so a
		// stale server list refreshes while the route is open.
		_ = s.d.refreshLocations(s.d.config())
		pass, err := s.d.pool.PreparePass(ctx, cfg.Network.GuardianEndpoint)
		if err != nil {
			return err
		}
		expires = pass.ExpiresAt()
		return nil
	})
	if err != nil {
		logx.Warn("bootstrap prepare failed: %s", logx.Err(err))
		if errors.Is(err, guardian.ErrRegionUnavailable) {
			writeError(w, http.StatusUnavailableForLegalReasons, "Guardian still refuses this connection (HTTP 451) — the bootstrap route did not get through either: "+err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, "bootstrap prepare failed: "+err.Error())
		return
	}
	logx.Info("bootstrap prepare stored a pass expiring %s", expires.Format(time.RFC3339))
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"pass_expires_at": expires.Unix(),
	})
}
