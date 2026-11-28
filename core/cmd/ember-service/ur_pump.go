package main

// The URnetwork packet pump — REPAIR 2042, workstream SVC-UR2.
//
// The vendor SDK's DeviceLocal moves raw IP packets: the host
// feeds it packets read from a TUN adapter (SendPacket) and
// receives packets back through a callback to write to the
// adapter. The SDK states the Windows shape itself
// (device_local_ioloop.go, build !windows): "the fd loop
// assumes posix fd semantics — on windows the app-side tunnel
// pumps packets via SendPacket/AddReceivePacketCallback
// instead". The SDK's fd IoLoop is therefore never used here;
// this pump is its Windows counterpart.
//
// The SDK hands the host the interface configuration and
// expects the host to apply it (device_local.go):
//   - TunnelLocalAddress() — the IPv4 the platform assigns to
//     the TUN (a per-device random 10.x.y.h host address);
//   - TunnelLocalAddressIpv6() + TunnelLocalPrefixLengthIpv6
//     (64) — the ULA address and its prefix length, paired
//     with a ::/0 route;
//   - TunnelDnsAddressesIpv4()/Ipv6() — the DNS servers the
//     platform applies to the TUN (the SDK's upgrade-mask
//     resolver addresses; plain :53 so the SDK's UpgradeMux
//     can intercept and upgrade queries).
//
// Self-capture: the SDK's connect stack binds its own egress
// sockets to the physical interface via IP_UNICAST_IF when
// the host tells it the physical interface index
// (connect/egress.go: connect.SetEgressInterfaceIndex, "the
// binding is a no-op unless an egress index is set"). The
// pump resolves the physical index (excluding the tunnel
// adapter) and sets it BEFORE the tunnel's routes go up, and
// clears it on stop — without it the provider sessions would
// route into the tunnel they serve and blackhole, the exact
// failure the Android glue hit in 2156 (there solved by
// addDisallowedApplication; Windows has no per-app exclusion,
// so the SDK's interface pin is the mechanism).
//
// Lifecycle (driven by ur.go's manager): the pump starts only
// after the SDK itself reports an established provider
// session, and stops on disconnect, on device rebuild, and on
// service shutdown. ur.status.tunneled is the pump's own
// Running() — never inferred from the SDK's connected state.
//
// This file is the platform-neutral lifecycle logic, tested
// on Linux with fakes (ur_pump_test.go). The Wintun adapter
// itself is ur_pump_windows.go (compile-verified only; the
// runtime proof is a PC run). Off Windows urPumpOpener stays
// nil and no pump is ever created: tunneled stays false.

import (
	"errors"
	"fmt"
	"sync"
)

// urTunnelMTU is the tunnel MTU the host applies. The SDK
// carries no MTU setting of its own; 1500 is the value the
// Android glue clamps to (UrVpnService.MTU) and what the
// desktop platform interfaces default to.
const urTunnelMTU = 1500

// urPumpConfig is the interface configuration the SDK hands
// the host for one device (see the header comment). Address6
// is "" when the SDK reports no IPv6 tunnel address.
type urPumpConfig struct {
	Address4   string
	Address6   string
	PrefixLen6 int
	DNS4       []string
	DNS6       []string
	MTU        int
}

// urPumpDevice is the packet-plane slice of the SDK device.
// The real implementation is on urSDKDevice (ur_sdk.go);
// ur.go's manager type-asserts the urDevice it holds to this
// interface, so a device without a packet plane (every fake,
// and any future binding) simply never gets a pump.
type urPumpDevice interface {
	// SendPacket hands one raw IP packet (read from the TUN)
	// to the SDK. False means the SDK's route dropped it.
	SendPacket(packet []byte) bool
	// AddReceivePacketCallback registers the sink for packets
	// the SDK emits toward the TUN. The packet slice is
	// borrowed for the duration of the call only. The
	// returned function unregisters it.
	AddReceivePacketCallback(cb func(packet []byte)) (remove func())
	// SetTunnelStarted tells the SDK the platform tunnel is
	// up (adapter configured, pump running) or down.
	SetTunnelStarted(started bool)
	// SetEgressInterface pins the SDK's own egress sockets to
	// the physical interface (connect.SetEgressInterfaceIndex);
	// (0, 0) clears the pin.
	SetEgressInterface(index4, index6 uint32)
	// TunnelConfig returns the SDK's interface configuration
	// for this device.
	TunnelConfig() urPumpConfig
}

// urTunAdapter is the host TUN adapter the pump drives. The
// Windows implementation wraps a Wintun session
// (ur_pump_windows.go); tests substitute a fake.
type urTunAdapter interface {
	// Index is the adapter's interface index (used to keep
	// the SDK's egress pin off the tunnel itself).
	Index() uint32
	// ApplyConfig assigns the addresses, DNS servers, MTU
	// and default routes from cfg to the adapter.
	ApplyConfig(cfg urPumpConfig) error
	// ReadPacket blocks until a packet arrives or the
	// adapter is closed; the returned slice is owned by the
	// caller.
	ReadPacket() ([]byte, error)
	// WritePacket queues one packet for transmission. A full
	// adapter queue is an error; the pump drops the packet,
	// as any TUN does under load.
	WritePacket(packet []byte) error
	// Close tears the adapter down (session, routes,
	// addresses) and unblocks ReadPacket. Idempotent.
	Close() error
}

