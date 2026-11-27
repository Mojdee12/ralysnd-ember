//go:build !windows

package main

// reapExePath kills processes running the given executable that
// this service does not own (owned PIDs are always spared).
// Windows-only; a no-op elsewhere.
func reapExePath(exe string, owned map[int]bool) {}

// reapOrphans clears allowlisted engine processes left behind
// under the registered roots by a crashed app or service.
func reapOrphans(roots *rootSet) {}
