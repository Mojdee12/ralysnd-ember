package main

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// ---- fake adapter ---------------------------------------------------

type fakePumpAdapter struct {
	mu       sync.Mutex
	idx      uint32
	cfg      *urPumpConfig
	applyErr error
	written  [][]byte
	readCh   chan []byte
	errCh    chan error
	closed   bool
	closeCh  chan struct{}
	once     sync.Once
}

func newFakePumpAdapter(idx uint32) *fakePumpAdapter {
	return &fakePumpAdapter{
		idx:     idx,
		readCh:  make(chan []byte, 16),
		errCh:   make(chan error, 1),
		closeCh: make(chan struct{}),
	}
}

func (a *fakePumpAdapter) Index() uint32 { return a.idx }

func (a *fakePumpAdapter) ApplyConfig(cfg urPumpConfig) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	c := cfg
	a.cfg = &c
	return a.applyErr
}

func (a *fakePumpAdapter) ReadPacket() ([]byte, error) {
	select {
	case p := <-a.readCh:
		return p, nil
	case err := <-a.errCh:
		return nil, err
	case <-a.closeCh:
		return nil, errors.New("fake adapter closed")
	}
}

func (a *fakePumpAdapter) WritePacket(p []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return errors.New("fake adapter closed")
	}
	a.written = append(a.written, append([]byte(nil), p...))
	return nil
}

func (a *fakePumpAdapter) Close() error {
	a.once.Do(func() {
		a.mu.Lock()
		a.closed = true
		a.mu.Unlock()
		close(a.closeCh)
	})
	return nil
}

func (a *fakePumpAdapter) isClosed() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.closed
}

func (a *fakePumpAdapter) writtenPackets() [][]byte {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([][]byte(nil), a.written...)
}

// ---- fake pump device (urDevice + urPumpDevice) ---------------------

type fakePumpDevice struct {
	fakeURDevice

	mu           sync.Mutex
	sent         [][]byte
	cb           func([]byte)
	cbRemoved    bool
	tunnelStates []bool
	egress       [][2]uint32
	cfg          urPumpConfig
}

// Connect/Connected override the embedded fakeURDevice pair
// in one respect: once the destination is removed, the SDK
// reports no provider session on later polls too (the base
// fake's poll counter would flip it back to connected).
func (d *fakePumpDevice) Connect(country string) error {
	d.fakeURDevice.mu.Lock()
	d.fakeURDevice.disconnected = false
	d.fakeURDevice.mu.Unlock()
	return d.fakeURDevice.Connect(country)
}

func (d *fakePumpDevice) Connected() (bool, string) {
	d.fakeURDevice.mu.Lock()
	disconnected := d.fakeURDevice.disconnected
	d.fakeURDevice.mu.Unlock()
	if disconnected {
		return false, ""
	}
	return d.fakeURDevice.Connected()
}

func (d *fakePumpDevice) SendPacket(p []byte) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.sent = append(d.sent, append([]byte(nil), p...))
	return true
}

func (d *fakePumpDevice) AddReceivePacketCallback(cb func([]byte)) func() {
	d.mu.Lock()
	d.cb = cb
	d.mu.Unlock()
	return func() {
		d.mu.Lock()
		defer d.mu.Unlock()
		d.cb = nil
		d.cbRemoved = true
	}
}

func (d *fakePumpDevice) SetTunnelStarted(started bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.tunnelStates = append(d.tunnelStates, started)
}

func (d *fakePumpDevice) SetEgressInterface(i4, i6 uint32) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.egress = append(d.egress, [2]uint32{i4, i6})
}

func (d *fakePumpDevice) TunnelConfig() urPumpConfig { return d.cfg }

// emitReceive delivers a device -> adapter packet through the
// registered callback, as the SDK would.
func (d *fakePumpDevice) emitReceive(p []byte) {
	d.mu.Lock()
	cb := d.cb
	d.mu.Unlock()
	if cb != nil {
		cb(p)
	}
}

func (d *fakePumpDevice) sentPackets() [][]byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([][]byte(nil), d.sent...)
}

func (d *fakePumpDevice) tunnelStateLog() []bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]bool(nil), d.tunnelStates...)
}

func (d *fakePumpDevice) egressLog() [][2]uint32 {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([][2]uint32(nil), d.egress...)
}

