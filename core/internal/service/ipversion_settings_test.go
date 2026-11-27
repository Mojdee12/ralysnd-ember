package service

import (
	"testing"

	"github.com/armanlife/firefox-vpn-client/core/internal/resolver"
)

// Build 2105 (verification iteration 1): a settings change to
// dns.ip_version alone must reach the live resolver policy — the
// value was saved and shown while dials kept the old policy until
// a daemon restart, because updateSettings only re-applied the
// DNS configuration when the servers or the fallback changed.
func TestUpdateSettingsAppliesIPVersionLive(t *testing.T) {
	d := newTestDaemon(t)
	resolver.SetIPVersion("auto")
	t.Cleanup(func() { resolver.SetIPVersion("auto") })

	next := d.cfg
	next.DNS.IPVersion = "ipv6_only"
	if _, err := d.updateSettings(next, nil); err != nil {
		t.Fatal(err)
	}
	if got := resolver.CurrentIPVersion(); got != "ipv6_only" {
		t.Fatalf("live resolver policy = %q, want ipv6_only after an ip_version-only settings change", got)
	}

	next.DNS.IPVersion = "ipv4_only"
	if _, err := d.updateSettings(next, nil); err != nil {
		t.Fatal(err)
	}
	if got := resolver.CurrentIPVersion(); got != "ipv4_only" {
		t.Fatalf("live resolver policy = %q, want ipv4_only", got)
	}
}
