//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// Install/uninstall for the Ember service. The installed copy
// lives in %ProgramFiles%\Ralysnd Ember\ember-service.exe and
// runs as LocalSystem, auto-start, restart-on-failure. The
// app's installer invokes `ember-service.exe install` from the
// app's core\ folder; the verb records THAT folder's parent as
// an app root, copies itself into Program Files, registers and
// starts the service. Elevation is self-service: when the
// caller is not elevated the verb relaunches itself with the
// "runas" verb and waits — the same pattern the TUN service
// installer has used since the first build.

func installedExe() string {
	pf := os.Getenv("ProgramFiles")
	if pf == "" {
		pf = `C:\Program Files`
	}
	return filepath.Join(pf, "Ralysnd Ember", "ember-service.exe")
}

func isElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

var (
	shell32          = windows.NewLazySystemDLL("shell32.dll")
	procShellExecute = shell32.NewProc("ShellExecuteExW")
)

type shellExecuteInfo struct {
	cbSize       uint32
	fMask        uint32
	hwnd         uintptr
	lpVerb       *uint16
	lpFile       *uint16
	lpParameters *uint16
	lpDirectory  *uint16
	nShow        int32
	hInstApp     uintptr
	lpIDList     uintptr
	lpClass      *uint16
	hkeyClass    uintptr
	dwHotKey     uint32
	hIcon        uintptr
	hProcess     uintptr
}

const (
	seeMaskNocloseProcess = 0x00000040
	swHide                = 0
)

// relaunchElevated starts this exe with the given verb under a
// UAC prompt and waits for it to finish, returning its exit
// code. The user sees one prompt; a decline is a plain error.
func relaunchElevated(verb string) (int, error) {
	code, _, err := relaunchElevatedWait(verb, 0)
	return code, err
}

// relaunchElevatedWait is relaunchElevated with a bounded wait:
// timeout <= 0 waits forever; otherwise finished=false reports
// that the elevated process was still running when the wait
// gave up (it is NOT killed — an installer mid-swap must not be
// shot; the caller decides what an unfinished wait means).
func relaunchElevatedWait(verb string, timeout time.Duration) (code int, finished bool, err error) {
	exe, err := os.Executable()
	if err != nil {
		return 1, false, err
	}
	verbPtr, _ := windows.UTF16PtrFromString("runas")
	filePtr, _ := windows.UTF16PtrFromString(exe)
	paramsPtr, _ := windows.UTF16PtrFromString(verb)
	sei := shellExecuteInfo{
		fMask:        seeMaskNocloseProcess,
		lpVerb:       verbPtr,
		lpFile:       filePtr,
		lpParameters: paramsPtr,
		nShow:        swHide,
	}
	sei.cbSize = uint32(unsafe.Sizeof(sei))
	r, _, callErr := procShellExecute.Call(uintptr(unsafe.Pointer(&sei)))
	if r == 0 {
		return 1, false, fmt.Errorf("elevation failed: %v", callErr)
	}
	if sei.hProcess != 0 {
		defer windows.CloseHandle(windows.Handle(sei.hProcess))
		wait := uint32(windows.INFINITE)
		if timeout > 0 {
			wait = uint32(timeout / time.Millisecond)
		}
		event, _ := windows.WaitForSingleObject(windows.Handle(sei.hProcess), wait)
		if timeout > 0 && event == uint32(windows.WAIT_TIMEOUT) {
			return 0, false, nil
		}
		var exitCode uint32
		if err := windows.GetExitCodeProcess(windows.Handle(sei.hProcess), &exitCode); err == nil {
			return int(exitCode), true, nil
		}
		return 0, true, nil
	}
	return 0, false, nil
}

// installWaitTimeout bounds the non-elevated stub's whole
// wait for the elevated install (audit W8): the elevated flow
// can legitimately take a while (30s stop + 15s gone-wait +
// 20s RUNNING + 20s hello, ×2 on rollback), so the bound is
// generous — but it IS a bound, and the outcome is read from
// the result file, not from the stub's captured stdio.
const installWaitTimeout = 150 * time.Second

