package main

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// TestAllowlistReconciledWithShell is the BLOCKING
// reconciliation test whose absence shipped 2041's B-2/C1
// blocker: the service's allowedExes refused four of the
// engines the Electron shell itself starts (xray.exe,
// firefox-vpn-core.exe, psiphon-core.exe, amneziawg.exe),
// while a dead entry (lantern-bridge.exe) sat allowlisted.
//
// It parses the shell's ENGINE_CFG table (and TUN_EXE) out of
// electron/renderer/controllers.js and fails if:
//   - any exe the shell can start is missing from allowedExes, or
//   - allowedExes carries an exe the shell never starts that is
//     not a known service-internal binary (started by the
//     service's own drivers — lantern/ovpn/tun/warp — rather
//     than by a shell ENGINE_CFG row).
func TestAllowlistReconciledWithShell(t *testing.T) {
	path := filepath.Join("..", "..", "..", "electron", "renderer", "controllers.js")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shell's controllers.js: %v", err)
	}
	shell := map[string]bool{}
	for _, m := range regexp.MustCompile(`exe:\s*'([^']+)'`).FindAllSubmatch(src, -1) {
		shell[string(m[1])] = true
	}
	for _, m := range regexp.MustCompile(`const TUN_EXE = '([^']+)'`).FindAllSubmatch(src, -1) {
		shell[string(m[1])] = true
	}
	if len(shell) < 9 {
		t.Fatalf("parsed only %d shell exes from controllers.js — the parser or the table moved", len(shell))
	}
	for exe := range shell {
		if !allowedExes[exe] {
			t.Errorf("shell starts %s but allowedExes refuses it", exe)
		}
	}
	// Service-internal binaries: started by the service's own
	// drivers, so the shell's table need not name them. Any
	// OTHER allowlist entry the shell never starts is drift —
	// the lantern-bridge.exe dead entry is the cautionary tale.
	internal := map[string]bool{
		"lanternd.exe":         true, // lantern driver
		"openvpn.exe":          true, // ovpn driver
		"ember-tun-bridge.exe": true, // tun driver
		"usque.exe":            true, // warp/MASQUE driver path
		"aether.exe":           true, // warp fallback driver path
		"sing-box.exe":         true, // service-side second core
		"amneziawg.exe":        true, // wg driver (wg.go drives it via /installtunnelservice; the shell's ENGINE_CFG wireguard row was replaced by the service wg.* methods during the 2042 repair)
	}
	for exe := range allowedExes {
		if !shell[exe] && !internal[exe] {
			t.Errorf("allowedExes carries %s, which the shell never starts and no service driver owns", exe)
		}
	}
	if allowedExes["lantern-bridge.exe"] {
		t.Error("lantern-bridge.exe is allowlisted but no longer ships (dead entry, 2041 audit C1)")
	}
	for _, want := range []string{"xray.exe", "firefox-vpn-core.exe", "psiphon-core.exe", "amneziawg.exe"} {
		if !allowedExes[want] {
			t.Errorf("allowedExes is missing the shell engine %s (2041 audit B-2)", want)
		}
	}
}
