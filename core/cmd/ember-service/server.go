package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/version"
)

// The server: accepts pipe connections, speaks the JSON-lines
// protocol, and forwards the managers' events to every client.
// One connection per client; requests on a connection are
// handled in order, events interleave freely.

type server struct {
	mgr       *manager
	tun       *tunManager
	ovpn      *ovpnManager
	warp      *warpManager
	lantern   *lanternManager
	roots     *rootSet
	events    *broadcaster
	startedAt time.Time
}

func newServer(roots *rootSet) *server {
	events := newBroadcaster()
	mgr := newManager(execLauncher{}, events, roots)
	return &server{
		mgr:       mgr,
		tun:       newTunManager(mgr, events),
		ovpn:      newOvpnManager(mgr, events),
		warp:      newWarpManager(),
		lantern:   newLanternManager(mgr),
		roots:     roots,
		events:    events,
		startedAt: time.Now(),
	}
}

func (s *server) shutdown() {
	_, _ = s.tun.stop()
	s.mgr.stopAll()
}

func (s *server) serve(ln net.Listener) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go s.handle(conn)
	}
}

func (s *server) handle(conn net.Conn) {
	defer conn.Close()
	sub := s.events.subscribe()
	defer s.events.unsubscribe(sub)

	var wmu sync.Mutex
	write := func(v interface{}) {
		b, err := encodeLine(v)
		if err != nil {
			return
		}
		wmu.Lock()
		_, _ = conn.Write(b)
		wmu.Unlock()
	}
	go func() {
		for ev := range sub {
			write(ev)
		}
	}()

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 1<<20)
	for sc.Scan() {
		var req request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			write(response{V: protocolVersion, OK: false, Error: "bad request frame"})
			continue
		}
		write(s.dispatch(req))
	}
}

func (s *server) dispatch(req request) response {
	if req.V != protocolVersion {
		return failResp(req.ID, "unsupported protocol version")
	}
	var err error
	var result interface{}
	switch req.Method {
	case "hello":
		var p struct {
			AppRoot string `json:"appRoot,omitempty"`
		}
		err = paramsInto(req.Params, &p)
		if err == nil && p.AppRoot != "" {
			s.roots.add(p.AppRoot)
		}
		if err == nil {
			result = map[string]interface{}{
				"name":        "ralysnd-ember-service",
				"version":     version.Current,
				"protocol":    protocolVersion,
				"startedAtMs": s.startedAt.UnixMilli(),
				"procs":       s.mgr.states(),
				"tun":         s.tun.state(),
			}
		}
	case "service.status":
		result = map[string]interface{}{
			"procs": s.mgr.states(),
			"tun":   s.tun.state(),
			"ovpn":  s.ovpn.states(),
		}
	case "proc.start":
		var p procSpec
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.mgr.start(p)
		}
	case "proc.stop":
		var p struct {
			Name string `json:"name"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.mgr.stop(p.Name)
		}
	case "proc.state":
		var p struct {
			Name string `json:"name"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			result = s.mgr.state(p.Name)
		}
	case "proc.write":
		var p struct {
			Name string `json:"name"`
			Line string `json:"line"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			err = s.mgr.write(p.Name, p.Line)
			result = map[string]interface{}{"written": err == nil}
		}
	case "tun.start":
		var p tunStartParams
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.tun.start(p)
		}
	case "tun.stop":
		result, err = s.tun.stop()
	case "tun.state":
		result = s.tun.state()
	case "ovpn.start":
		var p ovpnStartParams
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.ovpn.start(p)
		}
	case "ovpn.stop":
		var p struct {
			Name string `json:"name"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.ovpn.stop(p.Name)
		}
	case "ovpn.state":
		var p struct {
			Name string `json:"name"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			result = s.ovpn.state(p.Name)
		}
	case "ovpn.auth":
		var p struct {
			Name     string `json:"name"`
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if err = paramsInto(req.Params, &p); err == nil {
			err = s.ovpn.auth(p.Name, p.Username, p.Password)
			result = map[string]interface{}{"sent": err == nil}
		}
	case "warp.register":
		var p struct {
			Force bool `json:"force,omitempty"`
		}
		_ = paramsInto(req.Params, &p)
		result, err = s.warp.register(p.Force)
	case "warp.profile":
		result, err = s.warp.stored()
	case "lantern.start":
		var p lanternStartParams
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.lantern.start(p)
		}
	case "lantern.stop":
		result, err = s.lantern.stop()
	case "lantern.state":
		result = s.lantern.state()
	case "lantern.call":
		var p lanternCallParams
		if err = paramsInto(req.Params, &p); err == nil {
			result, err = s.lantern.call(p)
		}
	default:
		err = errors.New("unknown method " + req.Method)
	}
	if err != nil {
		return failResp(req.ID, err.Error())
	}
	return response{V: protocolVersion, ID: req.ID, OK: true, Result: result}
}

func failResp(id int, msg string) response {
	return response{V: protocolVersion, ID: id, OK: false, Error: msg}
}
