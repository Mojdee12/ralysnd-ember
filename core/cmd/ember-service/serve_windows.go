//go:build windows

package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

// listenPipe opens the service's named pipe. The security
// descriptor grants SYSTEM and Administrators full access and
// INTERACTIVE (S-1-5-4) read/write: whichever user is
// interactively logged on can CONNECT to the pipe, while
// non-interactive accounts (services, scheduled tasks, other
// sessions' leftovers) cannot.
//
// INTERACTIVE is only a pre-filter, NOT the security
// boundary (2042 adversarial review C2): on a multi-user PC
// every interactive account passes it. The boundary is the
// owner-SID binding in ownerBoundListener below — when the
// installer has recorded an owner SID in service.json, a
// connection is served only if the connecting client's own
// SID matches it. (App roots are likewise install-bound:
// server.go hello, audit B-S1.)
//
// This replaces the old shape (2041 audit B-S2), which bound
// the ACE once, at listen time, to whoever the console user
// happened to be then — locking the app out after a user
// switch — and fell back to BUILTIN\Users (every local
// account) when no console user resolved at boot.
func listenPipe() (net.Listener, error) {
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;S-1-5-4)"
	ln, err := winio.ListenPipe(pipePath, &winio.PipeConfig{
		SecurityDescriptor: sddl,
		InputBufferSize:    64 * 1024,
		OutputBufferSize:   64 * 1024,
	})
	if err != nil {
		return nil, err
	}
	return ownerBoundListener{Listener: ln}, nil
}

// ownerBoundListener enforces the owner-SID binding (review
// C2, service half) on every accepted pipe connection. The
// recorded SID is read from service.json per connection, so
// an install that records it while the service is already
// running takes effect without a restart. No recorded SID
// (dev/console/portable runs) disables the check and every
// connection is allowed.
type ownerBoundListener struct {
	net.Listener
}

func (l ownerBoundListener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		recorded := loadOwnerSID()
		if recorded == "" {
			return conn, nil
		}
		sid, err := pipeClientSID(conn)
		if err != nil {
			log.Printf("ember-service: cannot identify pipe client, refusing connection: %v", err)
			conn.Close()
			continue
		}
		if !ownerSIDAllows(recorded, sid) {
			log.Printf("ember-service: refused pipe connection from SID %s (install owner is %s)", sid, recorded)
			conn.Close()
			continue
		}
		return conn, nil
	}
}

var procImpersonateNamedPipeClient = kernel32.NewProc("ImpersonateNamedPipeClient")

// pipeClientSID identifies the user on the other end of one
// pipe connection: impersonate the client on this (locked)
// thread, read the impersonation token's user SID, revert.
// The handle comes from the winio connection's Fd.
func pipeClientSID(conn net.Conn) (string, error) {
	fder, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return "", fmt.Errorf("pipe connection does not expose a handle")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	r, _, callErr := procImpersonateNamedPipeClient.Call(fder.Fd())
	if r == 0 {
		return "", fmt.Errorf("impersonate the pipe client: %v", callErr)
	}
	defer func() { _ = windows.RevertToSelf() }()
	thread, err := windows.GetCurrentThread()
	if err != nil {
		return "", fmt.Errorf("current thread: %w", err)
	}
	var tok windows.Token
	if err := windows.OpenThreadToken(thread, windows.TOKEN_QUERY, true, &tok); err != nil {
		return "", fmt.Errorf("open the client token: %w", err)
	}
	defer tok.Close()
	user, err := tok.GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("read the client token user: %w", err)
	}
	return user.User.Sid.String(), nil
}

func dialPipe(timeout time.Duration) (net.Conn, error) {
	return winio.DialPipe(pipePath, &timeout)
}

func runConsole() int {
	roots := loadRoots()
	srv := newServer(roots)
	reapOrphans(roots)
	ln, err := listenPipe()
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		return 1
	}
	fmt.Println("ember-service console on", pipePath)
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

type svcHandler struct{ srv *server }

func (h *svcHandler) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}
	roots := loadRoots()
	reapOrphans(roots)
	ln, err := listenPipe()
	if err != nil {
		return false, 1
	}
	go h.srv.serve(ln)
	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		c := <-r
		switch c.Cmd {
		case svc.Interrogate:
			s <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			s <- svc.Status{State: svc.StopPending}
			ln.Close()
			h.srv.shutdown()
			return false, 0
		}
	}
}

func runServiceMain() int {
	isSvc, err := svc.IsWindowsService()
	if err != nil || !isSvc {
		// Launched by hand (or by the installer for a smoke
		// run): behave like console mode.
		return runConsole()
	}
	srv := newServer(loadRoots())
	if err := svc.Run(serviceName, &svcHandler{srv: srv}); err != nil {
		return 1
	}
	return 0
}
