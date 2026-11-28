package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The OpenVPN driver: the service supervises openvpn.exe and
// drives it over OpenVPN's own management interface (the
// community binary's documented local control channel). State
// and byte counters come from the daemon itself — >STATE and
// >BYTECOUNT notifications — which is what fixes the old
// "session bytes unmeasured" gap: the numbers are OpenVPN's
// own, not estimates.
//
// Written from the management interface's public protocol:
// after connecting, the client enables state and bytecount
// notifications ("state on", "bytecount 1"), releases the
// hold, and reads lines; ">PASSWORD:Need 'Auth' username/
// password" asks for credentials, answered with
// username/password commands; "signal SIGTERM" ends the
// session politely.

type ovpnStartParams struct {
	Name       string `json:"name"`
	Exe        string `json:"exe"`
	ConfigPath string `json:"configPath"`
	WorkDir    string `json:"workDir,omitempty"`
}

type ovpnState struct {
	Name      string `json:"name"`
	State     string `json:"state"` // idle|starting|connecting|connected|auth|failed|exited
	Message   string `json:"message,omitempty"`
	Up        int64  `json:"up"`
	Down      int64  `json:"down"`
	SinceMs   int64  `json:"sinceMs,omitempty"`
	Connected bool   `json:"connected"`
}

type ovpnSession struct {
	name     string
	procName string
	conn     net.Conn
	wmu      sync.Mutex
	mu       sync.Mutex
	state    ovpnState
	done     chan struct{}
}

type ovpnManager struct {
	mu       sync.Mutex
	mgr      *manager
	events   *broadcaster
	sessions map[string]*ovpnSession
	// starting holds session names with a start in flight —
	// the same check-then-act guard as manager.start (W4):
	// the session only enters the map after mgr.start
	// returns, so without this a concurrent duplicate start
	// would launch a second daemon.
	starting   map[string]bool
	dial       func(addr string) (net.Conn, error)
	portPicker func() (int, error)
	now        func() time.Time
}

func newOvpnManager(mgr *manager, events *broadcaster) *ovpnManager {
	return &ovpnManager{
		mgr:      mgr,
		events:   events,
		sessions: make(map[string]*ovpnSession),
		starting: make(map[string]bool),
		dial: func(addr string) (net.Conn, error) {
			return net.DialTimeout("tcp", addr, 2*time.Second)
		},
		portPicker: freePort,
		now:        time.Now,
	}
}

// freePort reserves an ephemeral loopback port for one
// session's management channel.
func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// ovpnBlockedDirectives are config directives that must
// never appear in a client-supplied .ovpn the service launches
// (audit B-S4): each either executes code as SYSTEM (plugin,
// up/down and the other script hooks), hijacks the management
// channel this driver depends on (management — the service
// injects its own --management flags after the config, so a
// config-side one is doubly unwanted), or redirects the
// daemon's own state (daemon, log, writepid, status, …).
var ovpnBlockedDirectives = map[string]bool{
	"plugin":                true,
	"up":                    true,
	"down":                  true,
	"client-connect":        true,
	"client-disconnect":     true,
	"script-security":       true,
	"management":            true,
	"learn-address":         true,
	"ipchange":              true,
	"route-up":              true,
	"route-pre-down":        true,
	"tls-verify":            true,
	"auth-user-pass-verify": true,
	"daemon":                true,
	"log":                   true,
	"log-append":            true,
	"writepid":              true,
	"ifconfig-pool-persist": true,
	"status":                true,
}

// checkOvpnConfigText scans config text for blocked
// directives: a directive counts when it appears at the start
// of a line (leading whitespace allowed, case-insensitive) as
// the line's first token. Comment lines (# / ;) and inline
// <block> payloads' contents are still scanned line-wise —
// a blocked word at a payload line start is refused too,
// which is the safe direction for a SYSTEM daemon. The
// refusal names the directive.
func checkOvpnConfigText(text string) error {
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, ";") {
			continue
		}
		token := strings.Fields(trimmed)[0]
		// A directive token may carry its argument glued on
		// with '=' in some writers; compare the bare name.
		if i := strings.IndexByte(token, '='); i >= 0 {
			token = token[:i]
		}
		if ovpnBlockedDirectives[strings.ToLower(token)] {
			return fmt.Errorf("openvpn config refused: the %q directive is not allowed in a service-launched config", strings.ToLower(token))
		}
	}
	return nil
}

// checkOvpnConfigFile sanitises the config file ovpn.start is
// about to hand to openvpn.exe. A file that cannot be read is
// not scanned — the daemon itself will fail loudly on it —
// but a readable file with a blocked directive is refused
// before anything launches.
func checkOvpnConfigFile(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return checkOvpnConfigText(string(b))
}

