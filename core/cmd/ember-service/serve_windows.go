//go:build windows

package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

// listenPipe opens the service's named pipe. The security
// descriptor grants SYSTEM and Administrators full access and
// the console session's user read/write — the app runs as that
// user. When no console user can be resolved (headless CI),
// BUILTIN\Users is granted instead so the smoke test can dial.
func listenPipe() (net.Listener, error) {
	userACE := "(A;;GRGW;;;BU)"
	if sid := consoleUserSID(); sid != "" {
		userACE = "(A;;GRGW;;;" + sid + ")"
	}
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)" + userACE
	return winio.ListenPipe(pipePath, &winio.PipeConfig{
		SecurityDescriptor: sddl,
		InputBufferSize:    64 * 1024,
		OutputBufferSize:   64 * 1024,
	})
}

func consoleUserSID() string {
	session := windows.WTSGetActiveConsoleSessionId()
	if session == 0xFFFFFFFF {
		return ""
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(session, &token); err != nil {
		return ""
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return ""
	}
	return user.User.Sid.String()
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