// withPumpGlobals swaps the platform pump hooks for the test's
// duration (the real ones are registered by ur_pump_windows.go
// on Windows only; on Linux both are nil by default).
func withPumpGlobals(t *testing.T, opener func() (urTunAdapter, error), egress func(uint32) (uint32, uint32)) {
	t.Helper()
	oldOpener, oldEgress := urPumpOpener, urEgressIndex
	urPumpOpener, urEgressIndex = opener, egress
	t.Cleanup(func() { urPumpOpener, urEgressIndex = oldOpener, oldEgress })
}

// ---- lifecycle --------------------------------------------------------

func TestURPumpStartStopLifecycle(t *testing.T) {
	ad := newFakePumpAdapter(7)
	dev := &fakePumpDevice{cfg: urPumpConfig{Address4: "10.1.2.3", DNS4: []string{"1.2.3.4"}, MTU: 1500}}
	p := &urPump{
		dev:    dev,
		opener: func() (urTunAdapter, error) { return ad, nil },
		egress: func(exclude uint32) (uint32, uint32) {
			if exclude != 7 {
				t.Errorf("egress exclusion = %d; want the adapter index 7", exclude)
			}
			return 3, 0
		},
	}
	if err := p.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !p.Running() {
		t.Fatal("pump must be running after Start")
	}
	if ad.cfg == nil || ad.cfg.Address4 != "10.1.2.3" {
		t.Fatalf("adapter config = %+v; want the device's TunnelConfig applied", ad.cfg)
	}
	if got := dev.egressLog(); len(got) != 1 || got[0] != [2]uint32{3, 0} {
		t.Fatalf("egress pin = %v; want [[3 0]] set before the routes went up", got)
	}
	if got := dev.tunnelStateLog(); len(got) != 1 || !got[0] {
		t.Fatalf("tunnelStarted log = %v; want [true]", got)
	}

	// adapter -> device
	ad.readCh <- []byte{0x45, 0x01}
	deadline := time.Now().Add(2 * time.Second)
	for len(dev.sentPackets()) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := dev.sentPackets(); len(got) != 1 || got[0][0] != 0x45 {
		t.Fatalf("device received %v; want the adapter's packet", got)
	}
	// device -> adapter
	dev.emitReceive([]byte{0x45, 0x02})
	if got := ad.writtenPackets(); len(got) != 1 || got[0][1] != 0x02 {
		t.Fatalf("adapter written = %v; want the device's packet", got)
	}

	// Start is idempotent while running.
	if err := p.Start(); err != nil {
		t.Fatalf("second Start: %v", err)
	}

	p.Stop()
	if p.Running() {
		t.Fatal("pump must not be running after Stop")
	}
	if !ad.isClosed() {
		t.Fatal("Stop must close the adapter")
	}
	if got := dev.tunnelStateLog(); len(got) != 2 || got[1] {
		t.Fatalf("tunnelStarted log = %v; want [true false]", got)
	}
	if got := dev.egressLog(); len(got) != 2 || got[1] != [2]uint32{0, 0} {
		t.Fatalf("egress log = %v; want the pin cleared on stop", got)
	}
	if !dev.cbRemoved {
		t.Fatal("Stop must unregister the receive callback")
	}
	// Stop is idempotent.
	p.Stop()
}

func TestURPumpStartOpenFailure(t *testing.T) {
	dev := &fakePumpDevice{}
	p := &urPump{
		dev:    dev,
		opener: func() (urTunAdapter, error) { return nil, errors.New("no wintun") },
	}
	if err := p.Start(); err == nil {
		t.Fatal("Start must fail when the adapter cannot be created")
	}
	if p.Running() {
		t.Fatal("a failed Start must not leave the pump running")
	}
	if got := dev.tunnelStateLog(); len(got) != 0 {
		t.Fatalf("the SDK must never be told the tunnel started: %v", got)
	}
	if got := dev.egressLog(); len(got) != 0 {
		t.Fatalf("the egress pin must not be touched when no adapter exists: %v", got)
	}
}

