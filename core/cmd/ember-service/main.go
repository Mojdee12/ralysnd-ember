// ember-service: the Ralysnd Ember Windows service. It owns
// the lifecycle of the app's engine processes and of the
// system TUN session, and serves the app over a named pipe
// (see protocol.go). It is a supervisor, not a monolith:
// engine semantics stay with the app and the engines; this
// binary only starts, stops, watches and reports.
//
// Verbs:
//
//	ember-service            run as a Windows service (or console
//	                         when not under the SCM)
//	ember-service console    run in the foreground (CI / debug)
//	ember-service install    install + start the service (self-elevates)
//	ember-service uninstall  stop + remove the service (self-elevates)
//	ember-service probe      dial the pipe, say hello, print the reply
//	ember-service selftest   probe + a harmless proc lifecycle proof
//	ember-service version    print the build version
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/version"
)

const (
	serviceName = "RalysndEmberService"
	pipePath    = `\\.\pipe\RalysndEmberService.v1`
	displayName = "Ralysnd Ember Service"
)

func main() {
	verb := "serve"
	if len(os.Args) > 1 {
		verb = os.Args[1]
	}
	switch verb {
	case "version":
		fmt.Println(version.Current)
	case "console":
		os.Exit(runConsole())
	case "serve":
		os.Exit(runServiceMain())
	case "install":
		os.Exit(runInstall())
	case "uninstall":
		os.Exit(runUninstall())
	case "probe":
		os.Exit(runProbe(false))
	case "selftest":
		os.Exit(runProbe(true))
	default:
		fmt.Fprintf(os.Stderr, "unknown verb %q\n", verb)
		os.Exit(2)
	}
}

// --- pipe client (probe / selftest) ---

type pipeClient struct {
	conn   net.Conn
	sc     *bufio.Scanner
	nextID int
	events []event
}

func dialService(timeout time.Duration) (*pipeClient, error) {
	conn, err := dialPipe(timeout)
	if err != nil {
		return nil, err
	}
	c := &pipeClient{conn: conn, sc: bufio.NewScanner(conn)}
	c.sc.Buffer(make([]byte, 4096), 1<<20)
	return c, nil
}

// call sends one request and reads frames until its response
// arrives, buffering any events seen along the way.
func (c *pipeClient) call(method string, params interface{}) (json.RawMessage, error) {
	c.nextID++
	id := c.nextID
	var raw json.RawMessage
	if params != nil {
		b, err := json.Marshal(params)
		if err != nil {
			return nil, err
		}
		raw = b
	}
	line, err := encodeLine(request{V: protocolVersion, ID: id, Method: method, Params: raw})
	if err != nil {
		return nil, err
	}
	if _, err := c.conn.Write(line); err != nil {
		return nil, err
	}
	for c.sc.Scan() {
		b := c.sc.Bytes()
		var probe struct {
			ID    int    `json:"id"`
			Event string `json:"event"`
		}
		if err := json.Unmarshal(b, &probe); err != nil {
			continue
		}
		if probe.Event != "" {
			var ev event
			if err := json.Unmarshal(b, &ev); err == nil {
				c.events = append(c.events, ev)
			}
			continue
		}
		if probe.ID != id {
			continue
		}
		var resp response
		if err := json.Unmarshal(b, &resp); err != nil {
			return nil, err
		}
		if !resp.OK {
			return nil, fmt.Errorf("%s: %s", method, resp.Error)
		}
		out, _ := json.Marshal(resp.Result)
		return out, nil
	}
	if err := c.sc.Err(); err != nil {
		return nil, err
	}
	return nil, fmt.Errorf("%s: connection closed", method)
}

// waitEvent scans buffered + incoming events for a proc.exit of
// the named process.
func (c *pipeClient) waitExit(name string, timeout time.Duration) (int, bool) {
	deadline := time.Now().Add(timeout)
	for _, ev := range c.events {
		if ev.Event == "proc.exit" && ev.Data["name"] == name {
			if code, ok := ev.Data["code"].(float64); ok {
				return int(code), true
			}
		}
	}
	_ = c.conn.SetReadDeadline(deadline)
	for c.sc.Scan() {
		var ev event
		if err := json.Unmarshal(c.sc.Bytes(), &ev); err != nil || ev.Event == "" {
			continue
		}
		c.events = append(c.events, ev)
		if ev.Event == "proc.exit" && ev.Data["name"] == name {
			if code, ok := ev.Data["code"].(float64); ok {
				return int(code), true
			}
		}
		if time.Now().After(deadline) {
			break
		}
	}
	return 0, false
}

func appRootOf(exe string) string {
	return filepath.Dir(filepath.Dir(exe))
}

func runProbe(selftest bool) int {
	exe, _ := os.Executable()
	c, err := dialService(5 * time.Second)
	if err != nil {
		fmt.Println("PROBE FAIL: cannot reach the Ember service:", err)
		return 1
	}
	defer c.conn.Close()
	hello, err := c.call("hello", map[string]interface{}{"appRoot": appRootOf(exe)})
	if err != nil {
		fmt.Println("PROBE FAIL:", err)
		return 1
	}
	fmt.Println("HELLO", string(hello))
	if !selftest {
		fmt.Println("PROBE OK")
		return 0
	}
	// Lifecycle proof with a harmless child: the TUN bridge
	// helper with no arguments prints usage and exits with
	// code 2 — spawning it proves start, output streaming,
	// the exit event and the recorded state, end to end.
	bridge := filepath.Join(filepath.Dir(exe), "ember-tun-bridge.exe")
	if _, err := os.Stat(bridge); err != nil {
		// Dev runs on other platforms: any allowlisted sibling
		// works; without one the selftest is only a probe.
		fmt.Println("SELFTEST SKIP: no ember-tun-bridge.exe beside the service")
		return 0
	}
	if _, err := c.call("proc.start", map[string]interface{}{
		"name": "selftest", "exe": bridge,
	}); err != nil {
		fmt.Println("SELFTEST FAIL: proc.start:", err)
		return 1
	}
	code, ok := c.waitExit("selftest", 15*time.Second)
	if !ok {
		fmt.Println("SELFTEST FAIL: no exit event for the bridge helper")
		return 1
	}
	state, err := c.call("proc.state", map[string]interface{}{"name": "selftest"})
	if err != nil {
		fmt.Println("SELFTEST FAIL: proc.state:", err)
		return 1
	}
	fmt.Println("SELFTEST exit code:", code, "state:", string(state))
	if code != 2 {
		fmt.Println("SELFTEST FAIL: expected the bridge usage exit code 2")
		return 1
	}
	fmt.Println("SELFTEST OK")
	return 0
}
