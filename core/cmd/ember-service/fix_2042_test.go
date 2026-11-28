package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Regression locks for the 2042 adversarial-fix round
// (2042-adversarial-review.md: C1, C2 service half, C3, W4,
// W5). Each test was verified to FAIL against the pre-fix
// behaviour where the pre-fix code path still exists to run
// against (critical_fix_regression_lock).

// ---- C1: wg.start's exe param confers no authority ----

func TestWGFindExeRefusesExeOutsideRoots(t *testing.T) {
	r := &fakeWGRunner{}
	w, _ := newTestWG(t, r)
	// A same-named file in a folder no installer recorded —
	// the exact payload shape of the C1 bypass.
	outside := t.TempDir()
	evil := filepath.Join(outside, "amneziawg.exe")
	if err := os.WriteFile(evil, []byte("payload"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := w.findExe(wgStartParams{Exe: evil}); err == nil {
		t.Fatal("exe param outside the roots was accepted")
	}
	// Through start() as well: refused, and nothing ran.
	if _, err := w.start(wgStartParams{Name: "p", ConfText: wgConf, Exe: evil}); err == nil {
		t.Fatal("wg.start accepted an exe outside the roots")
	}
	for _, call := range r.calls {
		if strings.Contains(call, "/installtunnelservice") || strings.Contains(call, " start ") {
			t.Fatalf("a start verb ran for a refused start: %v", r.calls)
		}
	}
	// A traversal spelling of an outside path is refused too.
	sneaky := filepath.Join(outside, "wireguard", "..", "amneziawg.exe")
	if _, err := w.findExe(wgStartParams{Exe: sneaky}); err == nil {
		t.Fatal("traversal exe param was accepted")
	}
}

func TestWGFindExeResolvesInRoot(t *testing.T) {
	// All-lowercase temp root: the root set stores cleaned
	// (lower-cased) paths, and this stat runs on a
	// case-sensitive filesystem.
	root, err := os.MkdirTemp("", "emberwgroot")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	exe := filepath.Join(root, "wireguard", "amneziawg.exe")
	if err := os.MkdirAll(filepath.Dir(exe), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	w := newWGManager(newRootSet([]string{root}))
	// No param: resolved from the root set.
	got, err := w.findExe(wgStartParams{})
	if err != nil {
		t.Fatal(err)
	}
	if got != exe {
		t.Fatalf("resolved exe = %q, want %q", got, exe)
	}
	// Param naming exactly that file: accepted.
	if got, err := w.findExe(wgStartParams{Exe: exe}); err != nil || got != exe {
		t.Fatalf("in-root param: got %q err %v", got, err)
	}
}

// ---- C3: the exe-grandparent auto-add guard ----

func TestExeAutoRootGuard(t *testing.T) {
	cases := []struct {
		name string
		exe  string
		want string
		ok   bool
	}{
		{"installed core layout", `C:\Program Files\Ralysnd Ember\core\ember-service.exe`, "C:/Program Files/Ralysnd Ember", true},
		{"exe directly in app folder under Program Files", `C:\Program Files\Ralysnd Ember\ember-service.exe`, "", false},
		{"Program Files itself, upper case", `C:\PROGRAM FILES\ember-service.exe`, "", false},
		{"Program Files (x86) itself", `C:\Program Files (x86)\ember-service.exe`, "", false},
		{"drive root", `C:\ember-service.exe`, "", false},
		{"top-level folder only", `C:\Ember\ember-service.exe`, "", false},
		{"private vendor folder", `C:\Apps\Ember\core\ember-service.exe`, "C:/Apps/Ember", true},
		{"ProgramData itself", `C:\ProgramData\ember-service.exe`, "", false},
		{"Windows folder itself", `C:\Windows\core\ember-service.exe`, "", false},
		{"WindowsApps parent", `C:\Program Files\WindowsApps\ember-service.exe`, "", false},
		{"unix dev layout", "/home/rayan/ember/core/ember-service", "/home/rayan/ember", true},
		{"unix too shallow", "/opt/ember/core/ember-service", "", false},
		{"forward slashes", "C:/Program Files/Ralysnd Ember/core/ember-service.exe", "C:/Program Files/Ralysnd Ember", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := exeAutoRoot(tc.exe)
			if ok != tc.ok || got != tc.want {
				t.Fatalf("exeAutoRoot(%q) = %q,%v; want %q,%v", tc.exe, got, ok, tc.want, tc.ok)
			}
		})
	}
}

// ---- C2 (service half): the owner-SID decision ----

func TestOwnerSIDAllows(t *testing.T) {
	const owner = "S-1-5-21-1004336348-1177238915-682003330-1001"
	cases := []struct {
		name     string
		recorded string
		client   string
		want     bool
	}{
		{"no owner recorded allows anyone", "", "S-1-5-21-9-9-9-1002", true},
		{"no owner and no client", "", "", true},
		{"exact match", owner, owner, true},
		{"case-insensitive match", owner, strings.ToLower(owner), true},
		{"other user refused", owner, "S-1-5-21-1004336348-1177238915-682003330-1002", false},
		{"unidentifiable client refused", owner, "", false},
		{"system refused", owner, "S-1-5-18", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ownerSIDAllows(tc.recorded, tc.client); got != tc.want {
				t.Fatalf("ownerSIDAllows(%q, %q) = %v, want %v", tc.recorded, tc.client, got, tc.want)
			}
		})
	}
}

// ---- W4: concurrent duplicate starts ----

// slowLauncher blocks inside Launch until released, opening
// the check-then-act window deterministically.
type slowLauncher struct {
	entered  chan struct{}
	release  chan struct{}
	once     sync.Once
	mu       sync.Mutex
	launches int
}

func newSlowLauncher() *slowLauncher {
	return &slowLauncher{entered: make(chan struct{}), release: make(chan struct{})}
}

func (l *slowLauncher) Launch(procSpec) (child, error) {
	l.mu.Lock()
	l.launches++
	l.mu.Unlock()
	l.once.Do(func() { close(l.entered) })
	<-l.release
	return newFakeChild(4321, nil, 0), nil
}

func (l *slowLauncher) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.launches
}

