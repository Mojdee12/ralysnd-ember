package main

// The Windows Wintun adapter behind ur_pump.go's urTunAdapter
// — REPAIR 2042, workstream SVC-UR2.
//
// The adapter is created with golang.zx2c4.com/wintun, which
// loads wintun.dll by name; the DLL must sit beside
// ember-service.exe at runtime (the fetch script stages it
// into tools\sidecars\core\ and the build copies that folder
// into the app's core\ folder, next to the service — the same
// pattern as lanternd's own copy).
//
// Interface configuration is applied with netsh (the service
// runs as LocalSystem): the SDK's tunnel address as a /32
// host address, its DNS servers on the adapter, MTU, and the
// default route as the 0.0.0.0/1 + 128.0.0.0/1 pair (and
// ::/1 + 8000::/1 for IPv6) so the pre-existing default route
// is never deleted or fought over metrics — the
// wireguard-windows pattern. Closing the adapter removes its
// addresses and routes with it.
//
// COMPILE-VERIFIED ONLY: nothing here has run on Windows yet.
// The first PC run is the proof (adapter up, netsh accepted,
// traffic flowing) — see the SVC-UR2 report.

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
)

// urAdapterName is the Wintun adapter's name — distinct from
// every other engine's adapter (the TUN bridge's, Lantern's),
// so the UR pump never opens or disturbs a sibling's adapter.
const urAdapterName = "Ralysnd Ember UR"

const urWintunRingCapacity = 0x800000 // 8 MiB, the wintun package's customary session ring

func init() {
	urPumpOpener = openURWintunAdapter
	urEgressIndex = urPhysicalEgressIndex
}

type urWintunAdapter struct {
	adapter *wintun.Adapter
	session wintun.Session
	index   uint32

	writeMu   sync.Mutex // Wintun send allocation is not goroutine-safe
	closed    atomic.Bool
	closeOnce sync.Once
}

