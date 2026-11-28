package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeWGRunner scripts sc.exe / amneziawg.exe for the WG
// driver tests: it tracks one tunnel service's SCM state the
// way the real tools mutate it.
type fakeWGRunner struct {
	present bool
	running bool
	calls   []string
	// failInstall makes /installtunnelservice exit non-zero.
	failInstall bool
}

func (f *fakeWGRunner) Run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	switch {
	case strings.HasSuffix(name, "sc.exe") && len(args) == 2 && args[0] == "query":
		if !f.present {
			return "[SC] EnumQueryServicesStatus:OpenService FAILED 1060:\r\nThe specified service does not exist as an installed service.\r\n", fmt.Errorf("exit status 1")
		}
		word := "STOPPED"
		if f.running {
			word = "RUNNING"
		}
		return fmt.Sprintf("SERVICE_NAME: %s\r\n        STATE              : 4  %s\r\n", args[1], word), nil
	case strings.HasSuffix(name, "sc.exe") && len(args) == 2 && args[0] == "start":
		if !f.present {
			return "", fmt.Errorf("exit status 1")
		}
		f.running = true
		return "", nil
	case strings.HasSuffix(name, "sc.exe") && len(args) == 2 && args[0] == "stop":
		f.running = false
		return "", nil
	case strings.HasSuffix(name, "sc.exe") && len(args) == 2 && args[0] == "delete":
		f.present, f.running = false, false
		return "", nil
	case len(args) == 2 && args[0] == "/installtunnelservice":
		if f.failInstall {
			return "Access is denied.\r\n", fmt.Errorf("exit status 1")
		}
		f.present, f.running = true, true
		return "", nil
	case len(args) == 2 && args[0] == "/uninstalltunnelservice":
		f.present, f.running = false, false
		return "", nil
	}
	return "", fmt.Errorf("unexpected command %s %v", name, args)
}

func newTestWG(t *testing.T, r *fakeWGRunner) (*wgManager, string) {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "wireguard", "amneziawg.exe")
	if err := os.MkdirAll(filepath.Dir(exe), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	w := newWGManager(newRootSet([]string{dir}))
	w.runner = r
	w.storeDir = filepath.Join(dir, "store")
	w.pollAttempts = 3
	w.pollDelay = 0
	return w, exe
}

const wgConf = "[Interface]\nPrivateKey = abc=\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = def=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.1:51820\n"

func TestWGTunnelNameFor(t *testing.T) {
	cases := map[string]string{
		"My Profile!": "My_Profile",
		"ember-de":    "ember-de",
		"":            "ember",
		"...":         "ember",
		"a/b\\c:d":    "a_b_c_d",
	}
	for in, want := range cases {
		if got := awgTunnelNameFor(in); got != want {
			t.Errorf("awgTunnelNameFor(%q) = %q, want %q", in, got, want)
		}
	}
	long := awgTunnelNameFor(strings.Repeat("x", 60))
	if len(long) != 40 {
		t.Errorf("long name capped to %d chars, want 40", len(long))
	}
}

func TestParseSCQueryState(t *testing.T) {
	out := "SERVICE_NAME: AmneziaWGTunnel$ember\r\n        STATE              : 4  RUNNING\r\n"
	if word, ok := parseSCQueryState(out); !ok || word != "running" {
		t.Fatalf("parse = %q,%v", word, ok)
	}
	if _, ok := parseSCQueryState("FAILED 1060: does not exist"); ok {
		t.Fatal("1060 output must not parse as a state")
	}
}

func TestWGStartInstallsWhenAbsent(t *testing.T) {
	r := &fakeWGRunner{}
	w, exe := newTestWG(t, r)
	st, err := w.start(wgStartParams{Name: "My Profile", ConfText: wgConf, Exe: exe})
	if err != nil {
		t.Fatal(err)
	}
	if !st.Running || st.State != "running" {
		t.Fatalf("state = %+v", st)
	}
	if st.ServiceName != "AmneziaWGTunnel$My_Profile" {
		t.Fatalf("service name = %q", st.ServiceName)
	}
	// The config landed in the protected store, named by tunnel.
	confPath := filepath.Join(w.storeDir, "My_Profile.conf")
	b, err := os.ReadFile(confPath)
	if err != nil || string(b) != wgConf {
		t.Fatalf("stored conf: err=%v body=%q", err, b)
	}
	joined := strings.Join(r.calls, "\n")
	if !strings.Contains(joined, "/installtunnelservice "+confPath) {
		t.Fatalf("install verb not issued as verified:\n%s", joined)
	}
	// Stop removes the tunnel service and the stored config.
	st, err = w.stop("My Profile")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != "absent" {
		t.Fatalf("after stop = %+v", st)
	}
	if _, err := os.Stat(confPath); !os.IsNotExist(err) {
		t.Fatalf("stored conf should be deleted on stop, stat err = %v", err)
	}
	if !strings.Contains(strings.Join(r.calls, "\n"), "/uninstalltunnelservice My_Profile") {
		t.Fatalf("uninstall verb not issued:\n%s", strings.Join(r.calls, "\n"))
	}
}

func TestWGStartUsesScStartForExistingStoppedTunnel(t *testing.T) {
	r := &fakeWGRunner{present: true, running: false}
	w, exe := newTestWG(t, r)
	st, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConf, Exe: exe})
	if err != nil {
		t.Fatal(err)
	}
	if !st.Running {
		t.Fatalf("state = %+v", st)
	}
	joined := strings.Join(r.calls, "\n")
	if !strings.Contains(joined, "sc.exe start AmneziaWGTunnel$ember-de") {
		t.Fatalf("sc start not issued:\n%s", joined)
	}
	if strings.Contains(joined, "/installtunnelservice") {
		t.Fatalf("existing tunnel must not be reinstalled:\n%s", joined)
	}
}

func TestWGStartFailsLoudWhenInstallFails(t *testing.T) {
	r := &fakeWGRunner{failInstall: true}
	w, exe := newTestWG(t, r)
	_, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConf, Exe: exe})
	if err == nil || !strings.Contains(err.Error(), "Access is denied") {
		t.Fatalf("err = %v", err)
	}
}

func TestWGStateAbsentNeverAssumed(t *testing.T) {
	r := &fakeWGRunner{}
	w, _ := newTestWG(t, r)
	st := w.state("nothing-here")
	if st.State != "absent" || st.Running {
		t.Fatalf("state = %+v", st)
	}
}

func TestWGStartRejectsNonConfig(t *testing.T) {
	r := &fakeWGRunner{}
	w, exe := newTestWG(t, r)
	if _, err := w.start(wgStartParams{Name: "x", ConfText: "hello", Exe: exe}); err == nil {
		t.Fatal("non-config text must be refused")
	}
}
