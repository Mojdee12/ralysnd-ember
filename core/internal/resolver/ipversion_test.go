package resolver

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Build 2105: the dns.ip_version policy — ordering, filtering,
// literal refusal, and the DoH server's family questions.

func setPolicy(t *testing.T, name string) {
	t.Helper()
	SetIPVersion(name)
	t.Cleanup(func() { SetIPVersion("auto") })
}

func TestIPVersionPolicyOrderingAndFiltering(t *testing.T) {
	v4a := netip.MustParseAddr("192.0.2.1")
	v4b := netip.MustParseAddr("192.0.2.2")
	v6a := netip.MustParseAddr("2001:db8::1")
	v6b := netip.MustParseAddr("2001:db8::2")
	mixed := []netip.Addr{v6a, v4a, v6b, v4b}
	for name, want := range map[string][]netip.Addr{
		"auto":       {v4a, v4b, v6a, v6b},
		"ipv6_first": {v6a, v6b, v4a, v4b},
		"ipv4_only":  {v4a, v4b},
		"ipv6_only":  {v6a, v6b},
	} {
		setPolicy(t, name)
		if got := orderAddrs(mixed); !netipAddrsEqual(got, want) {
			t.Errorf("%s: orderAddrs = %v, want %v", name, got, want)
		}
	}
	// An unrecognized name is auto (config validation rejects it
	// before it can reach the resolver; the resolver stays safe).
	SetIPVersion("ipv5_only")
	if got := currentIPVersion(); got != ipVersionAuto {
		t.Errorf("unknown policy = %v, want auto", got)
	}
}

func netipAddrsEqual(a, b []netip.Addr) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestIPVersionLiteralRefusedAtDial(t *testing.T) {
	r := &Resolver{} // no servers: the system path
	setPolicy(t, "ipv4_only")
	if _, err := r.DialContext(context.Background(), "tcp", "[2001:db8::1]:443"); err == nil || !strings.Contains(err.Error(), "ip_version") {
		t.Fatalf("ipv6 literal under ipv4_only: err = %v", err)
	}
	setPolicy(t, "ipv6_only")
	if _, err := r.DialContext(context.Background(), "tcp", "192.0.2.1:443"); err == nil || !strings.Contains(err.Error(), "ip_version") {
		t.Fatalf("ipv4 literal under ipv6_only: err = %v", err)
	}
	// The allowed family passes the gate (and then fails to
	// connect, which is a different error).
	setPolicy(t, "ipv4_only")
	if _, err := r.DialContext(context.Background(), "tcp", "127.0.0.1:1"); err == nil || strings.Contains(err.Error(), "ip_version") {
		t.Fatalf("ipv4 literal under ipv4_only must pass the gate: err = %v", err)
	}
}

// A 4-in-6 mapped literal is an IPv4 endpoint: ipv4_only must let
// it through the gate, ipv6_only must refuse it — classification
// by the mapped address, not the textual family.
func TestIPVersionMappedLiteralClassifiedByMappedFamily(t *testing.T) {
	r := &Resolver{} // no servers: the system path
	setPolicy(t, "ipv6_only")
	if _, err := r.DialContext(context.Background(), "tcp", "[::ffff:192.0.2.1]:443"); err == nil || !strings.Contains(err.Error(), "ip_version") {
		t.Fatalf("mapped ipv4 literal under ipv6_only: err = %v", err)
	}
	setPolicy(t, "ipv4_only")
	if _, err := r.DialContext(context.Background(), "tcp", "[::ffff:127.0.0.1]:1"); err == nil || strings.Contains(err.Error(), "ip_version") {
		t.Fatalf("mapped ipv4 literal under ipv4_only must pass the gate: err = %v", err)
	}
}

// With a policy on, the system-resolver path must honour it for
// hostnames too: handing the name to the system dialer would let
// it use the excluded family, and the transports would disagree
// about what dns.ip_version means.
func TestIPVersionPolicyAppliesOnSystemPath(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			accepted <- conn
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	r := &Resolver{} // no servers: the system path

	setPolicy(t, "ipv6_only")
	if _, err := r.DialContext(context.Background(), "tcp", "localhost:"+port); err == nil {
		t.Fatal("ipv6_only must not connect to the IPv4 listener via the system path")
	}
	select {
	case conn := <-accepted:
		conn.Close()
		t.Fatal("the IPv4 listener accepted a connection under ipv6_only")
	case <-time.After(200 * time.Millisecond):
	}

	setPolicy(t, "auto")
	conn, err := r.DialContext(context.Background(), "tcp", "localhost:"+port)
	if err != nil {
		t.Fatalf("auto keeps the historic system dial: %v", err)
	}
	conn.Close()
}