func TestURPumpStartConfigFailure(t *testing.T) {
	ad := newFakePumpAdapter(7)
	ad.applyErr = errors.New("netsh refused")
	dev := &fakePumpDevice{}
	p := &urPump{
		dev:    dev,
		opener: func() (urTunAdapter, error) { return ad, nil },
		egress: func(uint32) (uint32, uint32) { return 3, 0 },
	}
	if err := p.Start(); err == nil {
		t.Fatal("Start must fail when the adapter cannot be configured")
	}
	if p.Running() {
		t.Fatal("a failed Start must not leave the pump running")
	}
	if !ad.isClosed() {
		t.Fatal("a failed Start must close the adapter it created")
	}
	if got := dev.egressLog(); len(got) != 2 || got[1] != [2]uint32{0, 0} {
		t.Fatalf("egress log = %v; want the pin set then cleared on the failure path", got)
	}
	if got := dev.tunnelStateLog(); len(got) != 0 {
		t.Fatalf("the SDK must never be told the tunnel started: %v", got)
	}
}

func TestURPumpUnavailableWithoutOpener(t *testing.T) {
	p := &urPump{dev: &fakePumpDevice{}}
	if err := p.Start(); !errors.Is(err, errURPumpUnavailable) {
		t.Fatalf("Start without an opener = %v; want errURPumpUnavailable", err)
	}
}

func TestURPumpAdapterDeathMarksDown(t *testing.T) {
	ad := newFakePumpAdapter(7)
	dev := &fakePumpDevice{}
	p := &urPump{
		dev:    dev,
		opener: func() (urTunAdapter, error) { return ad, nil },
		egress: func(uint32) (uint32, uint32) { return 3, 0 },
	}
	if err := p.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	ad.errCh <- errors.New("adapter vanished")
	deadline := time.Now().Add(2 * time.Second)
	for p.Running() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if p.Running() {
		t.Fatal("an adapter death must mark the pump down")
	}
	if got := dev.tunnelStateLog(); len(got) != 2 || got[1] {
		t.Fatalf("tunnelStarted log = %v; want [true false] after the death", got)
	}
	if got := dev.egressLog(); len(got) != 2 || got[1] != [2]uint32{0, 0} {
		t.Fatalf("egress log = %v; want the pin cleared after the death", got)
	}
	if !ad.isClosed() {
		t.Fatal("a dead adapter must be closed so its routes are released")
	}
	// Stop after a death is a clean no-op.
	p.Stop()
}

// ---- manager integration ----------------------------------------------

func TestURManagerConnectStartsPumpAndReportsTunneled(t *testing.T) {
	ad := newFakePumpAdapter(7)
	withPumpGlobals(t,
		func() (urTunAdapter, error) { return ad, nil },
		func(uint32) (uint32, uint32) { return 3, 0 })

	dev := &fakePumpDevice{cfg: urPumpConfig{Address4: "10.1.2.3", MTU: 1500}}
	dev.connectsToUp = 1
	dev.country = "Netherlands"
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	st, err := m.connect(urConnectParams{APIKey: "urn_key"})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if !st.Connected || !st.Tunneled {
		t.Fatalf("status after connect = %+v; want connected AND tunneled (the pump is running)", st)
	}
	st, err = m.disconnect()
	if err != nil {
		t.Fatalf("disconnect: %v", err)
	}
	if st.Tunneled {
		t.Fatal("tunneled must drop on disconnect")
	}
	if !ad.isClosed() {
		t.Fatal("disconnect must stop the pump (adapter closed)")
	}
}

func TestURManagerConnectFailsWhenPumpFails(t *testing.T) {
	withPumpGlobals(t,
		func() (urTunAdapter, error) { return nil, errors.New("no wintun.dll") },
		nil)

	dev := &fakePumpDevice{}
	dev.connectsToUp = 1
	m := newTestURManager(
		func(jwt string) (urDevice, error) { return dev, nil },
		okExchange(fakeJWT(time.Now().Add(time.Hour)), nil),
	)
	if _, err := m.connect(urConnectParams{APIKey: "urn_key"}); err == nil {
		t.Fatal("a pump that cannot start must fail the connect, not fake a tunneled session")
	}
	if !dev.disconnected {
		t.Fatal("a pump-failed connect must remove the SDK destination again")
	}
	if st := m.status(); st.Connected || st.Tunneled {
		t.Fatalf("status after a pump-failed connect = %+v; want neither connected nor tunneled", st)
	}
}
