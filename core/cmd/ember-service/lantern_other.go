//go:build !windows

package main

import (
	"context"
	"fmt"
	"net"
)

// The daemon's pipe is a Windows facility; off Windows the
// Lantern calls refuse plainly (the unit tests stub these).

func authenticateRadiancePipe(pid int, exePath string) error {
	return fmt.Errorf("the Lantern pipe exists only on Windows")
}

func dialRadiancePipe(ctx context.Context) (net.Conn, error) {
	return nil, fmt.Errorf("the Lantern pipe exists only on Windows")
}
