package fxa

// Build 2033: the Kumiho sign-in contract, host side — PKCE
// shape, the authorize URL's parameters, the /v1/token form
// grants (fields, host order, hard-block failover), and the
// id_token email claim. The live behaviour is the owner's
// device test; these tests pin the wire shape.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
)

// useFormFixture installs a transport that answers form
// posts, recording every request's host, path and form.
type formCall struct {
	host string
	path string
	form url.Values
	ua   string
}

func useFormFixture(t *testing.T, handler func(call formCall) (int, string)) *[]formCall {
	t.Helper()
	previous := controlplane.Transport()
	t.Cleanup(func() { controlplane.SetTransport(previous) })
	calls := &[]formCall{}
	controlplane.SetTransport(roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(raw))
		call := formCall{host: r.URL.Host, path: r.URL.Path, form: form, ua: r.Header.Get("User-Agent")}
		*calls = append(*calls, call)
		status, text := handler(call)
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(text)), Request: r}, nil
	}))
	return calls
}

func useTokenHosts(t *testing.T, hosts ...string) {
	t.Helper()
	previous := tokenHosts
	t.Cleanup(func() { tokenHosts = previous })
	tokenHosts = hosts
}

func TestBrowserChallengeShape(t *testing.T) {
	verifier, challenge, state, err := NewBrowserChallenge()
	if err != nil {
		t.Fatal(err)
	}
	if len(verifier) != 43 || strings.ContainsAny(verifier, "+/=") {
		t.Fatalf("verifier is not a 256-bit base64url value: %q", verifier)
	}
	if len(challenge) != 43 || strings.ContainsAny(challenge, "+/=") {
		t.Fatalf("challenge is not an S256 base64url value: %q", challenge)
	}
	if len(state) < 20 {
		t.Fatalf("state too short: %q", state)
	}
	// The challenge must be the S256 of the verifier.
	if got := browserChallengeOf(verifier); got != challenge {
		t.Fatalf("challenge %q is not S256(verifier) %q", challenge, got)
	}
}

