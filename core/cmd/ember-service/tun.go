package main

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The TUN session manager: owns the system's capture session
// for whichever engine is up. A session is the bundled
// ember-tun-bridge helper (which holds a session with the TUN
// service and forwards the system to the engine's SOCKS proxy);
// the helper's stdout line protocol — "UP <adapter> index=<i>
// ...", "DOWN <reason>", "ERROR <code> <message>" — is the
// session's own confirmation, and this manager turns it into
// plain state plus the adapter's real byte counters.

type tunStartParams struct {
	Name      string   `json:"name"` // the session's owner label, e.g. "lantern"
	Exe       string   `json:"exe"`  // ember-tun-bridge.exe path
	SocksPort int      `json:"socksPort"`
	Skip      []string `json:"skip,omitempty"` // engine exes kept outside the TUN
}

type tunState struct {
	Name     string `json:"name"`
	State    string `json:"state"` // idle | starting | up | down | failed
	Adapter  string `json:"adapter,omitempty"`
	Message  string `json:"message,omitempty"`
	SinceMs  int64  `json:"sinceMs,omitempty"`
	Up       int64  `json:"up"`
	Down     int64  `json:"down"`
	Counters bool   `json:"counters"` // Up/Down are the adapter's own counters
}

type tunManager struct {
	mu        sync.Mutex
	mgr       *manager
	events    *broadcaster
	cur       tunState
	procName  string
	ifIndex   uint32
	baseUp    uint64
	baseDown  uint64
	haveBase  bool
	now       func() time.Time
}

func newTunManager(mgr *manager, events *broadcaster) *tunManager {
	t := &tunManager{
		mgr:    mgr,
		events: events,
		cur:    tunState{State: "idle"},
		now:    time.Now,
	}
	mgr.addLineHook(t.onLine)
	return t
}

func (t *tunManager) procLabel(session string) string { return "tun-" + session }

func (t *tunManager) start(p tunStartParams) (tunState, error) {
	if !nameRe.MatchString(p.Name) {
		return tunState{}, fmt.Errorf("bad session name %q", p.Name)
	}
	if p.SocksPort <= 0 || p.SocksPort > 65535 {
		return tunState{}, fmt.Errorf("bad socks port %d", p.SocksPort)
	}
	t.mu.Lock()
	if t.cur.State == "starting" || t.cur.State == "up" {
		owner := t.cur.Name
		t.mu.Unlock()
		return tunState{}, fmt.Errorf("the TUN is already held by %s", owner)
	}
	t.mu.Unlock()

	args := []string{"-proxy", fmt.Sprintf("127.0.0.1:%d", p.SocksPort)}
	for _, s := range p.Skip {
		args = append(args, "-skip", s)
	}
	procName := t.procLabel(p.Name)
	if _, err := t.mgr.start(procSpec{
		Name:  procName,
		Exe:   p.Exe,
		Args:  args,
		Stdin: true, // the bridge holds its session while stdin stays open
	}); err != nil {
		return tunState{}, err
	}
	t.mu.Lock()
	t.cur = tunState{Name: p.Name, State: "starting", SinceMs: t.now().UnixMilli()}
	t.procName = procName
	t.haveBase = false
	t.ifIndex = 0
	st := t.cur
	t.mu.Unlock()
	t.publish()
	return st, nil
}

func (t *tunManager) stop() (tunState, error) {
	t.mu.Lock()
	procName := t.procName
	active := t.cur.State == "starting" || t.cur.State == "up"
	t.mu.Unlock()
	if !active || procName == "" {
		return t.state(), nil
	}
	if _, err := t.mgr.stop(procName); err != nil {
		return tunState{}, err
	}
	t.mu.Lock()
	t.cur = tunState{State: "idle"}
	t.procName = ""
	t.mu.Unlock()
	t.publish()
	return t.state(), nil
}

func (t *tunManager) state() tunState {
	// Reconcile with the helper's own record first: a bridge
	// that died on its own must never leave a stale "up".
	t.mu.Lock()
	if (t.cur.State == "starting" || t.cur.State == "up") && t.procName != "" {
		if ps := t.mgr.state(t.procName); !ps.Running && ps.Exited {
			t.cur.State = "down"
			if t.cur.Message == "" {
				t.cur.Message = "the TUN bridge stopped"
			}
		}
	}
	st := t.cur
	idx, haveBase, bU, bD := t.ifIndex, t.haveBase, t.baseUp, t.baseDown
	t.mu.Unlock()
	if st.State == "up" && haveBase {
		if up, down, ok := adapterBytes(idx); ok {
			st.Up = int64(up - bU)
			st.Down = int64(down - bD)
			st.Counters = true
		}
	}
	return st
}

// onLine parses the bridge helper's stdout protocol for the
// session this manager started.
func (t *tunManager) onLine(name, stream, line string) {
	if stream != "stdout" {
		return
	}
	t.mu.Lock()
	if name != t.procName {
		t.mu.Unlock()
		return
	}
	changed := false
	switch {
	case strings.HasPrefix(line, "UP "):
		// UP <adapter> index=<i> luid=<l> proxy=<addr> ...
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			t.cur.Adapter = fields[1]
		}
		for _, f := range fields[2:] {
			if v, ok := strings.CutPrefix(f, "index="); ok {
				if n, err := strconv.ParseUint(v, 10, 32); err == nil {
					t.ifIndex = uint32(n)
				}
			}
		}
		t.cur.State = "up"
		t.cur.Message = ""
		t.cur.SinceMs = t.now().UnixMilli()
		if up, down, ok := adapterBytes(t.ifIndex); ok {
			t.baseUp, t.baseDown, t.haveBase = up, down, true
		}
		changed = true
	case strings.HasPrefix(line, "DOWN"):
		t.cur.State = "down"
		t.cur.Message = strings.TrimSpace(strings.TrimPrefix(line, "DOWN"))
		changed = true
	case strings.HasPrefix(line, "ERROR"):
		t.cur.State = "failed"
		t.cur.Message = strings.TrimSpace(strings.TrimPrefix(line, "ERROR"))
		changed = true
	}
	t.mu.Unlock()
	if changed {
		t.publish()
	}
}

func (t *tunManager) publish() {
	st := t.state()
	t.events.emit(event{V: protocolVersion, Event: "tun.state", Data: map[string]interface{}{
		"name":     st.Name,
		"state":    st.State,
		"adapter":  st.Adapter,
		"message":  st.Message,
		"sinceMs":  st.SinceMs,
		"up":       st.Up,
		"down":     st.Down,
		"counters": st.Counters,
	}})
}

