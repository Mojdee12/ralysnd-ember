//go:build windows

package main

import (
	"context"
	"fmt"
	"net"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

var (
	kernel32                  = windows.NewLazySystemDLL("kernel32.dll")
	procGetNamedPipeServerPID = kernel32.NewProc("GetNamedPipeServerProcessId")
)

// authenticateRadiancePipe verifies the process answering on
// the daemon's pipe: open the pipe, ask Windows for the server
// process id, require it to be the lanternd this service
// started, and require that process's image to be the exe we
// launched. Anything else is refused before a single call is
// proxied.
func authenticateRadiancePipe(pid int, exePath string) error {
	path, err := windows.UTF16PtrFromString(radiancePipePath)
	if err != nil {
		return err
	}
	h, err := windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE,
		0, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return fmt.Errorf("open the Lantern pipe: %w", err)
	}
	defer windows.CloseHandle(h)
	var serverPID uint32
	r, _, callErr := procGetNamedPipeServerPID.Call(uintptr(h), uintptr(unsafe.Pointer(&serverPID)))
	if r == 0 {
		return fmt.Errorf("identify the Lantern pipe server: %v", callErr)
	}
	if int(serverPID) != pid {
		return fmt.Errorf("the Lantern pipe is answered by an unexpected process (pid %d)", serverPID)
	}
	image := processImages()[serverPID]
	if image == "" || cleanPath(image) != cleanPath(exePath) {
		return fmt.Errorf("the Lantern pipe server is not the daemon this service started")
	}
	return nil
}

func dialRadiancePipe(ctx context.Context) (net.Conn, error) {
	return winio.DialPipeContext(ctx, radiancePipePath)
}
