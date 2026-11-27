package resolver

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/armanlife/firefox-vpn-client/core/internal/egress"
)

const (
	dohContentType  = "application/dns-message"
	maxDoHReplySize = 64 << 10
)

// dohServer queries an RFC 8484 DNS-over-HTTPS endpoint with POST.
type dohServer struct {
	url    string
	client *http.Client
}

// newDoHClient is replaced in tests to trust a local server. The client
// never uses an HTTP proxy from the environment and resolves the server's
// own name, if any, with the system resolver (while the TUN mode runs, the
// physical network's DNS: egress).
var newDoHClient = func() *http.Client {
	return &http.Client{
		Timeout: queryTimeout,
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
				return egress.Dialer(queryTimeout).DialContext(ctx, network, address)
			},
			TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
			ForceAttemptHTTP2:   true,
			TLSHandshakeTimeout: queryTimeout,
			MaxIdleConns:        4,
			IdleConnTimeout:     2 * time.Minute,
		},
	}
}

func newDoHServer(u string) *dohServer {
	return &dohServer{url: u, client: newDoHClient()}
}

func (s *dohServer) String() string { return s.url }

// lookup asks for the address families the IP version policy uses
// (build 2105). Auto keeps the historic shape — A records, and
// AAAA only when there are none — so an auto answer never gains an
// IPv6 candidate it did not have before. ipv4_only never asks for
// AAAA; ipv6_only asks only for AAAA; ipv6_first asks for both at
// once and merges the answers (orderAddrs puts IPv6 first).
func (s *dohServer) lookup(ctx context.Context, host string) ([]netip.Addr, time.Duration, error) {
	switch currentIPVersion() {
	case ipVersionIPv4Only:
		return s.query(ctx, host, dnsmessage.TypeA)
	case ipVersionIPv6Only:
		return s.query(ctx, host, dnsmessage.TypeAAAA)
	case ipVersionIPv6First:
		type outcome struct {
			addrs []netip.Addr
			ttl   time.Duration
			err   error
		}
		results := make(chan outcome, 2)
		for _, qtype := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
			go func() {
				addrs, ttl, err := s.query(ctx, host, qtype)
				results <- outcome{addrs, ttl, err}
			}()
		}
		var merged []netip.Addr
		var ttl time.Duration
		var firstErr error
		for range 2 {
			r := <-results
			if r.err != nil {
				if firstErr == nil {
					firstErr = r.err
				}
				continue
			}
			merged = append(merged, r.addrs...)
			// Only a family that answered carries a TTL: an empty
			// family's zero must not zero out the other's real TTL
			// (the merge order is whichever goroutine landed first).
			if len(r.addrs) > 0 && (ttl == 0 || r.ttl < ttl) {
				ttl = r.ttl
			}
		}
		if len(merged) == 0 && firstErr != nil {
			return nil, 0, firstErr
		}
		return merged, ttl, nil
	default:
		addrs, ttl, err := s.query(ctx, host, dnsmessage.TypeA)
		if err != nil || len(addrs) > 0 {
			return addrs, ttl, err
		}
		return s.query(ctx, host, dnsmessage.TypeAAAA)
	}
}

func (s *dohServer) query(ctx context.Context, host string, qtype dnsmessage.Type) ([]netip.Addr, time.Duration, error) {
	name, err := dnsmessage.NewName(host + ".")
	if err != nil {
		return nil, 0, err
	}
	msg := dnsmessage.Message{
		Header:    dnsmessage.Header{RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: name, Type: qtype, Class: dnsmessage.ClassINET}},
	}
	packed, err := msg.Pack()
	if err != nil {
		return nil, 0, err
	}
	body, err := s.exchange(ctx, packed)
	if err != nil {
		return nil, 0, err
	}
	return parseAnswer(body, qtype)
}

// exchange sends a DNS message in wire format and returns the server's
// answer as it is.
func (s *dohServer) exchange(ctx context.Context, msg []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.url, bytes.NewReader(msg))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", dohContentType)
	req.Header.Set("Accept", dohContentType)
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxDoHReplySize))
}

// parseAnswer extracts the addresses of the wanted type and the smallest
// TTL among them; CNAME chains are followed by the server.
func parseAnswer(body []byte, qtype dnsmessage.Type) ([]netip.Addr, time.Duration, error) {
	var p dnsmessage.Parser
	header, err := p.Start(body)
	if err != nil {
		return nil, 0, err
	}
	if header.RCode != dnsmessage.RCodeSuccess {
		return nil, 0, fmt.Errorf("DNS error %s", header.RCode)
	}
	if err := p.SkipAllQuestions(); err != nil {
		return nil, 0, err
	}
	var addrs []netip.Addr
	var ttl time.Duration
	for {
		h, err := p.AnswerHeader()
		if errors.Is(err, dnsmessage.ErrSectionDone) {
			break
		}
		if err != nil {
			return nil, 0, err
		}
		if h.Type != qtype {
			if err := p.SkipAnswer(); err != nil {
				return nil, 0, err
			}
			continue
		}
		var addr netip.Addr
		switch qtype {
		case dnsmessage.TypeA:
			r, err := p.AResource()
			if err != nil {
				return nil, 0, err
			}
			addr = netip.AddrFrom4(r.A)
		case dnsmessage.TypeAAAA:
			r, err := p.AAAAResource()
			if err != nil {
				return nil, 0, err
			}
			addr = netip.AddrFrom16(r.AAAA).Unmap()
		}
		addrs = append(addrs, addr)
		recordTTL := time.Duration(h.TTL) * time.Second
		if ttl == 0 || recordTTL < ttl {
			ttl = recordTTL
		}
	}
	return addrs, ttl, nil
}
