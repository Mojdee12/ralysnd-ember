//go:build !windows

package main

// The URnetwork packet pump is Windows-only: its adapter is a
// Wintun adapter (ur_pump_windows.go), and this service ships
// only on Windows. On every other platform urPumpOpener and
// urEgressIndex stay nil, so ur.go's manager never creates a
// pump and ur.status keeps reporting tunneled:false — the
// honest answer for a build that cannot capture traffic.
// The pump lifecycle logic itself (ur_pump.go) is
// platform-neutral and is exercised on Linux by
// ur_pump_test.go with a fake adapter and a fake device.