func TestManagerConcurrentStartRefused(t *testing.T) {
	l := newSlowLauncher()
	mgr := newManager(l, newBroadcaster(), newRootSet([]string{"/apps/ember"}))
	spec := procSpec{Name: "xray", Exe: "/apps/ember/xray/xray.exe"}
	errCh := make(chan error, 1)
	go func() {
		_, err := mgr.start(spec)
		errCh <- err
	}()
	<-l.entered // first start is inside Launch
	if _, err := mgr.start(spec); err == nil ||
		!strings.Contains(err.Error(), "start already in progress") {
		t.Fatalf("concurrent start error = %v", err)
	}
	close(l.release)
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if got := l.count(); got != 1 {
		t.Fatalf("launches = %d, want exactly 1", got)
	}
	// The in-flight mark cleared on completion: a fresh start
	// now meets the ordinary already-running refusal.
	if _, err := mgr.start(spec); err == nil ||
		!strings.Contains(err.Error(), "already running") {
		t.Fatalf("post-start error = %v", err)
	}
}

func TestOvpnConcurrentStartRefused(t *testing.T) {
	l := newSlowLauncher()
	events := newBroadcaster()
	mgr := newManager(l, events, newRootSet([]string{"/apps/ember"}))
	ov := newOvpnManager(mgr, events)
	ov.portPicker = func() (int, error) { return 49999, nil }
	p := ovpnStartParams{Name: "ovpn-main", Exe: "/apps/ember/openvpn/openvpn.exe", ConfigPath: "/nonexistent/a.ovpn"}
	errCh := make(chan error, 1)
	go func() {
		_, err := ov.start(p)
		errCh <- err
	}()
	<-l.entered
	if _, err := ov.start(p); err == nil ||
		!strings.Contains(err.Error(), "start already in progress") {
		t.Fatalf("concurrent ovpn start error = %v", err)
	}
	close(l.release)
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if got := l.count(); got != 1 {
		t.Fatalf("launches = %d, want exactly 1", got)
	}
}

