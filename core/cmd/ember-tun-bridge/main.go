// Command ember-tun-bridge holds a TUN session with the installed
// TUN service (cmd/firefox-vpn-tun, protocol internal/tunapi) that
// forwards the whole system's traffic to a local SOCKS5 proxy owned
// by one of the app's other engine processes (xray.exe in TUN mode,
// psiphon-core.exe in Psiphon VPN mode). It is the Windows
// counterpart of what the Android engines get from their VpnService
// plus tun2socks: the service's own stack (core/internal/tunstack)
// terminates the TUN and dials out through the given proxy, exactly
// as it does for the core's own TUN mode (internal/desktop/tun.go) —
// the only difference is whose SOCKS proxy the session points at.
//
// The app spawns this helper when an engine enters TUN mode and
// keeps its stdin open; the helper holds the session for exactly as
// long as it runs. When stdin closes (the app exits, gracefully or
// not — a dead parent's pipe closes with it), or when the helper is
// interrupted, it closes the session politely and exits; if the
// helper dies any other way, the service notices the dropped pipe
// and takes the TUN down by itself, so no state can leak.
//
// The proxy's own process must not be routed into its own tunnel:
// -skip names the executables the service sends directly, outside
// the TUN (the tunapi programs mechanism, protocol 2). For Xray that
// is xray.exe itself; for Psiphon, psiphon-core.exe.
//
// Stdout is a tiny line protocol for the parent: "UP <adapter>"
// once the TUN is routed, "DOWN <reason>" when it ends by itself,
// "ERROR <code> <message>" when the start failed. Diagnostics go to
// stderr. Exit code 0 is a clean end (stdin closed, or DOWN after a
// running session); 1 is a failed start.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/tunapi"
	"github.com/armanlife/firefox-vpn-client/core/internal/version"
)

// replyTimeout bounds a service reply; creating the adapter can take
// a few seconds (internal/desktop uses the same 30 s).
const replyTimeout = 30 * time.Second

func main() {
	proxy := flag.String("proxy", "", "the SOCKS5 proxy the TUN forwards to (host:port)")
	var skips stringList
	flag.Var(&skips, "skip", "an executable file name the service sends outside the TUN (repeatable)")
	flag.Parse()
	if *proxy == "" {
		fmt.Fprintln(os.Stderr, "usage: ember-tun-bridge -proxy host:port [-skip exe.exe ...]")
		os.Exit(2)
	}
	os.Exit(run(*proxy, []string(skips)))
}

type stringList []string

func (s *stringList) String() string { return fmt.Sprint([]string(*s)) }
func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func run(proxy string, skips []string) int {
	if err := ensureService(); err != nil {
		fmt.Printf("ERROR service-missing %s\n", err)
		return 1
	}
	conn, err := hello()
	if err != nil {
		fmt.Printf("ERROR %s\n", errText(err))
		return 1
	}

	programs := make([]tunapi.Program, 0, len(skips))
	for _, name := range skips {
		programs = append(programs, tunapi.Program{Name: name})
	}
	reply, err := ask(conn, tunapi.Message{
		Type: tunapi.TypeOpen, Proxy: proxy, Programs: programs,
	})
	if err == nil && (reply.Type != tunapi.TypeOpened || reply.Interface == nil) {
		err = fmt.Errorf("unexpected reply %q", reply.Type)
	}
	if err != nil {
		conn.Close()
		fmt.Printf("ERROR %s\n", errText(err))
		return 1
	}
	iface := reply.Interface
	if reply, err = ask(conn, tunapi.Message{Type: tunapi.TypeRoute}); err == nil && reply.Type != tunapi.TypeRouted {
		err = fmt.Errorf("unexpected reply %q", reply.Type)
	}
	if err != nil {
		// The service took the adapter down with the failed route.
		conn.Close()
		fmt.Printf("ERROR route-failed %s\n", errText(err))
		return 1
	}
	fmt.Printf("UP %s\n", iface.Name)

	// Hold the session until stdin closes (the parent is gone or
	// stopping us), the service ends it, or we are interrupted.
	events := make(chan tunapi.Message, 4)
	connDone := make(chan error, 1)
	go func() {
		for {
			m, err := conn.Receive()
			if err != nil {
				connDone <- err
				return
			}
			events <- m
		}
	}()
	stdinDone := make(chan struct{})
	go func() {
		buf := make([]byte, 256)
		for {
			if _, err := os.Stdin.Read(buf); err != nil {
				close(stdinDone)
				return
			}
		}
	}()
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)

hold:
	for {
		select {
		case <-stdinDone:
			break hold
		case <-interrupt:
			break hold
		case err := <-connDone:
			fmt.Printf("DOWN %s\n", errText(err))
			return 0
		case m := <-events:
			if m.Type == tunapi.TypeFailed {
				fmt.Printf("DOWN %s\n", m.Message)
				conn.Close()
				return 0
			}
			// Anything else (udp_refused, programs_set, ...) needs
			// no answer; keep holding.
		}
	}

	// Polite close, as internal/desktop's stop does.
	_ = conn.Raw().SetWriteDeadline(time.Now().Add(5 * time.Second))
	if conn.Send(tunapi.Message{Type: tunapi.TypeClose}) == nil {
		deadline := time.After(10 * time.Second)
	wait:
		for {
			select {
			case m, ok := <-events:
				if !ok || m.Type == tunapi.TypeClosed {
					break wait
				}
			case <-connDone:
				break wait
			case <-deadline:
				break wait
			}
		}
	}
	conn.Close()
	fmt.Println("DOWN closed")
	return 0
}