// installResult is the install-result channel (audit W8): the
// elevated installer writes one of these on EVERY ending, and
// the non-elevated stub (whose caller — the Electron shell via
// svc:install — can only see the stub's stdio and exit code)
// reads it back and surfaces the REAL message, including the
// loud rollback wording, instead of its own silence.
type installResult struct {
	OK         bool      `json:"ok"`
	Message    string    `json:"message"`
	FinishedAt time.Time `json:"finishedAt"`
}

func installResultPath() string {
	return filepath.Join(filepath.Dir(configPath()), "install-result.json")
}

// writeInstallResult records the outcome atomically (temp file
// + rename) so a stub polling the path never reads a torn file.
func writeInstallResult(ok bool, message string) error {
	b, err := json.Marshal(installResult{OK: ok, Message: message, FinishedAt: time.Now()})
	if err != nil {
		return err
	}
	p := installResultPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// readFreshInstallResult returns the recorded result only when
// it was finished strictly after the stub started — a stale
// result from an earlier install must never be reported as
// this run's outcome.
func readFreshInstallResult(start time.Time) (installResult, bool) {
	b, err := os.ReadFile(installResultPath())
	if err != nil {
		return installResult{}, false
	}
	var res installResult
	if err := json.Unmarshal(b, &res); err != nil {
		return installResult{}, false
	}
	if !res.FinishedAt.After(start) {
		return installResult{}, false
	}
	return res, true
}

func runInstall() int {
	if !isElevated() {
		start := time.Now()
		// The elevated child's exit code and stdio are NOT the
		// outcome (W8): its stderr goes to a hidden console.
		// Wait for it (bounded), then read the result file it
		// wrote and surface that message and verdict.
		if _, _, err := relaunchElevatedWait("install", installWaitTimeout); err != nil {
			fmt.Fprintln(os.Stderr, "install:", err)
			return 1
		}
		deadline := start.Add(installWaitTimeout)
		for {
			if res, ok := readFreshInstallResult(start); ok {
				if res.OK {
					fmt.Println(res.Message)
					return 0
				}
				fmt.Fprintln(os.Stderr, res.Message)
				return 1
			}
			if !time.Now().Before(deadline) {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
		fmt.Fprintln(os.Stderr, "install: no result from the elevated installer within 150s — the install outcome is unknown; check %ProgramData%\\Ralysnd Ember\\install-result.json or run the install again")
		return 1
	}
	if err := installElevated(); err != nil {
		fmt.Fprintln(os.Stderr, "install:", err)
		return 1
	}
	fmt.Println("ember-service installed and started")
	return 0
}

// installElevated replaces the installed service WITHOUT ever
// destroying a working one on a failed upgrade (audit D1).
// The order is the whole fix:
//
//	(a) stage the NEW binary beside the target and prove the
//	    staged copy answers its `version` verb — the old
//	    service is untouched so far, and the previous binary
//	    is backed up beside the target;
//	(b) only then stop the old service (verified stopped —
//	    a still-running service aborts the install with the
//	    old registration intact, it is NOT deleted under it);
//	(c) delete the old registration, swap the staged binary
//	    into place, record the app root, register + start;
//	(d) verify the NEW service: SCM reports RUNNING and the
//	    pipe answers a hello;
//	(e) ANY failure after the old service was stopped rolls
//	    back: the partial new registration is removed, the
//	    previous binary and roots record are restored, the
//	    old service is re-registered, started and verified,
//	    and the original failure is returned loudly.
//
// It never ends with "old deleted + nothing working + success
// reported": success is returned only after (d) passes.
func installElevated() error {
	err := installElevatedBody()
	// W8: EVERY ending records its outcome in the result file
	// before returning — success, failure-with-rollback and
	// failure-rollback-failed alike — so the non-elevated stub
	// can surface the real wording. A result-write failure on
	// an otherwise successful install is itself reported: an
	// install whose outcome cannot be recorded must not pose
	// as a clean success to the stub waiting on that file.
	message := "ember-service installed and started"
	if err != nil {
		message = err.Error()
	}
	if werr := writeInstallResult(err == nil, message); werr != nil && err == nil {
		return fmt.Errorf("the service installed, but recording the install result failed: %w", werr)
	}
	return err
}

func installElevatedBody() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	appRoot := appRootOf(self)
	target := installedExe()
	staged := target + ".staged"
	backup := target + ".prev"
	sameFile := strings.EqualFold(filepath.Clean(self), filepath.Clean(target))

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}

	// (a) Stage + verify the new binary, old service untouched.
	if !sameFile {
		if err := copyFile(self, staged); err != nil {
			return fmt.Errorf("stage the new service binary: %w", err)
		}
	} else {
		staged = target
	}
	if err := verifyVersionVerb(staged); err != nil {
		if !sameFile {
			_ = os.Remove(staged)
		}
		return fmt.Errorf("the staged service binary does not run, install aborted with the previous service untouched: %w", err)
	}
	// Back up the previous binary (reading a running exe is
	// fine; replacing one is the part that needs it stopped).
	hadBinary := false
	if _, err := os.Stat(target); err == nil {
		hadBinary = true
		if err := copyFile(target, backup); err != nil {
			if !sameFile {
				_ = os.Remove(staged)
			}
			return fmt.Errorf("back up the previous service binary: %w", err)
		}
	}
	// Snapshot the roots record so a rollback restores it too.
	rootsPath := configPath()
	rootsBefore, rootsErr := os.ReadFile(rootsPath)
	hadRoots := rootsErr == nil

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to the service manager: %w", err)
	}
	defer m.Disconnect()

	hadService := false
	if old, err := m.OpenService(serviceName); err == nil {
		hadService = true
		// (b) Stop — and prove it stopped — BEFORE anything
		// is deleted. stopService now waits up to 30s: the
		// old 5s cap raced children that stop serially and
		// left the exe image locked for the swap.
		if err := stopService(old); err != nil {
			old.Close()
			// Nothing was deleted; try to leave the old
			// service running as we found it.
			if s2, err2 := m.OpenService(serviceName); err2 == nil {
				_ = s2.Start()
				s2.Close()
			}
			if !sameFile {
				_ = os.Remove(staged)
			}
			return fmt.Errorf("the previous service did not stop, install aborted with it still registered: %w", err)
		}
		if err := old.Delete(); err != nil {
			old.Close()
			if s2, err2 := m.OpenService(serviceName); err2 == nil {
				_ = s2.Start()
				s2.Close()
			}
			if !sameFile {
				_ = os.Remove(staged)
			}
			return fmt.Errorf("delete the previous registration: %w (the previous service was restarted)", err)
		}
		old.Close()
		if !waitServiceGone(m, 15*time.Second) {
			rbErr := rollbackInstall(m, target, backup, hadBinary, hadService, rootsPath, rootsBefore, hadRoots)
			if !sameFile {
				_ = os.Remove(staged)
			}
			return loudInstallFailure(fmt.Errorf("the previous registration is still pending deletion"), rbErr)
		}
	}

	// From here on the old service is stopped/gone: every
	// failure rolls back via rollbackInstall.
	fail := func(stepErr error) error {
		rbErr := rollbackInstall(m, target, backup, hadBinary, hadService, rootsPath, rootsBefore, hadRoots)
		if !sameFile {
			_ = os.Remove(staged)
		}
		return loudInstallFailure(stepErr, rbErr)
	}

	// (c) Swap + record roots + register + start.
	if !sameFile {
		if err := os.Rename(staged, target); err != nil {
			return fail(fmt.Errorf("swap the new service binary into place: %w", err))
		}
	}
	roots := loadRoots()
	roots.add(appRoot)
	if err := saveRoots(roots.list()); err != nil {
		return fail(fmt.Errorf("record the app folder: %w", err))
	}
	// C2 (install half): record the installing user's SID as
	// the install's owner. This elevated process runs under
	// that user's token, so its token user IS the owner; the
	// service binds pipe connections to this SID (the actual
	// boundary behind the pipe SDDL's INTERACTIVE pre-filter).
	// The rollback snapshot above (rootsBefore) covers this
	// write too — it restores the whole previous service.json.
	ownerSID, err := currentUserSID()
	if err != nil {
		return fail(fmt.Errorf("read the installing user's SID: %w", err))
	}
	if err := saveOwnerSID(ownerSID); err != nil {
		return fail(fmt.Errorf("record the installing user's SID: %w", err))
	}
	// (d) registerAndStart verifies SCM RUNNING + pipe hello.
	if err := registerAndStart(m, target); err != nil {
		return fail(err)
	}

	_ = os.Remove(backup)
	return nil
}

