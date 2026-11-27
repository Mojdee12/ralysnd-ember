package main

import (
	"bufio"
	"fmt"
	"net"
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
	mu         sync.Mutex
	mgr        *manager
	events     *broadcaster
	sessions   map[string]*ovpnSession
	dial       func(addr string) (net.Conn, error)
	portPicker func() (int, error)
	now        func() time.Time
}

func newOvpnManager(mgr *manager, events *broadcaster) *ovpnManager {
	return &ovpnManager{
		mgr:      mgr,
		events:   events,
		sessions: make(map[string]*ovpnSession),
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

func (o *ovpnManager) start(p ovpnStartParams) (ovpnState, error) {
	if !nameRe.MatchString(p.Name) {
		return ovpnState{}, fmt.Errorf("bad session name %q", p.Name)
	}
	o.mu.Lock()
	if s, ok := o.sessions[p.Name]; ok && s.state.State != "exited" && s.state.State != "failed" {
		o.mu.Unlock()
		return ovpnState{}, fmt.Errorf("openvpn session %s is already active", p.Name)
	}
	o.mu.Unlock()

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

// auth answers an 'Auth' password request.
func (o *ovpnManager) auth(name, username, password string) error {
	o.mu.Lock()
	s, ok := o.sessions[name]
	o.mu.Unlock()
	if !ok {
		return fmt.Errorf("no openvpn session %s", name)
	}
	if err := s.send(fmt.Sprintf("username \"Auth\" %q", username)); err != nil {
		return err
	}
	return s.send(fmt.Sprintf("password \"Auth\" %q", password))
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
