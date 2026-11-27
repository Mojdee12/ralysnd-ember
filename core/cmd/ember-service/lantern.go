package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

// The Lantern driver: the service supervises the radiance
// daemon (full-VPN build — radiance owns its own TUN) and is
// the ONLY caller of the daemon's named-pipe API. Two guards,
// both implemented here:
//
//  1. An endpoint allowlist: the shell can reach exactly the
//     six calls the engine page needs — nothing else the
//     daemon exposes is reachable through this service.
//  2. Pipe-server authentication before the first call of a
//     daemon run: the process answering on the daemon's pipe
//     must be the very lanternd this service started (PID
//     match) running the very image we launched (path match).
//     A stranger process squatting on the pipe name is
//     refused, plainly.
//
// The daemon's API itself is radiance's upstream contract:
// plain HTTP (a Go http.Server + ServeMux) over the named
// pipe — net/http with a pipe dial is the whole client.

var lanternAllowlist = map[string]bool{
	"GET /vpn/status":       true,
	"POST /vpn/connect":     true,
	"POST /vpn/disconnect":  true,
	"GET /server/selected":  true,
	"POST /server/selected": true,
	"GET /servers":          true,
}

// radiancePipePath is where the daemon listens — hard-coded
// in radiance's own ipc package (ipc/conn_windows.go), not
// configurable. The pipe NAME being upstream's is exactly why
// the PID + image authentication above is load-bearing: any
// process could squat the name; only ours may answer.
var radiancePipePath = `\\.\pipe\Lantern\lantern`

const lanternProcName = "lanternd"

type lanternStartParams struct {
	Exe     string            `json:"exe"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	WorkDir string            `json:"workDir,omitempty"`
}

type lanternCallParams struct {
	Method string          `json:"method"`
	Path   string          `json:"path"`
	Body   json.RawMessage `json:"body,omitempty"`
}

type lanternCallResult struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body,omitempty"`
}

type lanternManager struct {
	mgr          *manager
	mu           sync.Mutex
	client       *http.Client
	authedPID    int
	exePath      string
	authenticate func(pid int, exePath string) error
	dial         func(ctx context.Context) (net.Conn, error)
}

func newLanternManager(mgr *manager) *lanternManager {
	return &lanternManager{
		mgr:          mgr,
		authenticate: authenticateRadiancePipe,
		dial:         dialRadiancePipe,
	}
}

func (l *lanternManager) start(p lanternStartParams) (procState, error) {
	// _LANTERND_CHILD=1 makes `lanternd run` BE the daemon in
	// this process (no self-babysitter respawn): the service
	// owns the lifecycle, and the daemon exits when its stdin
	// closes — which is the manager's polite-stop path.
	env := map[string]string{"_LANTERND_CHILD": "1"}
	for k, v := range p.Env {
		env[k] = v
	}
	st, err := l.mgr.start(procSpec{
		Name: lanternProcName, Exe: p.Exe, Args: p.Args,
		Env: env, WorkDir: p.WorkDir, Stdin: true,
	})
	if err != nil {
		return procState{}, err
	}
	l.mu.Lock()
	l.authedPID = 0
	l.client = nil
	l.exePath = p.Exe
	l.mu.Unlock()
	return st, nil
}

func (l *lanternManager) stop() (procState, error) {
	l.mu.Lock()
	l.authedPID = 0
	l.client = nil
	l.mu.Unlock()
	return l.mgr.stop(lanternProcName)
}

func (l *lanternManager) state() procState { return l.mgr.state(lanternProcName) }

// httpClient returns the shared pipe client, building it
// after authenticating the pipe server for this daemon run.
func (l *lanternManager) httpClient() (*http.Client, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	st := l.mgr.state(lanternProcName)
	if !st.Running {
		return nil, fmt.Errorf("the Lantern daemon is not running")
	}
	if l.client != nil && l.authedPID == st.PID {
		return l.client, nil
	}
	if err := l.authenticate(st.PID, l.exePath); err != nil {
		return nil, err
	}
	dial := l.dial
	l.client = &http.Client{
		Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dial(ctx)
			},
		},
	}
	l.authedPID = st.PID
	return l.client, nil
}

// call proxies one allow-listed request to the daemon and
// returns its status + JSON body verbatim.
func (l *lanternManager) call(p lanternCallParams) (*lanternCallResult, error) {
	if !lanternAllowlist[p.Method+" "+p.Path] {
		return nil, fmt.Errorf("%s %s is not an allowed Lantern call", p.Method, p.Path)
	}
	client, err := l.httpClient()
	if err != nil {
		return nil, err
	}
	timeout := 20 * time.Second
	if p.Path == "/vpn/connect" {
		timeout = 70 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var body io.Reader
	if len(p.Body) > 0 {
		body = bytes.NewReader(p.Body)
	}
	req, err := http.NewRequestWithContext(ctx, p.Method, "http://lantern"+p.Path, body)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("the Lantern daemon did not answer: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	out := &lanternCallResult{Status: resp.StatusCode}
	if len(raw) > 0 {
		out.Body = json.RawMessage(raw)
	}
	return out, nil
}