// currentUserSID returns the SID (string form) of the user
// whose token this process runs under. In installElevated
// that is the installing user — elevation keeps the same
// account's SID, only the privilege level changes.
func currentUserSID() (string, error) {
	tu, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", err
	}
	return tu.User.Sid.String(), nil
}

// saveOwnerSID persists sid as the config's OwnerSID via a
// read-modify-write of serviceConfig, preserving the app
// roots saveRoots just wrote (and vice versa: saveRoots
// preserves OwnerSID the same way).
func saveOwnerSID(sid string) error {
	p := configPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	cfg := loadServiceConfig()
	cfg.OwnerSID = sid
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o644)
}

// loudInstallFailure words a failed install so the outcome is
// unmistakable: what failed, and whether the rollback left the
// previous service working again or ALSO failed.
func loudInstallFailure(stepErr, rbErr error) error {
	if rbErr != nil {
		return fmt.Errorf("INSTALL FAILED: %v — AND THE ROLLBACK ALSO FAILED: %v — the Ember service may be missing; reinstall Ralysnd Ember to repair it", stepErr, rbErr)
	}
	return fmt.Errorf("INSTALL FAILED: %v — the previous service was restored and verified running; nothing was lost, retry the install", stepErr)
}

// rollbackInstall undoes a half-finished replacement: remove
// any partial new registration, restore the previous binary
// and roots record, then re-register, start and verify the
// previous service (when there was one). Every step is
// attempted; failures are aggregated, never swallowed.
func rollbackInstall(m *mgr.Mgr, target, backup string, hadBinary, hadService bool, rootsPath string, rootsBefore []byte, hadRoots bool) error {
	var problems []string
	if err := deleteRegistration(m); err != nil {
		problems = append(problems, err.Error())
	}
	if hadBinary {
		if err := copyFile(backup, target); err != nil {
			problems = append(problems, "restore the previous binary: "+err.Error())
		}
	} else {
		_ = os.Remove(target)
	}
	if hadRoots {
		if err := os.WriteFile(rootsPath, rootsBefore, 0o644); err != nil {
			problems = append(problems, "restore the roots record: "+err.Error())
		}
	} else {
		_ = os.Remove(rootsPath)
	}
	if hadService {
		if err := registerAndStart(m, target); err != nil {
			problems = append(problems, "restart the previous service: "+err.Error())
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, "; "))
	}
	return nil
}