// Under ipv6_first, a family with no records must not zero out
// the answering family's TTL (the merge order is whichever
// goroutine lands first, so the bug cached answers for the
// default TTL about half the time).
func TestDoHIPv6FirstMergeKeepsTheAnsweringFamilysTTL(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var msg dnsmessage.Message
		if err := msg.Unpack(body); err != nil || len(msg.Questions) == 0 {
			http.Error(w, "bad query", http.StatusBadRequest)
			return
		}
		q := msg.Questions[0]
		reply := dnsmessage.Message{
			Header:    dnsmessage.Header{ID: msg.Header.ID, Response: true, RecursionAvailable: true},
			Questions: msg.Questions,
		}
		if q.Type == dnsmessage.TypeA {
			reply.Answers = append(reply.Answers, dnsmessage.Resource{
				Header: dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 120},
				Body:   &dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}},
			})
		}
		packed, err := reply.Pack()
		if err != nil {
			t.Errorf("packing reply: %v", err)
			return
		}
		w.Header().Set("Content-Type", dohContentType)
		_, _ = w.Write(packed)
	}))
	t.Cleanup(srv.Close)
	old := newDoHClient
	newDoHClient = srv.Client
	t.Cleanup(func() { newDoHClient = old })

	setPolicy(t, "ipv6_first")
	s := newDoHServer(srv.URL + "/dns-query")
	addrs, ttl, err := s.lookup(context.Background(), "example.com")
	if err != nil {
		t.Fatal(err)
	}
	if len(addrs) != 1 {
		t.Fatalf("addrs = %v, want the one A answer", addrs)
	}
	if ttl != 120*time.Second {
		t.Fatalf("merged TTL = %v, want the answering family's 120s", ttl)
	}
}

// startDoHBoth starts a DoH server answering A with 192.0.2.1 and
// AAAA with 2001:db8::1, counting the questions per family.
func startDoHBoth(t *testing.T, aHits, aaaaHits *atomic.Int32) string {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var msg dnsmessage.Message
		if err := msg.Unpack(body); err != nil || len(msg.Questions) == 0 {
			http.Error(w, "bad query", http.StatusBadRequest)
			return
		}
		q := msg.Questions[0]
		reply := dnsmessage.Message{
			Header:    dnsmessage.Header{ID: msg.Header.ID, Response: true, RecursionAvailable: true},
			Questions: msg.Questions,
		}
		switch q.Type {
		case dnsmessage.TypeA:
			aHits.Add(1)
			reply.Answers = append(reply.Answers, dnsmessage.Resource{
				Header: dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 120},
				Body:   &dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}},
			})
		case dnsmessage.TypeAAAA:
			aaaaHits.Add(1)
			reply.Answers = append(reply.Answers, dnsmessage.Resource{
				Header: dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeAAAA, Class: dnsmessage.ClassINET, TTL: 120},
				Body:   &dnsmessage.AAAAResource{AAAA: netip.MustParseAddr("2001:db8::1").As16()},
			})
		}
		packed, err := reply.Pack()
		if err != nil {
			t.Errorf("packing reply: %v", err)
			return
		}
		w.Header().Set("Content-Type", dohContentType)
		_, _ = w.Write(packed)
	}))
	t.Cleanup(srv.Close)
	old := newDoHClient
	newDoHClient = srv.Client
	t.Cleanup(func() { newDoHClient = old })
	return srv.URL + "/dns-query"
}

func TestDoHLookupFamiliesFollowPolicy(t *testing.T) {
	var aHits, aaaaHits atomic.Int32
	url := startDoHBoth(t, &aHits, &aaaaHits)
	s := newDoHServer(url)
	v4 := netip.MustParseAddr("192.0.2.1")
	v6 := netip.MustParseAddr("2001:db8::1")

	for _, tc := range []struct {
		policy   string
		wantA    int32
		wantAAAA int32
		want     []netip.Addr
	}{
		{"auto", 1, 0, []netip.Addr{v4}},           // A first; AAAA only when no A
		{"ipv4_only", 1, 0, []netip.Addr{v4}},      // never AAAA
		{"ipv6_only", 0, 1, []netip.Addr{v6}},      // only AAAA
		{"ipv6_first", 1, 1, []netip.Addr{v4, v6}}, // both, merged
	} {
		aHits.Store(0)
		aaaaHits.Store(0)
		setPolicy(t, tc.policy)
		addrs, _, err := s.lookup(context.Background(), "example.com")
		if err != nil {
			t.Fatalf("%s: %v", tc.policy, err)
		}
		if aHits.Load() != tc.wantA || aaaaHits.Load() != tc.wantAAAA {
			t.Errorf("%s: questions A=%d AAAA=%d, want %d/%d", tc.policy, aHits.Load(), aaaaHits.Load(), tc.wantA, tc.wantAAAA)
		}
		if len(addrs) != len(tc.want) {
			t.Fatalf("%s: addrs = %v, want %v", tc.policy, addrs, tc.want)
		}
		for _, want := range tc.want {
			found := false
			for _, got := range addrs {
				if got == want {
					found = true
				}
			}
			if !found {
				t.Errorf("%s: addrs %v missing %v", tc.policy, addrs, want)
			}
		}
	}
}