// ensureService makes sure the TUN service is installed, installing
// it from the copy beside this helper when it is not — the same
// thing Setup does, and what the app does the first time TUN mode is
// chosen (the installer's own administrator prompt appears). A
// service installed for another user is reported, not fought.
func ensureService() error {
	installed, err := tunapi.Installed()
	if err == nil && installed {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	tunExe := filepath.Join(filepath.Dir(exe), tunapi.ExeName)
	if _, err := os.Stat(tunExe); err != nil {
		return errors.New("the TUN service is not installed and no installer copy is beside the bridge")
	}
	cmd := exec.Command(tunExe, "install")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stderr, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("installing the TUN service: %w", err)
	}
	// The service needs a moment to come up.
	deadline := time.Now().Add(15 * time.Second)
	for {
		if installed, err := tunapi.Installed(); err == nil && installed {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("the TUN service did not come up after installing")
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// hello dials the service and exchanges hellos, updating an older
// service from the copy beside this helper first when it speaks an
// overlapping protocol — internal/desktop's connect, reduced to one
// update attempt. The returned connection is ready for open.
func hello() (*tunapi.Conn, error) {
	for attempt := 0; ; attempt++ {
		conn, peer, err := dialHello()
		if err != nil {
			return nil, err
		}
		incompatible := peer.Type == tunapi.TypeError
		if incompatible && peer.MinProtocol > tunapi.Protocol {
			conn.Close()
			return nil, fmt.Errorf("app-outdated the TUN service %s is newer than this app %s", peer.Version, version.Current)
		}
		older := incompatible || version.Newer(version.Current, peer.Version)
		if !older || attempt > 0 {
			if incompatible {
				conn.Close()
				return nil, fmt.Errorf("service-outdated the TUN service %s is older than this app %s and speaks no common protocol", peer.Version, version.Current)
			}
			return conn, nil
		}
		// Older but overlapping (or incompatible-but-maybe-fixable):
		// ask it to update from the bundled copy, then redial. A
		// refused update is fine while a common protocol exists.
		exe, _ := os.Executable()
		bundled := filepath.Join(filepath.Dir(exe), tunapi.ExeName)
		reply, uerr := ask(conn, tunapi.Message{Type: tunapi.TypeUpdate, Path: bundled})
		if uerr == nil && reply.Type != tunapi.TypeUpdating {
			uerr = fmt.Errorf("unexpected reply %q", reply.Type)
		}
		conn.Close()
		if uerr != nil {
			if incompatible {
				return nil, fmt.Errorf("service-outdated the TUN service %s did not update: %w", peer.Version, uerr)
			}
			// It still speaks this build's protocol; start over on a
			// fresh connection and proceed without the update.
			conn2, _, err2 := dialHello()
			if err2 != nil {
				return nil, err2
			}
			return conn2, nil
		}
		if err := waitForService(); err != nil {
			return nil, err
		}
	}
}

// dialHello connects and says hello; a protocol refusal comes back
// as the peer message (Type TypeError with the peer's range), as in
// internal/desktop's dialHello.
func dialHello() (*tunapi.Conn, tunapi.Message, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	raw, err := tunapi.Dial(ctx)
	cancel()
	if err != nil {
		return nil, tunapi.Message{}, err
	}
	conn := tunapi.NewConn(raw)
	reply, err := ask(conn, tunapi.Hello(version.Current))
	var e *tunapi.Error
	if errors.As(err, &e) && e.Code == tunapi.CodeProtocol {
		return conn, tunapi.Message{
			Type: tunapi.TypeError, Code: e.Code,
			Protocol: e.Protocol, MinProtocol: e.MinProtocol, Version: e.Version,
		}, nil
	}
	if err == nil && reply.Type != tunapi.TypeHello {
		err = fmt.Errorf("unexpected reply %q", reply.Type)
	}
	if err != nil {
		conn.Close()
		return nil, tunapi.Message{}, err
	}
	return conn, reply, nil
}

// waitForService waits for an updated service to answer again.
func waitForService() error {
	deadline := time.Now().Add(30 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		raw, err := tunapi.Dial(ctx)
		cancel()
		if err == nil {
			raw.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("the TUN service did not come back after updating: %w", err)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// ask sends m and returns the reply, as an error when it is one.
func ask(conn *tunapi.Conn, m tunapi.Message) (tunapi.Message, error) {
	_ = conn.Raw().SetDeadline(time.Now().Add(replyTimeout))
	defer conn.Raw().SetDeadline(time.Time{})
	if err := conn.Send(m); err != nil {
		return tunapi.Message{}, err
	}
	reply, err := conn.Receive()
	if err != nil {
		return tunapi.Message{}, err
	}
	if err := tunapi.AsError(reply); err != nil {
		return reply, err
	}
	return reply, nil
}

// errText renders an error for the ERROR/DOWN line: a tunapi error
// keeps its code, so the parent can log (or localize) the cause.
func errText(err error) string {
	var e *tunapi.Error
	if errors.As(err, &e) {
		if e.Message != "" {
			return e.Code + " " + e.Message
		}
		return e.Code
	}
	return err.Error()
}