func (o *ovpnManager) start(p ovpnStartParams) (ovpnState, error) {
	if !nameRe.MatchString(p.Name) {
		return ovpnState{}, fmt.Errorf("bad session name %q", p.Name)
	}
	o.mu.Lock()
	if s, ok := o.sessions[p.Name]; ok && s.state.State != "exited" && s.state.State != "failed" {
		o.mu.Unlock()
		return ovpnState{}, fmt.Errorf("openvpn session %s is already active", p.Name)
	}
	if o.starting == nil {
		o.starting = make(map[string]bool)
	}
	if o.starting[p.Name] {
		o.mu.Unlock()
		return ovpnState{}, fmt.Errorf("start already in progress for %s", p.Name)
	}
	o.starting[p.Name] = true
	o.mu.Unlock()
	defer func() {
		o.mu.Lock()
		delete(o.starting, p.Name)
		o.mu.Unlock()
	}()

	// Sanitise before anything launches (audit B-S4): a
	// config carrying script hooks or its own management
	// directive never reaches openvpn.exe.
	if err := checkOvpnConfigFile(p.ConfigPath); err != nil {
		return ovpnState{}, err
	}

	port, err := o.portPicker()
	if err != nil {
		return ovpnState{}, err
	}
	procName := "ovpn-" + p.Name
	args := []string{
		"--config", p.ConfigPath,
		"--management", "127.0.0.1", strconv.Itoa(port),
		"--management-hold",
		"--connect-retry-max", "1",
	}
	if _, err := o.mgr.start(procSpec{
		Name: procName, Exe: p.Exe, Args: args, WorkDir: p.WorkDir, Stdin: true,
	}); err != nil {
		return ovpnState{}, err
	}
	s := &ovpnSession{
		name:     p.Name,
		procName: procName,
		state:    ovpnState{Name: p.Name, State: "starting", SinceMs: o.now().UnixMilli()},
		done:     make(chan struct{}),
	}
	o.mu.Lock()
	o.sessions[p.Name] = s
	o.mu.Unlock()
	o.publish(s)

	go o.attach(s, port)
	return s.snapshot(), nil
}

// attach dials the management channel (the daemon opens it
// during start-up; retry briefly), enables notifications and
// releases the hold so the connection proceeds.
func (o *ovpnManager) attach(s *ovpnSession, port int) {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		conn, err = o.dial(addr)
		if err == nil {
			break
		}
		select {
		case <-s.done:
			return
		case <-time.After(200 * time.Millisecond):
		}
	}
	if err != nil {
		o.setState(s, "failed", "the management channel never opened")
		return
	}
	s.conn = conn
	_ = s.send("state on")
	_ = s.send("bytecount 1")
	_ = s.send("hold release")
	o.setState(s, "connecting", "")
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 64*1024)
	for sc.Scan() {
		o.onLine(s, sc.Text())
	}
	// The channel closing means the daemon exited or was
	// stopped; reconcile with the process record.
	if ps := o.mgr.state(s.procName); !ps.Running {
		o.setState(s, "exited", s.snapshot().Message)
	}
	closeOnce(s)
}

func (s *ovpnSession) send(line string) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if s.conn == nil {
		return fmt.Errorf("management channel is not open")
	}
	_, err := s.conn.Write([]byte(line + "\r\n"))
	return err
}

func (o *ovpnManager) onLine(s *ovpnSession, line string) {
	switch {
	case strings.HasPrefix(line, ">STATE:"):
		// >STATE:<unix>,<STATE>,<desc>,<localIP>,<remoteIP>,...
		parts := strings.SplitN(strings.TrimPrefix(line, ">STATE:"), ",", 4)
		if len(parts) >= 2 {
			switch parts[1] {
			case "CONNECTED":
				msg := ""
				if len(parts) >= 3 {
					msg = parts[2]
				}
				o.setState(s, "connected", msg)
				s.muSet(func(st *ovpnState) { st.Connected = true })
			case "AUTH":
				o.setState(s, "auth", "waiting for credentials")
			case "RECONNECTING":
				o.setState(s, "connecting", "reconnecting")
			case "EXITING":
				o.setState(s, "exited", "")
			default:
				o.setState(s, "connecting", strings.ToLower(parts[1]))
			}
		}
	case strings.HasPrefix(line, ">BYTECOUNT:"):
		parts := strings.Split(strings.TrimPrefix(line, ">BYTECOUNT:"), ",")
		if len(parts) == 2 {
			down, _ := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
			up, _ := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
			s.muSet(func(st *ovpnState) { st.Down, st.Up = down, up })
			o.publish(s)
		}
	case strings.HasPrefix(line, ">PASSWORD:"):
		if strings.Contains(line, "Need 'Auth'") {
			o.setState(s, "auth", "the server asks for a username and password")
		} else if strings.Contains(line, "Verification Failed") {
			o.setState(s, "failed", "the server refused the credentials")
		}
	case strings.HasPrefix(line, ">FATAL:"):
		o.setState(s, "failed", strings.TrimSpace(strings.TrimPrefix(line, ">FATAL:")))
	}
}

