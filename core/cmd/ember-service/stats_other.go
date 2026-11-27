//go:build !windows

package main

// adapterBytes reads the interface's received/sent octet
// counters. Windows-only (GetIfEntry2); elsewhere the TUN state
// reports counters as unavailable rather than inventing them.
func adapterBytes(ifIndex uint32) (up, down uint64, ok bool) {
	return 0, 0, false
}
