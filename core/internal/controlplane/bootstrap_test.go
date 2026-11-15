package controlplane

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func stubResponse(r *http.Request) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader("{}")),
		Request:    r,
	}
}

func TestWorkerRelayRewritesAllowlistedHost(t *testing.T) {
	var got *http.Request
	inner := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		got = r
		return stubResponse(r), nil
	})
	base, _ := url.Parse("https://relay.example.workers.dev")
	transport := &workerRelayTransport{base: base, key: "sekret", inner: inner}

	req, _ := http.NewRequest(http.MethodPost, "https://api.accounts.firefox.com/v1/token?x=1", strings.NewReader("a=b"))
	resp, err := transport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	if got.URL.String() != "https://relay.example.workers.dev/api.accounts.firefox.com/v1/token?x=1" {
		t.Fatalf("rewritten URL: %s", got.URL)
	}
	if got.Header.Get("X-Relay-Key") != "sekret" {
		t.Fatalf("relay key header: %q", got.Header.Get("X-Relay-Key"))
	}
	if resp.Request != req {
		t.Fatal("the response must keep the original request (cookies/redirects resolve against the target)")
	}
	// The caller's request is not mutated.
	if req.Header.Get("X-Relay-Key") != "" || req.URL.Host != "api.accounts.firefox.com" {
		t.Fatal("the original request was mutated")
	}
}

func TestWorkerRelayPassesOtherHostsThrough(t *testing.T) {
	var got *http.Request
	inner := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		got = r
		return stubResponse(r), nil
	})
	base, _ := url.Parse("https://relay.example.workers.dev")
	transport := &workerRelayTransport{base: base, key: "sekret", inner: inner}

	req, _ := http.NewRequest(http.MethodGet, "https://vpn.mozilla.org/api/v1/fpn/token", nil)
	if _, err := transport.RoundTrip(req); err != nil {
		t.Fatal(err)
	}
	if got != req {
		t.Fatal("a non-allowlisted host must pass through untouched")
	}
}

func TestBootstrapEgressSwapAndRestore(t *testing.T) {
	ClearBootstrap()
	t.Cleanup(ClearBootstrap)
	before := Transport()

	if err := SetBootstrapRelay("https://relay.example.workers.dev", "sekret"); err != nil {
		t.Fatal(err)
	}
	if Bootstrap() != BootstrapRelay {
		t.Fatalf("kind = %q, want relay", Bootstrap())
	}
	var inside http.RoundTripper
	err := WithBootstrapEgress(context.Background(), func(ctx context.Context) error {
		if !InBootstrapEgress(ctx) {
			t.Error("ctx is not marked as inside an egress window")
		}
		inside = Transport()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := inside.(*workerRelayTransport); !ok {
		t.Fatalf("transport inside the window = %T, want *workerRelayTransport", inside)
	}
	if Transport() != before {
		t.Fatal("transport was not restored after the window")
	}
	if InBootstrapEgress(context.Background()) {
		t.Fatal("a fresh context must not be marked")
	}

	SetBootstrapSocks("127.0.0.1:1080")
	if Bootstrap() != BootstrapSocks {
		t.Fatalf("kind = %q, want socks", Bootstrap())
	}
	err = WithBootstrapEgress(context.Background(), func(ctx context.Context) error {
		tr, ok := Transport().(*http.Transport)
		if !ok {
			t.Errorf("socks transport = %T, want *http.Transport", Transport())
			return nil
		}
		proxyURL, err := tr.Proxy(&http.Request{URL: &url.URL{Scheme: "https", Host: "vpn.mozilla.org"}})
		if err != nil || proxyURL == nil || proxyURL.String() != "socks5://127.0.0.1:1080" {
			t.Errorf("proxy = %v, %v; want socks5://127.0.0.1:1080", proxyURL, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if Transport() != before {
		t.Fatal("transport was not restored after the socks window")
	}
}
