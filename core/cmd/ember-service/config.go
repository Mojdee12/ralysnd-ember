package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// serviceConfig is the small persisted state the installer
// writes and the service reads at start: the app folders the
// service may run engine executables from, and the SID of the
// user the install was performed for. It carries no secrets —
// paths and an account identifier only.
type serviceConfig struct {
	AppRoots []string `json:"appRoots"`
	// OwnerSID is the Windows SID (string form, e.g.
	// "S-1-5-21-…-1001") of the user who owns this install,
	// recorded by the installer. The pipe listener
	// (serve_windows.go) binds every accepted connection to
	// it: the INTERACTIVE ACE in the pipe SDDL is only a
	// pre-filter, this SID is the actual boundary (2042
	// adversarial review C2). Empty means "not recorded"
	// (dev/console/portable runs) and disables the check.
	OwnerSID string `json:"ownerSid,omitempty"`
}

func configPath() string {
	dir := os.Getenv("ProgramData")
	if dir == "" {
		dir = `C:\ProgramData`
	}
	return filepath.Join(dir, "Ralysnd Ember", "service.json")
}

// loadServiceConfig reads the persisted config; a missing or
// unreadable file yields the zero config, never an error —
// the service must still start (with no roots and no owner
// binding) rather than die on a damaged state file.
func loadServiceConfig() serviceConfig {
	var cfg serviceConfig
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	return cfg
}

// loadOwnerSID returns the recorded owner SID, read fresh
// from disk on every call so an install that records it after
// the service started is honoured without a restart.
func loadOwnerSID() string {
	return strings.TrimSpace(loadServiceConfig().OwnerSID)
}

// ownerSIDAllows is the pure accept/reject decision for one
// pipe connection (serve_windows.go): no recorded owner means
// the check is disabled (dev/console/portable); a recorded
// owner requires an exact SID match — an unidentifiable
// client (empty client SID) is refused.
func ownerSIDAllows(recorded, client string) bool {
	recorded = strings.TrimSpace(recorded)
	if recorded == "" {
		return true
	}
	client = strings.TrimSpace(client)
	if client == "" {
		return false
	}
	return strings.EqualFold(recorded, client)
}

// sharedParentNames are directory names that must never be
// auto-registered as an app root: they are shared parents of
// many vendors' installs, so registering one would make every
// allowlisted-named binary underneath it launchable by this
// SYSTEM service (2042 adversarial review C3).
var sharedParentNames = map[string]bool{
	"program files":       true,
	"program files (x86)": true,
	"programdata":         true,
	"windows":             true,
	"windowsapps":         true,
}

// exeAutoRoot derives the app root to auto-register from the
// service exe's own path: the exe's grandparent folder (the
// exe normally runs from <root>\core\). It returns ok=false
// when the grandparent must NOT be registered (review C3):
// a drive root, a shared parent (Program Files & friends),
// or a path with fewer than 3 components. Pure over path
// strings — separators are normalised inside — so it is
// unit-testable on any OS with Windows-style paths.
func exeAutoRoot(exe string) (string, bool) {
	norm := strings.ReplaceAll(strings.TrimSpace(exe), "\\", "/")
	grand := slashDir(slashDir(norm))
	if grand == "" || grand == "/" {
		return "", false
	}
	parts := make([]string, 0, 4)
	for _, seg := range strings.Split(grand, "/") {
		if seg != "" {
			parts = append(parts, seg)
		}
	}
	// Fewer than 3 components means the grandparent is a
	// drive root ("C:"), a top-level folder ("C:/Ember") or
	// a filesystem root — all shared or anchor locations,
	// never a private app folder.
	if len(parts) < 3 {
		return "", false
	}
	if sharedParentNames[strings.ToLower(parts[len(parts)-1])] {
		return "", false
	}
	return grand, true
}

// slashDir is path.Dir over "/" separators, for use on
// normalised Windows-style paths on any host OS.
func slashDir(p string) string {
	p = strings.TrimSuffix(p, "/")
	if i := strings.LastIndex(p, "/"); i >= 0 {
		if i == 0 {
			return "/"
		}
		return p[:i]
	}
	return ""
}

func loadRoots() *rootSet {
	roots := newRootSet(nil)
	for _, r := range loadServiceConfig().AppRoots {
		roots.add(r)
	}
	// The folder the service's own exe lives in is two levels
	// below an app root when the exe runs from the app's core\
	// folder (dev/portable runs). The grandparent is only
	// auto-registered when exeAutoRoot proves it is a private
	// app folder — never a shared parent like Program Files
	// (review C3: the old unconditional add registered all of
	// C:\Program Files as a root).
	if exe, err := os.Executable(); err == nil {
		if root, ok := exeAutoRoot(exe); ok {
			roots.add(root)
		}
	}
	return roots
}

func saveRoots(roots []string) error {
	p := configPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	// Preserve fields this function does not own (OwnerSID,
	// recorded by the installer) instead of wiping them.
	cfg := loadServiceConfig()
	cfg.AppRoots = roots
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o644)
}
