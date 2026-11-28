//go:build !windows

package main

// secureWGStoreDir is a no-op off Windows: POSIX modes
// (0o700 on the folder, 0o600 on the files) already confine
// the WireGuard config store there. The Windows build applies
// an explicit DACL instead — see wg_dacl_windows.go.
func secureWGStoreDir(string) error { return nil }