// ---- W4-adjacent / B-S4: the ovpn config sanitiser ----

func TestCheckOvpnConfigText(t *testing.T) {
	clean := "client\ndev tun\nproto udp\nremote vpn.example.com 1194\n" +
		"auth-user-pass\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n"
	if err := checkOvpnConfigText(clean); err != nil {
		t.Fatalf("clean config refused: %v", err)
	}
	blocked := []struct {
		line string
		want string
	}{
		{"plugin /usr/lib/auth.so", "plugin"},
		{"  up /tmp/pwn.sh", "up"},
		{"UP /tmp/pwn.sh", "up"},
		{"down /tmp/pwn.sh", "down"},
		{"script-security 2", "script-security"},
		{"management 127.0.0.1 7505", "management"},
		{"Management 127.0.0.1 7505", "management"},
		{"route-up /tmp/x", "route-up"},
		{"tls-verify /tmp/x", "tls-verify"},
		{"auth-user-pass-verify /tmp/x via-env", "auth-user-pass-verify"},
		{"daemon", "daemon"},
		{"log /tmp/x", "log"},
		{"log-append /tmp/x", "log-append"},
		{"writepid /tmp/x", "writepid"},
		{"status /tmp/x 5", "status"},
		{"learn-address /tmp/x", "learn-address"},
		{"client-connect /tmp/x", "client-connect"},
		{"ifconfig-pool-persist /tmp/x", "ifconfig-pool-persist"},
	}
	for _, tc := range blocked {
		text := "client\ndev tun\n" + tc.line + "\nremote vpn.example.com 1194\n"
		err := checkOvpnConfigText(text)
		if err == nil {
			t.Errorf("directive %q was not refused", tc.line)
			continue
		}
		if !strings.Contains(err.Error(), `"`+tc.want+`"`) {
			t.Errorf("refusal for %q does not name the directive: %v", tc.line, err)
		}
	}
}

// ---- W5: a running tunnel's config is never overwritten ----

const wgConfB = "[Interface]\nPrivateKey = xyz=\nAddress = 10.0.0.3/32\n\n[Peer]\nPublicKey = def=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.2:51820\n"

func TestWGStartRefusesConfigChangeWhileRunning(t *testing.T) {
	r := &fakeWGRunner{}
	w, exe := newTestWG(t, r)
	if _, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConf, Exe: exe}); err != nil {
		t.Fatal(err)
	}
	// Same config on the running tunnel: idempotent success.
	st, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConf, Exe: exe})
	if err != nil {
		t.Fatalf("same-config restart of a running tunnel: %v", err)
	}
	if !st.Running {
		t.Fatalf("state = %+v", st)
	}
	// Different config: refused, and the stored config is
	// untouched (the old tunnel keeps carrying its own conf).
	if _, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConfB, Exe: exe}); err == nil ||
		!strings.Contains(err.Error(), "tunnel is running") {
		t.Fatalf("config-change error = %v", err)
	}
	b, err := os.ReadFile(filepath.Join(w.storeDir, "ember-de.conf"))
	if err != nil || string(b) != wgConf {
		t.Fatalf("stored conf changed under a running tunnel: err=%v body=%q", err, b)
	}
	// After a stop, the new config starts fine.
	if _, err := w.stop("ember-de"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.start(wgStartParams{Name: "ember-de", ConfText: wgConfB, Exe: exe}); err != nil {
		t.Fatalf("start after stop with new config: %v", err)
	}
}