// urPumpOpener creates the platform adapter. Set by
// ur_pump_windows.go's init; nil on every other platform.
var urPumpOpener func() (urTunAdapter, error)

// urEgressIndex resolves the physical interface indices to
// pin the SDK's egress to, excluding the tunnel adapter.
// Set by ur_pump_windows.go's init; nil elsewhere (the pump
// then leaves the egress pin unset, (0, 0)).
var urEgressIndex func(excludeIndex uint32) (index4, index6 uint32)

var errURPumpUnavailable = errors.New("no Wintun packet pump is available in this build on this platform")

// urPump owns one adapter <-> device packet loop.
type urPump struct {
	dev    urPumpDevice
	opener func() (urTunAdapter, error)
	egress func(excludeIndex uint32) (uint32, uint32)

	mu       sync.Mutex
	adapter  urTunAdapter
	removeCb func()
	done     chan struct{}
	running  bool
}

func newURPump(dev urPumpDevice) *urPump {
	return &urPump{dev: dev, opener: urPumpOpener, egress: urEgressIndex}
}

// Start brings the adapter up and starts pumping. It is
// idempotent: starting a running pump is a no-op. Any failure
// leaves the pump fully stopped (adapter closed, egress pin
// cleared, SDK never told the tunnel started).
func (p *urPump) Start() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running {
		return nil
	}
	if p.opener == nil {
		return errURPumpUnavailable
	}
	ad, err := p.opener()
	if err != nil {
		return fmt.Errorf("ur pump: the TUN adapter could not be created: %w", err)
	}
	// From here, every failure path closes the adapter.
	cfg := p.dev.TunnelConfig()
	var idx4, idx6 uint32
	if p.egress != nil {
		idx4, idx6 = p.egress(ad.Index())
	}
	p.dev.SetEgressInterface(idx4, idx6)
	if err := ad.ApplyConfig(cfg); err != nil {
		p.dev.SetEgressInterface(0, 0)
		ad.Close()
		return fmt.Errorf("ur pump: the TUN adapter could not be configured: %w", err)
	}
	remove := p.dev.AddReceivePacketCallback(func(packet []byte) {
		// The packet is borrowed for this call; WritePacket
		// copies it into the adapter's send ring synchronously.
		// A full ring drops the packet (ordinary TUN backpressure).
		_ = ad.WritePacket(packet)
	})
	done := make(chan struct{})
	p.adapter = ad
	p.removeCb = remove
	p.done = done
	p.running = true
	go p.readLoop(ad, done)
	p.dev.SetTunnelStarted(true)
	return nil
}

// readLoop is the adapter -> device direction.
func (p *urPump) readLoop(ad urTunAdapter, done chan struct{}) {
	defer close(done)
	for {
		packet, err := ad.ReadPacket()
		if err != nil {
			p.onAdapterDeath(ad)
			return
		}
		p.dev.SendPacket(packet)
	}
}

// onAdapterDeath handles a read failure the pump did not ask
// for (Stop closes the adapter too, but it clears the fields
// first, so a death that finds itself still registered here
// is a real one): mark the pump down, tell the SDK the
// tunnel stopped, unpin the egress, and release the adapter
// so its routes and addresses go away.
func (p *urPump) onAdapterDeath(ad urTunAdapter) {
	p.mu.Lock()
	if p.adapter != ad {
		p.mu.Unlock()
		return // Stop (or a newer Start) already owns the state
	}
	remove := p.removeCb
	p.adapter = nil
	p.removeCb = nil
	p.done = nil
	p.running = false
	p.mu.Unlock()

	p.dev.SetTunnelStarted(false)
	if remove != nil {
		remove()
	}
	ad.Close()
	p.dev.SetEgressInterface(0, 0)
}

// Stop tears the pump down: the SDK is told the tunnel
// stopped, the receive callback is unregistered, the adapter
// is closed (which unblocks the read loop), and the egress
// pin is cleared. Idempotent; safe on a pump that never
// started or whose adapter already died.
func (p *urPump) Stop() {
	p.mu.Lock()
	ad, remove, done := p.adapter, p.removeCb, p.done
	p.adapter, p.removeCb, p.done = nil, nil, nil
	p.running = false
	p.mu.Unlock()
	if ad == nil {
		return
	}
	p.dev.SetTunnelStarted(false)
	if remove != nil {
		remove()
	}
	ad.Close()
	p.dev.SetEgressInterface(0, 0)
	if done != nil {
		<-done
	}
}

// Running reports whether the pump is actually moving
// packets (adapter up, read loop alive). This is what
// ur.status.tunneled carries.
func (p *urPump) Running() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.running
}