func (s *ovpnSession) muSet(f func(*ovpnState)) {
	s.mu.Lock()
	f(&s.state)
	s.mu.Unlock()
}

func (o *ovpnManager) setState(s *ovpnSession, state, msg string) {
	s.muSet(func(st *ovpnState) {
		st.State = state
		if msg != "" || state != "connected" {
			st.Message = msg
		}
		if state == "connected" && st.SinceMs == 0 {
			st.SinceMs = o.now().UnixMilli()
		}
	})
	o.publish(s)
}

func (o *ovpnManager) publish(s *ovpnSession) {
	st := s.snapshot()
	o.events.emit(event{V: protocolVersion, Event: "ovpn.state", Data: map[string]interface{}{
		"name": st.Name, "state": st.State, "message": st.Message,
		"up": st.Up, "down": st.Down, "connected": st.Connected,
	}})
}

func (s *ovpnSession) snapshot() ovpnState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

func (o *ovpnManager) states() []ovpnState {
	o.mu.Lock()
	defer o.mu.Unlock()
	out := make([]ovpnState, 0, len(o.sessions))
	for _, s := range o.sessions {
		out = append(out, s.snapshot())
	}
	return out
}

func (o *ovpnManager) state(name string) ovpnState {
	o.mu.Lock()
	s, ok := o.sessions[name]
	o.mu.Unlock()
	if !ok {
		return ovpnState{Name: name, State: "idle"}
	}
	return s.snapshot()
}

// mgmtQuote quotes one value for the OpenVPN management
// interface (audit C6). The management protocol's quoting is
// NOT Go's %q: the value is wrapped in double quotes, a
// backslash is escaped as \\ and a double quote as \"; every
// other byte — non-ASCII included — passes through as-is
// (UTF-8). Go's %q would emit \u / \x escapes the daemon
// does not understand, mangling exactly the passwords that
// contain quotes, backslashes or non-ASCII characters.
// CR/LF are NOT quotable (the protocol is line-delimited):
// auth refuses such credentials before quoting — see
// mgmtValueSafe (review W9).
func mgmtQuote(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// ovpnAuthCommands builds the two management lines that
// answer an 'Auth' password request.
func ovpnAuthCommands(username, password string) [2]string {
	return [2]string{
		"username \"Auth\" " + mgmtQuote(username),
		"password \"Auth\" " + mgmtQuote(password),
	}
}

// mgmtValueSafe reports whether a credential may be placed
// on the management channel at all. The protocol is
// line-delimited, so CR/LF in a username or password would
// inject whole extra management commands into the session
// (review W9) — quoting cannot save a line break, so such
// credentials are refused outright.
func mgmtValueSafe(s string) bool {
	return !strings.ContainsAny(s, "\r\n")
}

// auth answers an 'Auth' password request.
func (o *ovpnManager) auth(name, username, password string) error {
	if !mgmtValueSafe(username) || !mgmtValueSafe(password) {
		return fmt.Errorf("openvpn credentials must not contain CR or LF characters")
	}
	o.mu.Lock()
	s, ok := o.sessions[name]
	o.mu.Unlock()
	if !ok {
		return fmt.Errorf("no openvpn session %s", name)
	}
	cmds := ovpnAuthCommands(username, password)
	if err := s.send(cmds[0]); err != nil {
		return err
	}
	return s.send(cmds[1])
}

func (o *ovpnManager) stop(name string) (ovpnState, error) {
	o.mu.Lock()
	s, ok := o.sessions[name]
	o.mu.Unlock()
	if !ok {
		return ovpnState{Name: name, State: "idle"}, fmt.Errorf("no openvpn session %s", name)
	}
	_ = s.send("signal SIGTERM")
	if s.conn != nil {
		s.conn.Close()
	}
	closeOnce(s)
	if _, err := o.mgr.stop(s.procName); err != nil {
		return ovpnState{}, err
	}
	o.setState(s, "exited", "")
	return s.snapshot(), nil
}

func closeOnce(s *ovpnSession) {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
}