func browserChallengeOf(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func TestBrowserAuthURLContract(t *testing.T) {
	raw := BrowserAuthURL("CH", "ST")
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme+"://"+u.Host+u.Path != "https://accounts.firefox.com/authorization" {
		t.Fatalf("authorize endpoint: %s", raw)
	}
	q := u.Query()
	want := map[string]string{
		"client_id":             "a2270f727f45f648",
		"response_type":         "code",
		"scope":                 "profile https://identity.mozilla.com/apps/vpn",
		"access_type":           "offline",
		"code_challenge":        "CH",
		"code_challenge_method": "S256",
		"state":                 "ST",
		"redirect_uri":          "https://accounts.firefox.com/oauth/success/a2270f727f45f648",
	}
	for key, value := range want {
		if got := q.Get(key); got != value {
			t.Fatalf("param %s = %q, want %q (url %s)", key, got, value, raw)
		}
	}
	if BrowserRedirectPrefix() != "https://accounts.firefox.com/oauth/success/a2270f727f45f648" {
		t.Fatalf("redirect prefix: %s", BrowserRedirectPrefix())
	}
}

func TestExchangeAuthCodeFormAndHosts(t *testing.T) {
	useTokenHosts(t, "https://api.accounts.firefox.com/v1", "https://oauth.accounts.firefox.com/v1")
	calls := useFormFixture(t, func(call formCall) (int, string) {
		return 200, `{"access_token":"at","refresh_token":"rt","expires_in":21600,"id_token":"x"}`
	})
	tok, err := ExchangeAuthCode(context.Background(), "the-code", "the-verifier")
	if err != nil {
		t.Fatal(err)
	}
	if tok.AccessToken != "at" || tok.RefreshToken != "rt" || tok.ClientID != fenixClientID {
		t.Fatalf("token: %+v", tok)
	}
	if len(*calls) != 1 {
		t.Fatalf("calls: %d", len(*calls))
	}
	call := (*calls)[0]
	if call.host != "api.accounts.firefox.com" || call.path != "/v1/token" {
		t.Fatalf("endpoint: %s%s", call.host, call.path)
	}
	want := map[string]string{
		"client_id":     "a2270f727f45f648",
		"code":          "the-code",
		"code_verifier": "the-verifier",
		"grant_type":    "authorization_code",
		// Kumiho's exchange sends the registered redirect_uri
		// verbatim.
		"redirect_uri": "https://accounts.firefox.com/oauth/success/a2270f727f45f648",
	}
	for key, value := range want {
		if got := call.form.Get(key); got != value {
			t.Fatalf("form %s = %q, want %q", key, got, value)
		}
	}
	// FxA requests carry a desktop Firefox UA, never MozillaVPN's.
	if !strings.Contains(call.ua, "Firefox/") || strings.Contains(call.ua, "MozillaVPN") {
		t.Fatalf("user agent: %q", call.ua)
	}
}

func TestTokenGrantHardBlockFailsOver(t *testing.T) {
	useTokenHosts(t, "https://api.accounts.firefox.com/v1", "https://oauth.accounts.firefox.com/v1")
	calls := useFormFixture(t, func(call formCall) (int, string) {
		if call.host == "api.accounts.firefox.com" {
			return 406, "" // the empty hard block: no challenge page
		}
		return 200, `{"access_token":"at2","refresh_token":"rt2","expires_in":21600}`
	})
	tok, err := RefreshToken(context.Background(), "old-refresh", "")
	if err != nil {
		t.Fatal(err)
	}
	if tok.AccessToken != "at2" || tok.RefreshToken != "rt2" {
		t.Fatalf("token: %+v", tok)
	}
	if len(*calls) != 2 {
		t.Fatalf("expected one call per host, got %d", len(*calls))
	}
	grant := (*calls)[0].form
	if grant.Get("grant_type") != "refresh_token" || grant.Get("client_id") != firefoxClientID || grant.Get("scope") != oauthScope {
		t.Fatalf("refresh form: %v", grant)
	}
}

func TestRefreshKeepsClientAndOldTokenWhenUnrotated(t *testing.T) {
	useTokenHosts(t, "https://api.accounts.firefox.com/v1")
	useFormFixture(t, func(call formCall) (int, string) {
		return 200, `{"access_token":"at3","expires_in":21600}`
	})
	tok, err := RefreshToken(context.Background(), "keep-me", fenixClientID)
	if err != nil {
		t.Fatal(err)
	}
	if tok.RefreshToken != "keep-me" || tok.ClientID != fenixClientID {
		t.Fatalf("token: %+v", tok)
	}
}

func TestTokenGrantDefinitiveErrorDoesNotFailOver(t *testing.T) {
	useTokenHosts(t, "https://api.accounts.firefox.com/v1", "https://oauth.accounts.firefox.com/v1")
	calls := useFormFixture(t, func(call formCall) (int, string) {
		return 400, `{"errno":125,"message":"Invalid grant"}`
	})
	_, err := RefreshToken(context.Background(), "dead", "")
	if err == nil {
		t.Fatal("expected an error")
	}
	if len(*calls) != 1 {
		t.Fatalf("a definitive FxA answer must end the walk, got %d calls", len(*calls))
	}
}

func TestEmailFromIDToken(t *testing.T) {
	payload, _ := json.Marshal(map[string]string{"email": "person@example.com", "sub": "uid1"})
	jwt := "h." + base64.RawURLEncoding.EncodeToString(payload) + ".s"
	if got := EmailFromIDToken(&TokenResponse{IDToken: jwt}); got != "person@example.com" {
		t.Fatalf("email: %q", got)
	}
	if got := EmailFromIDToken(&TokenResponse{}); got != "" {
		t.Fatalf("no token must mean no email, got %q", got)
	}
	if got := EmailFromIDToken(&TokenResponse{IDToken: "not-a-jwt"}); got != "" {
		t.Fatalf("a malformed token must mean no email, got %q", got)
	}
}
