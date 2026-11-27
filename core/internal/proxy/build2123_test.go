package proxy

// Build 2123, audit F-01 gap 1 (evidence completion):
//   - pool-absorbed slot failures are counted through
//     the controller's established-failure counter — a
//     request served by a sibling slot used to leave the
//     dead slot's failure counted nowhere;
//   - mid-stream tunnel deaths (Read/Write errors after
//     a successful open) are counted once per tunnel —
//     they used to move only the byte counters.

import (
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
)

func TestBuild2123PoolAbsorbedFailureIsCounted(t *testing.T) {
	slotErr := errors.New("dial tcp: connection refused")
	create := func() (proxySession, error) {
		return &fakeProxySession{}, nil
	}
	pool, err := newProxySessionPool(2, create)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()
	c := &Controller{}
	pool.noteAbsorbed = c.noteEstablishedFailure
	// Slot 0 is the first open's start slot (round-robin
	// begins at 0); construction is parallel, so the
	// failure is planted on the built slot directly
	// rather than by create-call order.
	pool.sessions[0].session.(*fakeProxySession).openErr = slotErr

	conn, err := pool.OpenTunnel("example.org:443")
	if err != nil {
		t.Fatalf("open: %v (the healthy slot must serve)", err)
	}
	_ = conn.Close()
	// The dead slot's failure reached the established
	// counter even though the open SUCCEEDED.
	if got := c.establishedFailureSummary(); got == "none" {
		t.Fatalf("established summary = %q, want the absorbed failure counted", got)
	}
}

func TestBuild2123PoolUnhealthySlotRetirementIsCounted(t *testing.T) {
	create := func() (proxySession, error) {
		return &fakeProxySession{}, nil
	}
	pool, err := newProxySessionPool(2, create)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()
	var noted []error
	pool.noteAbsorbed = func(err error) { noted = append(noted, err) }

	// The keepalive's verdict on slot 0 (start slot of the
	// first round-robin open): unhealthy before any open.
	pool.sessions[0].mu.Lock()
	pool.sessions[0].healthy = false
	pool.sessions[0].mu.Unlock()

	conn, err := pool.OpenTunnel("example.org:443")
	if err != nil {
		t.Fatalf("open: %v (slot 1 must serve)", err)
	}
	_ = conn.Close()
	if len(noted) != 1 || !errors.Is(noted[0], errProxySessionUnhealthy) {
		t.Fatalf("noted = %v, want exactly the unhealthy verdict", noted)
	}
}

func TestBuild2123PoolWithoutHookStaysSilentAndSafe(t *testing.T) {
	// Pools in older tests never install the hook; the
	// absorbed path must be a no-op, not a panic.
	var calls atomic.Int32
	create := func() (proxySession, error) {
		if calls.Add(1) == 1 {
			return &fakeProxySession{openErr: errors.New("boom")}, nil
		}
		return &fakeProxySession{}, nil
	}
	pool, err := newProxySessionPool(2, create)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()
	conn, err := pool.OpenTunnel("example.org:443")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	_ = conn.Close()
}

type scriptedStreamConn struct {
	net.Conn
	readErr  error
	writeErr error
}

func (s *scriptedStreamConn) Read(p []byte) (int, error)  { return 0, s.readErr }
func (s *scriptedStreamConn) Write(p []byte) (int, error) { return 0, s.writeErr }
func (s *scriptedStreamConn) Close() error                { return nil }

func newScriptedPipe(t *testing.T, readErr, writeErr error) *scriptedStreamConn {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() { _ = a.Close(); _ = b.Close() })
	return &scriptedStreamConn{Conn: a, readErr: readErr, writeErr: writeErr}
}

func TestBuild2123MidStreamDeathCountedOnce(t *testing.T) {
	reset := errors.New("read tcp: connection reset by peer")
	var notes atomic.Int32
	mtc := &managedTunnelConn{
		Conn:        newScriptedPipe(t, reset, nil),
		noteFailure: func(error) { notes.Add(1) },
	}
	buf := make([]byte, 16)
	for i := 0; i < 3; i++ {
		if _, err := mtc.Read(buf); err == nil {
			t.Fatalf("read %d: want the reset error", i)
		}
	}
	if got := notes.Load(); got != 1 {
		t.Fatalf("notes = %d, want exactly 1 per tunnel", got)
	}
	// A write failure on a fresh tunnel counts too.
	var wNotes atomic.Int32
	wtc := &managedTunnelConn{
		Conn:        newScriptedPipe(t, nil, reset),
		noteFailure: func(error) { wNotes.Add(1) },
	}
	if _, err := wtc.Write(buf); err == nil {
		t.Fatalf("write: want the reset error")
	}
	if got := wNotes.Load(); got != 1 {
		t.Fatalf("write notes = %d, want 1", got)
	}
}

func TestBuild2123MidStreamCleanEndingsNotCounted(t *testing.T) {
	var notes atomic.Int32
	note := func(error) { notes.Add(1) }
	// A clean EOF is a normal ending.
	etc := &managedTunnelConn{
		Conn:        newScriptedPipe(t, io.EOF, nil),
		noteFailure: note,
	}
	if _, err := etc.Read(make([]byte, 4)); !errors.Is(err, io.EOF) {
		t.Fatalf("read: want EOF, got %v", err)
	}
	// An error surfacing after a local Close is the close
	// unwinding the stream, not a death.
	ctc := &managedTunnelConn{
		Conn:        newScriptedPipe(t, errors.New("use of closed connection"), nil),
		noteFailure: note,
	}
	_ = ctc.Close()
	_, _ = ctc.Read(make([]byte, 4))
	if got := notes.Load(); got != 0 {
		t.Fatalf("notes = %d, want 0 for clean endings", got)
	}
}
