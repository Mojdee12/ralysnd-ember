package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A fake OpenVPN management server: accepts the channel,
// reads the client's enable lines, then plays the daemon's
// notifications.
func fakeMgmt(t *testing.T, script func(w *bufio.Writer, r *bufio.Reader)) (port int, done chan struct{}) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done = make(chan struct{})
	go func() {
		defer close(done)
		defer ln.Close()
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		w := bufio.NewWriter(conn)
		fmt.Fprintf(w, ">INFO:OpenVPN Management Interface Version 5\r\n")
		w.Flush()
		script(w, r)
	}()
	return ln.Addr().(*net.TCPAddr).Port, done
}

func TestOvpnSessionViaManagement(t *testing.T) {
	port, _ := fakeMgmt(t, func(w *bufio.Writer, r *bufio.Reader) {
		// Expect the three enable lines, in order.
		for _, want := range []string{"state on", "bytecount 1", "hold release"} {
			line, err := r.ReadString('\n')
			if err != nil || strings.TrimSpace(line) != want {
				t.Errorf("mgmt line = %q err=%v, want %q", line, err, want)
				return
			}
		}
		fmt.Fprintf(w, ">STATE:1700000000,CONNECTED,SUCCESS,10.8.0.2,203.0.113.7,443,,\r\n")
		fmt.Fprintf(w, ">BYTECOUNT:12345,6789\r\n")
		w.Flush()
		// Stay open until the client goes away.
		for {
			if _, err := r.ReadString('\n'); err != nil {
				return
			}
		}
	})

	roots := newRootSet([]string{"/apps/ember"})
	events := newBroadcaster()
	mgr := newManager(fakeLauncher{children: map[string]*fakeChild{
		"openvpn.exe": newFakeChild(999, nil, 0),
	}}, events, roots)
	ov := newOvpnManager(mgr, events)
	ov.portPicker = func() (int, error) { return port, nil }

	st, err := ov.start(ovpnStartParams{
		Name: "ovpn-main", Exe: "/apps/ember/openvpn/openvpn.exe",
		ConfigPath: "/apps/ember/profiles/a.ovpn",
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.State != "starting" {
		t.Fatalf("start state = %+v", st)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		st = ov.state("ovpn-main")
		if st.State == "connected" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("never connected: %+v", st)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if st.Down != 12345 || st.Up != 6789 {
		t.Fatalf("byte counters = up %d down %d", st.Up, st.Down)
	}
	if _, err := ov.stop("ovpn-main"); err != nil {
		t.Fatal(err)
	}
	if st = ov.state("ovpn-main"); st.State != "exited" {
		t.Fatalf("after stop = %+v", st)
	}
}

func TestWarpRegistrationFlow(t *testing.T) {
	var gotKey string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/reg" {
			http.NotFound(w, r)
			return
		}
		var body map[string]interface{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotKey, _ = body["key"].(string)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{
			"account": {"id": "acct-1", "license": "lic-1"},
			"config": {
				"client_id": "oem=",
				"peers": [{"public_key": "peerkey=", "endpoint": {"host": "engage.cloudflareclient.com:2408"}}],
				"interface": {"addresses": {"v4": "172.16.0.2", "v6": "fd01::2"}}
			}
		}`)
	}))
	defer ts.Close()
	old := warpAPIBase
	warpAPIBase = ts.URL
	defer func() { warpAPIBase = old }()

	wm := newWarpManager()
	wm.store = filepath.Join(t.TempDir(), "warp.json")
	p, err := wm.register(false)
	if err != nil {
		t.Fatal(err)
	}
	if gotKey == "" || gotKey != p.PublicKey {
		t.Fatalf("registered key = %q, profile public = %q", gotKey, p.PublicKey)
	}
	if p.AddressV4 != "172.16.0.2" || p.PeerPublicKey != "peerkey=" || p.Endpoint != "engage.cloudflareclient.com:2408" {
		t.Fatalf("profile = %+v", p)
	}
	// Second call serves the stored identity (no new request).
	p2, err := wm.register(false)
	if err != nil {
		t.Fatal(err)
	}
	if p2.PrivateKey != p.PrivateKey {
		t.Fatal("stored identity was not reused")
	}
}
