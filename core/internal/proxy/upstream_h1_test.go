package proxy

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// Build 2105: the HTTP/1.1 upstream session against a local fixture
// proxy that speaks raw HTTP/1.1 CONNECT over TLS. (Whether
// Mozilla's real edge accepts this is a device question; what is
// pinned here is the wire shape and the session's semantics.)

// h1Fixture is a TLS listener that answers CONNECT like an
// HTTP/1.1 proxy: 200 and an echo tunnel, or 407 for
// blocked.example. It records what it saw for the assertions.
type h1Fixture struct {
	addr  string
	roots *x509.CertPool

	mu       sync.Mutex
	accepts  int
	authSeen []string
}

func newH1Fixture(t *testing.T) *h1Fixture {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	f := &h1Fixture{roots: x509.NewCertPool()}
	f.roots.AddCert(cert)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		NextProtos:   []string{"http/1.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	f.addr = ln.Addr().String()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			f.mu.Lock()
			f.accepts++
			f.mu.Unlock()
			go f.serve(conn)
		}
	}()
	SetUpstreamRoots(f.roots)
	t.Cleanup(func() { SetUpstreamRoots(nil) })
	return f
}

func (f *h1Fixture) serve(conn net.Conn) {
	defer conn.Close()
	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		return
	}
	f.mu.Lock()
	f.authSeen = append(f.authSeen, req.Header.Get("Proxy-Authorization"))
	f.mu.Unlock()
	if req.Method != http.MethodConnect {
		_, _ = io.WriteString(conn, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
		return
	}
	if req.Host == "blocked.example:443" {
		_, _ = io.WriteString(conn, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
		return
	}
	if req.Host == "silent.example:443" {
		// The proxy took the CONNECT and never answers: the client
		// must give up on its own deadline.
		_, _ = io.Copy(io.Discard, conn)
		return
	}
	if _, err := io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	_, _ = io.Copy(conn, conn) // echo until the client goes away
}

func (f *h1Fixture) url(t *testing.T) *url.URL {
	t.Helper()
	u, err := url.Parse("https://" + f.addr)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func (f *h1Fixture) stats() (int, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.accepts, append([]string(nil), f.authSeen...)
}

func TestH1SessionTunnelsAndEchoes(t *testing.T) {
	f := newH1Fixture(t)
	session, err := newH1ProxySession(f.url(t), "pass-token", 5*time.Second)
	if err != nil {
		t.Fatalf("newH1ProxySession: %v", err)
	}
	defer session.Close()
	// Construction dialed once: the establishment proof
	// NewController relies on (a dead server must fail here).
	if accepts, _ := f.stats(); accepts != 1 {
		t.Fatalf("construction accepts = %d, want 1 (the probe)", accepts)
	}
	for i, want := range []string{"first", "second"} {
		conn, err := session.OpenTunnel("example.com:443")
		if err != nil {
			t.Fatalf("OpenTunnel %d: %v", i, err)
		}
		if _, err := io.WriteString(conn, "ping-"+want); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		buf := make([]byte, len("ping-"+want))
		if _, err := io.ReadFull(conn, buf); err != nil {
			t.Fatalf("read %d: %v", i, err)
		}
		if string(buf) != "ping-"+want {
			t.Fatalf("echo %d = %q, want %q", i, buf, "ping-"+want)
		}
		_ = conn.Close()
	}
	// The first tunnel reused the probe connection; the second
	// dialed fresh. Both carried the pass as a Bearer token.
	accepts, auth := f.stats()
	if accepts != 2 {
		t.Fatalf("accepts = %d, want 2", accepts)
	}
	for _, a := range auth {
		if a != "Bearer pass-token" {
			t.Fatalf("Proxy-Authorization = %q, want the Bearer pass", a)
		}
	}
	// A renewed pass is presented by the next tunnel.
	if err := session.UpdateToken("new-token"); err != nil {
		t.Fatal(err)
	}
	conn, err := session.OpenTunnel("example.com:443")
	if err != nil {
		t.Fatalf("OpenTunnel after UpdateToken: %v", err)
	}
	_ = conn.Close()
	if _, auth := f.stats(); auth[len(auth)-1] != "Bearer new-token" {
		t.Fatalf("after UpdateToken the tunnel carried %q", auth[len(auth)-1])
	}
	if err := session.UpdateToken(" "); err == nil {
		t.Fatal("an empty token must be refused")
	}
}

// A CONNECT the proxy leaves unanswered until the deadline is a
// tunnel-open timeout — the target's pace, not the server's
// health. Reported as anything else, one slow target would
// rebuild the session repeatedly and strike a healthy server
// (verification finding, build 2105 iteration 1).
func TestH1ConnectTimeoutIsATunnelOpenTimeout(t *testing.T) {
	f := newH1Fixture(t)
	session, err := newH1ProxySession(f.url(t), "pass-token", 300*time.Millisecond)
	if err != nil {
		t.Fatalf("newH1ProxySession: %v", err)
	}
	defer session.Close()
	_, err = session.OpenTunnel("silent.example:443")
	var timeoutErr *tunnelOpenTimeoutError
	if !errors.As(err, &timeoutErr) {
		t.Fatalf("OpenTunnel error = %v, want a tunnelOpenTimeoutError", err)
	}
	if shouldRebuildProxySession(err) {
		t.Fatal("a tunnel-open timeout must not rebuild the session")
	}
}

// The tunnel must offer the half-close the relay asks for, like
// the H2/H3 tunnel conn: protocols that signal end-of-input and
// wait for the answer otherwise stall for the relay's whole
// half-close drain.
func TestH1TunnelOffersHalfClose(t *testing.T) {
	f := newH1Fixture(t)
	session, err := newH1ProxySession(f.url(t), "pass-token", 5*time.Second)
	if err != nil {
		t.Fatalf("newH1ProxySession: %v", err)
	}
	defer session.Close()
	tunnel, err := session.OpenTunnel("example.com:443")
	if err != nil {
		t.Fatalf("OpenTunnel: %v", err)
	}
	defer tunnel.Close()
	if _, ok := tunnel.(interface{ CloseWrite() error }); !ok {
		t.Fatal("the H1 tunnel does not implement CloseWrite")
	}
	// And it must not pretend the other half: *tls.Conn has no
	// CloseRead, so a CloseRead method could only ever no-op.
	if _, ok := tunnel.(interface{ CloseRead() error }); ok {
		t.Fatal("the H1 tunnel must not offer a CloseRead TLS cannot honour")
	}
}

func TestH1SessionRefusedStatusIsAConnectError(t *testing.T) {
	f := newH1Fixture(t)
	session, err := newH1ProxySession(f.url(t), "pass-token", 5*time.Second)
	if err != nil {
		t.Fatalf("newH1ProxySession: %v", err)
	}
	defer session.Close()
	_, err = session.OpenTunnel("blocked.example:443")
	var connectErr *proxyConnectHTTPError
	if !errors.As(err, &connectErr) || connectErr.statusCode != http.StatusProxyAuthRequired {
		t.Fatalf("err = %v, want a proxyConnectHTTPError with 407", err)
	}
	// A 407 is the account/pass's problem, never the server's:
	// the failover must not count it (the shipped serverFault
	// table, exercised here for the H1 error shape).
	if serverFault(err) {
		t.Fatal("a 407 from an H1 CONNECT must not count as a server fault")
	}
}

func TestH1ConstructionFailsForADeadServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := ln.Addr().String()
	_ = ln.Close()
	u, err := url.Parse("https://" + dead)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newH1ProxySession(u, "pass-token", 2*time.Second); err == nil {
		t.Fatal("construction against a dead server must fail — NewController's failover trigger depends on it")
	}
}

func TestH1SessionCloseRefusesNewTunnels(t *testing.T) {
	f := newH1Fixture(t)
	session, err := newH1ProxySession(f.url(t), "pass-token", 5*time.Second)
	if err != nil {
		t.Fatalf("newH1ProxySession: %v", err)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := session.OpenTunnel("example.com:443"); err == nil || !strings.Contains(err.Error(), "closed") {
		t.Fatalf("OpenTunnel after Close: err = %v", err)
	}
	if err := session.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}
