//go:build windows

package main

import (
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
	exe, err := os.Executable()
	if err != nil {
		return 1, err
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
		return 1, fmt.Errorf("elevation failed: %v", callErr)
	}
	if sei.hProcess != 0 {
		defer windows.CloseHandle(windows.Handle(sei.hProcess))
		_, _ = windows.WaitForSingleObject(windows.Handle(sei.hProcess), windows.INFINITE)
		var code uint32
		if err := windows.GetExitCodeProcess(windows.Handle(sei.hProcess), &code); err == nil {
			return int(code), nil
		}
	}
	return 0, nil
}

func runInstall() int {
	if !isElevated() {
		code, err := relaunchElevated("install")
		if err != nil {
			fmt.Fprintln(os.Stderr, "install:", err)
			return 1
		}
		return code
	}
	if err := installElevated(); err != nil {
		fmt.Fprintln(os.Stderr, "install:", err)
		return 1
	}
	fmt.Println("ember-service installed and started")
	return 0
}

func installElevated() error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	appRoot := appRootOf(self)
	target := installedExe()

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to the service manager: %w", err)
	}
	defer m.Disconnect()

	// Replace any previous registration so upgrades are one
	// path: stop, delete, wait until it is gone.
	if old, err := m.OpenService(serviceName); err == nil {
		_ = stopService(old)
		_ = old.Delete()
		old.Close()
		for i := 0; i < 50; i++ {
			gone, err := m.OpenService(serviceName)
			if err != nil {
				break
			}
			gone.Close()
			time.Sleep(100 * time.Millisecond)
		}
	}

	if clean := filepath.Clean(self); !strings.EqualFold(clean, filepath.Clean(target)) {
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := copyFile(self, target); err != nil {
			return fmt.Errorf("copy the service into Program Files: %w", err)
		}
	}

	// Record the app root the invoking copy belongs to (plus
	// any roots recorded before, e.g. a second install folder).
	roots := loadRoots()
	roots.add(appRoot)
	if err := saveRoots(roots.list()); err != nil {
		return fmt.Errorf("record the app folder: %w", err)
	}

	s, err := m.CreateService(serviceName, target, mgr.Config{
		DisplayName: displayName,
		Description: "Owns Ralysnd Ember's engine processes and TUN sessions.",
		StartType:   mgr.StartAutomatic,
	})
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
	// Prove the pipe answers before claiming success.
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if c, err := dialPipe(2 * time.Second); err == nil {
			c.Close()
			return nil
		}
		time.Sleep(300 * time.Millisecond)
	}
	return fmt.Errorf("the service started but its pipe did not answer within 20s")
}

func stopService(s *mgr.Service) error {
	status, err := s.Query()
	if err != nil || status.State != svc.Running {
		return nil
	}
	if _, err := s.Control(svc.Stop); err != nil {
		return err
	}
	for i := 0; i < 50; i++ {
		status, err := s.Query()
		if err != nil || status.State == svc.Stopped {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil
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
