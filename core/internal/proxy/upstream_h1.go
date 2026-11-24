package proxy

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
	"github.com/armanlife/firefox-vpn-client/core/internal/resolver"
)

// HTTP/1.1 upstream sessions (build 2105, transport "h1").
//
// Where the H2 and H3 sessions multiplex every site connection over
// ONE long-lived connection, an H1 session opens a fresh TCP+TLS
// connection to the Mozilla proxy for every tunnel and speaks one
// HTTP/1.1 CONNECT on it. That is the trade armanlife's v1.0.12
// offers and the reason this transport exists: on a network that
// slows or cuts long-lived HTTP/2 connections, there is no long
// connection to cut. On a healthy network it is strictly slower
// per connection (a full TCP+TLS handshake per site) and opens
// more sockets.
//
// Whether Mozilla's edge accepts HTTP/1.1 CONNECT with a Bearer
// Proxy-Authorization from this client cannot be proven from this
// tree — nothing here spoke it before. The session is written to
// the same wire shape Firefox itself uses (CONNECT with the pass
// as a Bearer token and Firefox's User-Agent); the owner's device
// test is the acceptance, exactly as the build was scoped.
//
// Two consequences of the per-connection shape, both deliberate:
//
//   - Construction still dials once (and keeps that connection for
//     the first tunnel): NewController treats a factory error as
//     "this server does not answer", which is what the failover
//     counts. A factory that dialed nothing would report every
//     dead server as connected.
//   - Open errors are NOT fed to a session-failure tracker. The
//     tracker infers a sick SHARED session from failing targets;
//     here there is no shared session to be sick, so an ordinary
//     per-site failure stays a per-site failure and never triggers
//     a rebuild or a pass renewal.

var errProxyHTTP1Unavailable = errors.New("proxy did not negotiate HTTP/1.1")

type h1ProxySession struct {
	proxyHost string
	timeout   time.Duration

	// ctx bounds every dial the session makes; Close cancels it, so
	// a dial in flight while the controller closes cannot hand out
	// a live connection from a closed session (the H2/H3 Close gets
	// this by killing the shared connection).
	ctx    context.Context
	cancel context.CancelFunc

	tokenMu sync.RWMutex
	token   string

	mu     sync.Mutex
	held   net.Conn // the construction probe, kept for the first tunnel
	closed bool
}

func newH1ProxySession(proxyURL *url.URL, token string, timeout time.Duration) (*h1ProxySession, error) {
	session, err := dialH1ProxySession(proxyURL, token, timeout)
	if err != nil {
		return nil, err
	}
	logx.Info("upstream HTTP/1.1 session established proxy=%s", session.proxyHost)
	return session, nil
}

// dialH1ProxySession dials and TLS-handshakes one connection to the
// proxy, proving the server answers before NewController reports
// success; the connection is kept for the first OpenTunnel.
func dialH1ProxySession(proxyURL *url.URL, token string, timeout time.Duration) (*h1ProxySession, error) {
	proxyHost := proxyURL.Host
	if proxyURL.Port() == "" {
		proxyHost = proxyURL.Hostname() + ":443"
	}
	session := &h1ProxySession{proxyHost: proxyHost, timeout: timeout, token: token}
	session.ctx, session.cancel = context.WithCancel(context.Background())
	conn, err := session.dial()
	if err != nil {
		session.cancel()
		return nil, err
	}
	session.held = conn
	return session, nil
}

// dial opens one TLS connection to the proxy with ALPN http/1.1.
// The timeout covers resolving, connecting, and the handshake, as
// in the H2 dial.
func (s *h1ProxySession) dial() (net.Conn, error) {
	dialCtx, cancelDial := s.ctx, context.CancelFunc(func() {})
	if s.timeout > 0 {
		dialCtx, cancelDial = context.WithTimeout(s.ctx, s.timeout)
	}
	defer cancelDial()
	raw, err := resolver.Dial(dialCtx, "tcp", s.proxyHost)
	if err != nil {
		return nil, err
	}
	proxyTLS := tls.Client(raw, &tls.Config{
		RootCAs:    upstreamRoots.Load(),
		ServerName: urlHostname(s.proxyHost),
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"http/1.1"},
	})
	if err := proxyTLS.HandshakeContext(dialCtx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	// A server that answers with a different ALPN than the one
	// offered is not going to speak HTTP/1.1 CONNECT; no ALPN at
	// all is the common HTTP/1.1 case and is fine.
	if negotiated := proxyTLS.ConnectionState().NegotiatedProtocol; negotiated != "" && negotiated != "http/1.1" {
		_ = proxyTLS.Close()
		return nil, errProxyHTTP1Unavailable
	}
	return proxyTLS, nil
}

func urlHostname(proxyHost string) string {
	host, _, err := net.SplitHostPort(proxyHost)
	if err != nil {
		return proxyHost
	}
	return host
}

// takeConn returns the held construction connection for the first
// tunnel and a fresh dial for every later one; the second result
// says whether the connection is the held one.
func (s *h1ProxySession) takeConn() (net.Conn, bool, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil, false, net.ErrClosed
	}
	if s.held != nil {
		conn := s.held
		s.held = nil
		s.mu.Unlock()
		return conn, true, nil
	}
	s.mu.Unlock()
	conn, err := s.dial()
	if err != nil {
		if errors.Is(err, errProxyHTTP1Unavailable) {
			// A property of the server, identical on every
			// dial — not one tunnel's accident. (Construction
			// normally catches it first; if it ever arises
			// later it must stay a session failure.)
			return nil, false, err
		}
		// A per-tunnel dial failure is this tunnel's alone (see
		// errPerTunnelFailure): unmarked, the controller would
		// read it as a session failure and rebuild — escalating
		// to a fresh Guardian pass — over one lost handshake.
		return nil, false, fmt.Errorf("%w: %w", errPerTunnelFailure, err)
	}
	return conn, false, nil
}