func openURWintunAdapter() (urTunAdapter, error) {
	// Reuse a same-named adapter left behind by an unclean
	// shutdown before creating a second one.
	adapter, err := wintun.OpenAdapter(urAdapterName)
	if err != nil {
		adapter, err = wintun.CreateAdapter(urAdapterName, "Ralysnd Ember", nil)
		if err != nil {
			return nil, fmt.Errorf("wintun adapter %q: %w (is wintun.dll beside the service?)", urAdapterName, err)
		}
	}
	session, err := adapter.StartSession(urWintunRingCapacity)
	if err != nil {
		adapter.Close()
		return nil, fmt.Errorf("wintun session on %q: %w", urAdapterName, err)
	}
	a := &urWintunAdapter{adapter: adapter, session: session}
	// The adapter can take a moment to surface in the
	// interface list; its index only feeds the egress
	// exclusion, so a miss degrades to 0, never a failure.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if ifs, err := net.Interfaces(); err == nil {
			for _, ifc := range ifs {
				if ifc.Name == urAdapterName {
					a.index = uint32(ifc.Index)
					return a, nil
				}
			}
		}
		if time.Now().After(deadline) {
			return a, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (a *urWintunAdapter) Index() uint32 { return a.index }

func urNetsh(args ...string) error {
	out, err := exec.Command("netsh", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("netsh %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *urWintunAdapter) ApplyConfig(cfg urPumpConfig) error {
	name := urAdapterName
	if cfg.Address4 != "" {
		// The SDK's address is a single host address (a
		// per-device random 10.x.y.h): assign it as a /32 and
		// let the explicit routes below do all forwarding.
		if err := urNetsh("interface", "ipv4", "set", "address",
			"name="+name, "source=static", "address="+cfg.Address4,
			"mask=255.255.255.255", "gateway=none"); err != nil {
			return err
		}
		if err := urNetsh("interface", "ipv4", "set", "subinterface",
			name, "mtu="+fmt.Sprint(cfg.MTU), "store=active"); err != nil {
			return err
		}
		for i, dns := range cfg.DNS4 {
			if i == 0 {
				if err := urNetsh("interface", "ipv4", "set", "dnsservers",
					"name="+name, "source=static", "address="+dns,
					"register=primary", "validate=no"); err != nil {
					return err
				}
			} else {
				if err := urNetsh("interface", "ipv4", "add", "dnsservers",
					"name="+name, "address="+dns, "index="+fmt.Sprint(i+1),
					"validate=no"); err != nil {
					return err
				}
			}
		}
		// The split-default pair: together 0.0.0.0/0, but
		// neither half overrides the machine's existing
		// default route entry.
		for _, prefix := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
			if err := urNetsh("interface", "ipv4", "add", "route",
				"prefix="+prefix, "interface="+name, "store=active"); err != nil {
				return err
			}
		}
	}
	if cfg.Address6 != "" {
		// The SDK pairs its ULA address with prefix length 64
		// (TunnelLocalPrefixLengthIpv6), which is also netsh's
		// default for a set address, so it is not restated.
		if err := urNetsh("interface", "ipv6", "set", "address",
			"interface="+name, "address="+cfg.Address6); err != nil {
			return err
		}
		if err := urNetsh("interface", "ipv6", "set", "subinterface",
			name, "mtu="+fmt.Sprint(cfg.MTU), "store=active"); err != nil {
			return err
		}
		for i, dns := range cfg.DNS6 {
			if i == 0 {
				if err := urNetsh("interface", "ipv6", "set", "dnsservers",
					"interface="+name, "source=static", "address="+dns,
					"register=primary", "validate=no"); err != nil {
					return err
				}
			} else {
				if err := urNetsh("interface", "ipv6", "add", "dnsservers",
					"interface="+name, "address="+dns, "index="+fmt.Sprint(i+1),
					"validate=no"); err != nil {
					return err
				}
			}
		}
		for _, prefix := range []string{"::/1", "8000::/1"} {
			if err := urNetsh("interface", "ipv6", "add", "route",
				"prefix="+prefix, "interface="+name, "store=active"); err != nil {
				return err
			}
		}
	}
	return nil
}

// ReadPacket blocks until a packet is available, copying it
// out of the session ring before releasing the slot. The wait
// wakes every 250 ms to notice Close on a quiet link.
func (a *urWintunAdapter) ReadPacket() ([]byte, error) {
	for {
		if a.closed.Load() {
			return nil, fmt.Errorf("ur pump: the Wintun adapter is closed")
		}
		packet, err := a.session.ReceivePacket()
		if err == nil {
			out := make([]byte, len(packet))
			copy(out, packet)
			a.session.ReleaseReceivePacket(packet)
			return out, nil
		}
		if err != windows.ERROR_NO_MORE_ITEMS {
			return nil, fmt.Errorf("ur pump: Wintun receive: %w", err)
		}
		windows.WaitForSingleObject(a.session.ReadWaitEvent(), 250)
	}
}

func (a *urWintunAdapter) WritePacket(packet []byte) error {
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	if a.closed.Load() {
		return fmt.Errorf("ur pump: the Wintun adapter is closed")
	}
	buf, err := a.session.AllocateSendPacket(len(packet))
	if err != nil {
		// ERROR_BUFFER_OVERFLOW when the ring is full: the
		// pump treats it as a drop, like any TUN under load.
		return fmt.Errorf("ur pump: Wintun send allocation: %w", err)
	}
	copy(buf, packet)
	a.session.SendPacket(buf)
	return nil
}

func (a *urWintunAdapter) Close() error {
	a.closeOnce.Do(func() {
		a.closed.Store(true)
		a.session.End()
		a.adapter.Close()
	})
	return nil
}

// urPhysicalEgressIndex finds the machine's physical
// interface indices for the SDK's egress pin: the first up,
// non-loopback interface other than the tunnel adapter that
// holds a global unicast address of each family. A family
// with no such interface stays 0 (unpinned), exactly as
// connect.SetEgressInterfaceIndex documents.
func urPhysicalEgressIndex(excludeIndex uint32) (uint32, uint32) {
	ifs, err := net.Interfaces()
	if err != nil {
		return 0, 0
	}
	var idx4, idx6 uint32
	for _, ifc := range ifs {
		if uint32(ifc.Index) == excludeIndex || ifc.Flags&net.FlagUp == 0 ||
			ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || !ipNet.IP.IsGlobalUnicast() {
				continue
			}
			if ipNet.IP.To4() != nil {
				if idx4 == 0 {
					idx4 = uint32(ifc.Index)
				}
			} else if idx6 == 0 {
				idx6 = uint32(ifc.Index)
			}
		}
		if idx4 != 0 && idx6 != 0 {
			break
		}
	}
	return idx4, idx6
}
