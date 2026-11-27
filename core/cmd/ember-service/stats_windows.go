//go:build windows

package main

import "golang.org/x/sys/windows"

// adapterBytes reads the interface's octet counters through
// GetIfEntry2: InOctets is what the system received through the
// adapter (the tunnel's download), OutOctets what it sent (the
// upload).
func adapterBytes(ifIndex uint32) (up, down uint64, ok bool) {
	if ifIndex == 0 {
		return 0, 0, false
	}
	row := windows.MibIfRow2{InterfaceIndex: ifIndex}
	if err := windows.GetIfEntry2Ex(0, &row); err != nil {
		return 0, 0, false
	}
	return row.OutOctets, row.InOctets, true
}