func (s *h1ProxySession) OpenTunnel(authority string) (net.Conn, error) {
	conn, held, err := s.takeConn()
	if err != nil {
		return nil, err
	}
	tunnel, err := s.connect(conn, authority)
	if err != nil && held && isDeadConnErr(err) {
		// The construction connection sat idle since the session
		// was built; if the proxy or the network dropped it
		// meanwhile, one fresh dial is the honest retry — it is
		// what any later OpenTunnel would have done anyway. A real
		// proxy answer (an HTTP error) or a timeout is never
		// retried: those describe the target or the proxy, not a
		// stale socket.
		_ = conn.Close()
		conn, err = s.dial()
		if err != nil {
			if errors.Is(err, errProxyHTTP1Unavailable) {
				return nil, err
			}
			return nil, fmt.Errorf("%w: %w", errPerTunnelFailure, err)
		}
		tunnel, err = s.connect(conn, authority)
	}
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if s.ctx.Err() != nil {
		// Close landed while this tunnel was being built: a
		// closed session hands out no tunnels (the H2 session
		// gets this by killing its shared connection).
		_ = tunnel.Close()
		return nil, net.ErrClosed
	}
	return tunnel, nil
}

// isDeadConnErr reports whether err says the connection itself
// died (EOF, reset, broken pipe) rather than anything about the
// proxy's answer or the target's pace.
func isDeadConnErr(err error) bool {
	var httpErr *proxyConnectHTTPError
	if errors.As(err, &httpErr) {
		return false
	}
	var timeoutErr *tunnelOpenTimeoutError
	if errors.As(err, &timeoutErr) {
		return false
	}
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE)
}

// connect speaks the one HTTP/1.1 CONNECT on conn and returns the
// tunnel when the proxy answers 2xx.
func (s *h1ProxySession) connect(conn net.Conn, authority string) (net.Conn, error) {
	if s.timeout > 0 {
		_ = conn.SetDeadline(time.Now().Add(s.timeout))
		defer func() { _ = conn.SetDeadline(time.Time{}) }()
	}
	var request strings.Builder
	fmt.Fprintf(&request, "CONNECT %s HTTP/1.1\r\n", authority)
	fmt.Fprintf(&request, "Host: %s\r\n", authority)
	fmt.Fprintf(&request, "Proxy-Authorization: Bearer %s\r\n", s.bearerToken())
	// As Firefox's CONNECT; Go would otherwise name itself.
	fmt.Fprintf(&request, "User-Agent: %s\r\n", controlplane.FirefoxUserAgent())
	request.WriteString("\r\n")
	if _, err := io.WriteString(conn, request.String()); err != nil {
		return nil, s.openErr(err)
	}
	req, err := http.NewRequest(http.MethodConnect, "http://"+authority, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), req)
	if err != nil {
		return nil, s.openErr(err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		_ = resp.Body.Close()
		return nil, &proxyConnectHTTPError{
			statusCode: resp.StatusCode,
			status:     resp.Status,
			body:       strings.TrimSpace(string(body)),
		}
	}
	// A 2xx answer to CONNECT makes the rest of the stream the
	// tunnel: resp.Body reads it (including anything the response
	// reader already buffered), conn carries the writes.
	return &h1TunnelConn{Conn: conn, reader: resp.Body}, nil
}

// openErr classifies an error from the CONNECT exchange itself
// (the dial that produced the connection is classified by the
// caller as before). A timeout here means the proxy took the
// connection and the target did not answer in time — the shape
// H2 reports from roundTripWithOpenTimeout. It must surface as a
// tunnelOpenTimeoutError: anything else is read upstream as a
// session failure, and one slow target would rebuild the session
// and strike a healthy server.
func (s *h1ProxySession) openErr(err error) error {
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return &tunnelOpenTimeoutError{timeout: s.timeout}
	}
	return err
}

// h1TunnelConn is a tunnel whose reads come from the CONNECT
// response body and whose writes go to the connection directly.
type h1TunnelConn struct {
	net.Conn
	reader io.Reader
}

func (c *h1TunnelConn) Read(b []byte) (int, error) { return c.reader.Read(b) }

// CloseWrite half-closes the tunnel's write side. It is
// WEAKER than the H2/H3 tunnel's stream end: the embedded
// connection is a *tls.Conn, whose CloseWrite only emits a TLS
// close_notify (it does not half-close the TCP connection), so
// whether the target sees EOF depends on the proxy edge acting
// on the close_notify. It is what HTTP/1.1 over TLS offers;
// protocols that signal end-of-input and wait for the answer
// depend on it, and without it the relay's half-close drain
// runs out its full timeout before force-closing. There is
// deliberately no CloseRead: *tls.Conn has none, and a method
// that can only ever no-op would lie to the relay's checks.
func (c *h1TunnelConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

func (s *h1ProxySession) bearerToken() string {
	s.tokenMu.RLock()
	defer s.tokenMu.RUnlock()
	return s.token
}

func (s *h1ProxySession) UpdateToken(token string) error {
	if strings.TrimSpace(token) == "" {
		return fmt.Errorf("empty proxy session token")
	}
	s.tokenMu.Lock()
	s.token = token
	s.tokenMu.Unlock()
	return nil
}

// Close refuses new tunnels and drops the held construction
// connection when no tunnel took it. Tunnels already handed out
// are separate connections owned by their callers — unlike the
// shared H2/H3 connection, closing the session does not cut them;
// the controller closes them with the client connections that
// carry them.
func (s *h1ProxySession) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	s.cancel()
	if s.held != nil {
		err := s.held.Close()
		s.held = nil
		return err
	}
	return nil
}
