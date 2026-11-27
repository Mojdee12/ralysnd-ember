//go:build windows

package main

import (
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// processImages snapshots pid → image path for every process.
func processImages() map[uint32]string {
	out := make(map[uint32]string)
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return out
	}
	defer windows.CloseHandle(snap)
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Process32First(snap, &entry); err != nil {
		return out
	}
	for {
		if h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, entry.ProcessID); err == nil {
			buf := make([]uint16, windows.MAX_PATH)
			size := uint32(len(buf))
			if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &size); err == nil && size > 0 {
				out[entry.ProcessID] = windows.UTF16ToString(buf[:size])
			}
			windows.CloseHandle(h)
		}
		if err := windows.Process32Next(snap, &entry); err != nil {
			break
		}
	}
	return out
}

func killPID(pid uint32) {
	h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		return
	}
	defer windows.CloseHandle(h)
	_ = windows.TerminateProcess(h, 1)
}

// reapExePath kills processes whose image is exactly exe and
// which this service did not start (a crashed app or service
// instance left them holding the engine's ports/identity). The
// manager's own children share the image path, so callers run
// this BEFORE launching their replacement — and the manager
// only calls it when its own record for the name is stopped.
func reapExePath(exe string, owned map[int]bool) {
	want := cleanPath(exe)
	self := uint32(windows.GetCurrentProcessId())
	for pid, image := range processImages() {
		if pid == self || owned[int(pid)] {
			continue
		}
		if cleanPath(image) == want {
			killPID(pid)
		}
	}
}

// reapOrphans clears allowlisted engine executables running
// from under any registered app root at service start.
func reapOrphans(roots *rootSet) {
	self := uint32(windows.GetCurrentProcessId())
	for pid, image := range processImages() {
		if pid == self {
			continue
		}
		base := strings.ToLower(filepath.Base(image))
		if !allowedExes[base] {
			continue
		}
		for _, root := range roots.list() {
			if underRoot(cleanPath(image), root) {
				killPID(pid)
				break
			}
		}
	}
}