// deleteRegistration stops (if needed) and deletes the
// service registration, waiting until the SCM agrees it is
// gone. A service that is not registered is already deleted.
func deleteRegistration(m *mgr.Mgr) error {
	s, err := m.OpenService(serviceName)
	if err != nil {
		return nil
	}
	// A stop that could not be PROVEN stopped (W7) must not be
	// waved through into a delete under a possibly-live service.
	if err := stopService(s); err != nil {
		s.Close()
		return fmt.Errorf("stop the service before deleting its registration: %w", err)
	}
	err = s.Delete()
	s.Close()
	if err != nil {
		return fmt.Errorf("delete the service registration: %w", err)
	}
	if !waitServiceGone(m, 15*time.Second) {
		return fmt.Errorf("the service registration is still pending deletion")
	}
	return nil
}

func waitServiceGone(m *mgr.Mgr, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		s, err := m.OpenService(serviceName)
		if err != nil {
			return true
		}
		s.Close()
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// registerAndStart creates the registration for the binary at
// target, sets restart-on-failure, starts it, and verifies
// (audit D1 step d): the SCM reports RUNNING and the pipe
// answers a hello. Used for the new service and, identically,
// for the rollback's previous service.
// createServiceRetry registers the service, retrying the one
// transient failure the delete-then-recreate flow can hit
// (audit W7): while the previous registration is still marked
// for deletion and draining, CreateService fails with
// ERROR_SERVICE_MARKED_FOR_DELETE (1072). That window closes
// on its own, so it is retried — bounded, 10 attempts 1s
// apart — instead of failing an install (or, worse, a
// rollback) whose only fault is timing. Any other error is
// returned at once.
func createServiceRetry(m *mgr.Mgr, target string) (*mgr.Service, error) {
	var lastErr error
	for attempt := 0; attempt < 10; attempt++ {
		s, err := m.CreateService(serviceName, target, mgr.Config{
			DisplayName: displayName,
			Description: "Owns Ralysnd Ember's engine processes and TUN sessions.",
			StartType:   mgr.StartAutomatic,
		})
		if err == nil {
			return s, nil
		}
		lastErr = err
		if !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
			break
		}
		if attempt < 9 {
			time.Sleep(1 * time.Second)
		}
	}
	return nil, lastErr
}

