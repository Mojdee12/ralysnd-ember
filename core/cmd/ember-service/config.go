package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// serviceConfig is the small persisted state the installer
// writes and the service reads at start: the app folders the
// service may run engine executables from. It carries no
// secrets — paths only.
type serviceConfig struct {
	AppRoots []string `json:"appRoots"`
}

func configPath() string {
	dir := os.Getenv("ProgramData")
	if dir == "" {
		dir = `C:\ProgramData`
	}
	return filepath.Join(dir, "Ralysnd Ember", "service.json")
}

func loadRoots() *rootSet {
	roots := newRootSet(nil)
	if b, err := os.ReadFile(configPath()); err == nil {
		var cfg serviceConfig
		if err := json.Unmarshal(b, &cfg); err == nil {
			for _, r := range cfg.AppRoots {
				roots.add(r)
			}
		}
	}
	// The folder the service's own exe lives in is two levels
	// below an app root when the exe runs from the app's core\
	// folder (dev/portable runs); when it runs from Program
	// Files that parent is the service's own folder, which
	// contains no engine exes and is harmless to register.
	if exe, err := os.Executable(); err == nil {
		roots.add(filepath.Dir(filepath.Dir(exe)))
	}
	return roots
}

func saveRoots(roots []string) error {
	p := configPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(serviceConfig{AppRoots: roots})
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o644)
}
