//go:build !windows

package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"time"
)

// Off Windows the service serves the same protocol on a
// loopback TCP port so the contract, the managers and the
// tests can be exercised anywhere (this is also how the unit
// tests and the Linux CI checks run it).

const devAddr = "127.0.0.1:47832"

func listenDev() (net.Listener, error) {
	return net.Listen("tcp", devAddr)
}

func dialPipe(timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("tcp", devAddr, timeout)
}

func runConsole() int {
	roots := loadRoots()
	srv := newServer(roots)
	ln, err := listenDev()
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		return 1
	}
	fmt.Println("ember-service console (dev) on", devAddr)
	sig := make(chan os.Signal, 2)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		ln.Close()
		srv.shutdown()
		os.Exit(0)
	}()
	_ = srv.serve(ln)
	return 0
}

func runServiceMain() int { return runConsole() }