func registerAndStart(m *mgr.Mgr, target string) error {
	s, err := createServiceRetry(m, target)
	if err != nil {
		return fmt.Errorf("register the service: %w", err)
	}
	defer s.Close()
	// Restart on failure, three times a minute apart; `sc` is
	// the reliable way to set failure actions.
	_ = exec.Command("sc.exe", "failure", serviceName,
		"reset=", "86400", "actions=", "restart/60000/restart/60000/restart/60000").Run()
	if err := s.Start(); err != nil {
		return fmt.Errorf("start the service: %w", err)
	}
	deadline := time.Now().Add(20 * time.Second)
	running := false
	for time.Now().Before(deadline) {
		if status, err := s.Query(); err == nil && status.State == svc.Running {
			running = true
			break
		}
		time.Sleep(300 * time.Millisecond)
	}
	if !running {
		return fmt.Errorf("the service did not reach RUNNING within 20s")
	}
	if err := verifyPipeHello(20 * time.Second); err != nil {
		return err
	}
	return nil
}

// verifyPipeHello proves the service's pipe answers a real
// hello request (not just that a dial succeeds).
func verifyPipeHello(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		c, err := dialService(2 * time.Second)
		if err == nil {
			_, err = c.call("hello", map[string]interface{}{})
			c.conn.Close()
			if err == nil {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("the service is RUNNING but its pipe did not answer a hello within %s", timeout)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// verifyVersionVerb runs a staged service binary's `version`
// verb: it must exit 0 and print a non-empty version. This is
// the proof the staged copy is a runnable ember-service at
// all before the working service is touched.
func verifyVersionVerb(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "version").Output()
	if err != nil {
		return fmt.Errorf("%s version: %w", path, err)
	}
	if strings.TrimSpace(string(out)) == "" {
		return fmt.Errorf("%s version printed nothing", path)
	}
	return nil
}

// stopService asks the service to stop and waits until the
// SCM reports STOPPED — up to 30s, because the service's
// children stop serially (audit D1: the old ~5s cap let the
// installer race a still-running, image-locked exe). A
// service that will not stop is an ERROR now, not a shrug:
// callers that replace the binary must know.
func stopService(s *mgr.Service) error {
	// Only a proven STOPPED state — or the service not existing
	// at all (1060) — counts as stopped (audit W7). A Query
	// ERROR is an error: the previous code treated any query
	// failure as proof of STOPPED, asserting a state it had not
	// proven at the exact step that exists to prove it.
	status, err := s.Query()
	if err != nil {
		if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return nil
		}
		return fmt.Errorf("query the service state: %w", err)
	}
	if status.State == svc.Stopped {
		return nil
	}
	if status.State == svc.Running || status.State == svc.StartPending {
		if _, err := s.Control(svc.Stop); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		status, err = s.Query()
		if err != nil {
			if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
				return nil
			}
			return fmt.Errorf("query the service state while stopping: %w", err)
		}
		if status.State == svc.Stopped {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("the service did not stop within 30s (state %v)", status.State)
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	tmp := dst + ".new"
	if err := os.WriteFile(tmp, b, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

func runUninstall() int {
	if !isElevated() {
		code, err := relaunchElevated("uninstall")
		if err != nil {
			fmt.Fprintln(os.Stderr, "uninstall:", err)
			return 1
		}
		return code
	}
	if err := uninstallElevated(); err != nil {
		fmt.Fprintln(os.Stderr, "uninstall:", err)
		return 1
	}
	fmt.Println("ember-service removed")
	return 0
}

func uninstallElevated() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	if s, err := m.OpenService(serviceName); err == nil {
		_ = stopService(s)
		err = s.Delete()
		s.Close()
		if err != nil {
			return err
		}
	}
	target := installedExe()
	if self, err := os.Executable(); err == nil && !strings.EqualFold(filepath.Clean(self), filepath.Clean(target)) {
		_ = os.Remove(target)
		_ = os.Remove(filepath.Dir(target))
	}
	_ = os.RemoveAll(filepath.Dir(configPath()))
	return nil
}
