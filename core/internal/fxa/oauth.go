package fxa

// Browser OAuth sign-in and the modern token grants (build
// 2033 — the Mozilla engine's sign-in contract is now
// Kumiho's: benyamin-git/Kumiho, MIT, adopted with credit).
//
// Why this file exists: through 2026 Mozilla retired the
// routes Ember's sign-in was built on. The legacy JSON token
// route (/v1/oauth/token) and any request carrying the
// MozillaVPN User-Agent on a token route are answered with
// an EMPTY HTTP 406 — a hard block no challenge solve clears
// (Kumiho v0.8.3/v0.10.2 release notes) — and the desktop
// client's completion hand-off travels over Firefox's
// in-process WebChannel, which no WebView can receive, so a
// sign-in that verifies on the web side has nowhere to land
// (the post-code reload loop the owner hit on build 2032).
//
// The contract implemented here, each point verified against
// Kumiho's source and live behaviour notes:
//
//   - Browser sign-in uses the public Firefox for Android
//     OAuth client (a2270f727f45f648) whose registered
//     redirect is an ordinary HTTPS page —
//     https://accounts.firefox.com/oauth/success — so a
//     WebView can intercept it and read code+state from the
//     URL. PKCE S256, access_type=offline, scope
//     "profile https://identity.mozilla.com/apps/vpn".
//   - Code exchange and refresh use the OAuth server's
//     standard form grant at POST /v1/token — never the
//     hard-blocked legacy JSON route — API host first, the
//     sibling oauth. host as the failover.
//   - The exchange sends Fenix's registered redirect_uri
//     verbatim (the invalid_grant in Kumiho's notes was for
//     the desktop client's URN redirect, a different value).
//   - A 406 whose body carries the Fastly challenge markers
//     is a challenge (solve + retry, the fxaDo discipline);
//     a 406 without them is a hard block: no solve is
//     attempted and the next host is tried at once.
//   - Refresh ROTATES the refresh token; the new one is in
//     the response and callers persist it (the SavedTokens
//     write in the account pool already does).
//   - FxA requests carry the DESKTOP Firefox User-Agent
//     (ApplyFirefoxHeaders) — the identity the token routes
//     are not blocked for. Guardian keeps the MozillaVPN UA
//     it requires; that split is deliberate.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
)

const (
	// fenixClientID is the public Firefox for Android OAuth
	// client — the only public client whose registered
	// redirect a WebView can intercept.
	fenixClientID = "a2270f727f45f648"

	// browserAuthorizeURL is the OAuth server's authorize
	// endpoint on the web host (Kumiho's
	// DefaultAuthorizationEndpoint — /authorization, not
	// /oauth).
	browserAuthorizeURL = "https://accounts.firefox.com/authorization"

	// browserRedirectURI is Fenix's registered success page,
	// client-id suffixed as registered; the WebView watches
	// for navigations to it.
	browserRedirectURI = "https://accounts.firefox.com/oauth/success/" + fenixClientID

	// fxaProfileURL is the FxA profile endpoint: after the
	// exchange, the account's email comes from here (Bearer
	// access token) — Kumiho never reads the id_token.
	fxaProfileURL = "https://profile.accounts.firefox.com/v1/profile"

	// fxaOAuthHost is the sibling auth-server host: the same
	// server behind a hostname the per-host hard blocks do
	// not always cover.
	fxaOAuthHost = "https://oauth.accounts.firefox.com/v1"
)

// tokenHosts is the /v1/token host order for the form
// grants: the API host first (it answers refresh), the
// sibling as failover. A variable so tests can point the
// grants at a local server.
var tokenHosts = []string{fxaAuthServer, fxaOAuthHost}

// errHardBlock marks an empty/markerless 406: Fastly's hard
// block, which no challenge solve clears.
var errHardBlock = errors.New("FxA hard block (HTTP 406 without a challenge page)")

// NewBrowserChallenge mints the PKCE pair and the anti-CSRF
// state for one browser sign-in: a 256-bit verifier (the
// base64url-no-padding form RFC 7636 wants), its S256
// challenge, and 128 bits of state.
func NewBrowserChallenge() (verifier, challenge, state string, err error) {
	var vraw [32]byte
	if _, err := rand.Read(vraw[:]); err != nil {
		return "", "", "", err
	}
	verifier = base64.RawURLEncoding.EncodeToString(vraw[:])
	sum := sha256.Sum256([]byte(verifier))
	challenge = base64.RawURLEncoding.EncodeToString(sum[:])
	var sraw [16]byte
	if _, err := rand.Read(sraw[:]); err != nil {
		return "", "", "", err
	}
	state = base64.RawURLEncoding.EncodeToString(sraw[:])
	return verifier, challenge, state, nil
}

// BrowserAuthURL builds the authorize URL the WebView opens.
func BrowserAuthURL(challenge, state string) string {
	q := url.Values{}
	q.Set("client_id", fenixClientID)
	q.Set("response_type", "code")
	q.Set("scope", oauthScope)
	q.Set("access_type", "offline")
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("state", state)
	q.Set("redirect_uri", browserRedirectURI)
	return browserAuthorizeURL + "?" + q.Encode()
}

// BrowserRedirectPrefix is the URL prefix the WebView
// intercepts: navigations starting with it carry the
// outcome (?code&state, or ?error) in their query.
func BrowserRedirectPrefix() string { return browserRedirectURI }

// ExchangeAuthCode trades the intercepted authorization code
// for tokens at /v1/token. The form carries the registered
// redirect_uri verbatim (Kumiho's caller does the same; the
// invalid_grant their notes warn about was for the DESKTOP
// client's URN redirect, not Fenix's registered page).
func ExchangeAuthCode(ctx context.Context, code, verifier string) (*TokenResponse, error) {
	form := url.Values{}
	form.Set("client_id", fenixClientID)
	form.Set("code", code)
	form.Set("code_verifier", verifier)
	form.Set("grant_type", "authorization_code")
	form.Set("redirect_uri", browserRedirectURI)
	tok, err := tokenFormGrant(ctx, form)
	if err != nil {
		return nil, err
	}
	tok.ClientID = fenixClientID
	return tok, nil
}

// ProfileEmail fetches the account's email from the FxA
// profile endpoint with the fresh access token — the
// browser flow's only identity source (Kumiho's
// LoginComplete does exactly this before storing anything).
func ProfileEmail(ctx context.Context, accessToken string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fxaProfileURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	controlplane.ApplyFirefoxHeaders(req)
	resp, err := controlplane.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", newFxaAPIError(resp.StatusCode, data)
	}
	var profile struct {
		Email string `json:"email"`
	}
	if err := json.Unmarshal(data, &profile); err != nil {
		return "", fmt.Errorf("parsing profile response: %w", err)
	}
	return profile.Email, nil
}

// refreshViaFormGrant is the /v1/token refresh that replaced
// the legacy JSON route (fxaRefreshToken's old body). The
// grant is bound to the client that minted the tokens, so a
// browser-minted token refreshes as Fenix and a
// password-minted one as the desktop client.
func refreshViaFormGrant(ctx context.Context, refreshToken, clientID string) (*TokenResponse, error) {
	if clientID == "" {
		clientID = firefoxClientID
	}
	form := url.Values{}
	form.Set("client_id", clientID)
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", refreshToken)
	form.Set("scope", oauthScope)
	tok, err := tokenFormGrant(ctx, form)
	if err != nil {
		return nil, err
	}
	// A rotated refresh token replaces the old one; when the
	// answer carries none, the old one stands.
	if tok.RefreshToken == "" {
		tok.RefreshToken = refreshToken
	}
	tok.ClientID = clientID
	return tok, nil
}

// tokenFormGrant runs a form grant against the token hosts
// in order. A hard block or a transport failure moves to the
// next host; any definitive FxA answer (a token, or an API
// error such as invalid_grant) ends the walk.
func tokenFormGrant(ctx context.Context, form url.Values) (*TokenResponse, error) {
	ctx, cancel := contextWithMinDeadline(ctx, fxaCallMinBudget)
	defer cancel()
	var lastErr error
	for _, host := range tokenHosts {
		tok, err := tokenFormGrantOn(ctx, host, form)
		if err == nil {
			return tok, nil
		}
		lastErr = err
		if !errors.Is(err, errHardBlock) && !isTransportErr(err) {
			return nil, err
		}
	}
	return nil, lastErr
}

func isTransportErr(err error) bool {
	var ue *url.Error
	return errors.As(err, &ue)
}

// tokenFormGrantOn is one host's attempt: challenge-page
// 406s are solved and retried (bounded, the fxaDo budget);
// a markerless 406 returns errHardBlock at once.
func tokenFormGrantOn(ctx context.Context, host string, form url.Values) (*TokenResponse, error) {
	tokenURL := host + "/token"
	for attempt := 1; attempt <= maxChallengeAttempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
		if err != nil {
			return nil, fmt.Errorf("creating token request: %w", err)
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		controlplane.ApplyFirefoxHeaders(req)
		resp, err := controlplane.Do(req)
		if err != nil {
			return nil, err
		}
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusOK:
			var tok TokenResponse
			if err := json.Unmarshal(data, &tok); err != nil {
				return nil, fmt.Errorf("parsing token response: %w", err)
			}
			return &tok, nil
		case resp.StatusCode == http.StatusNotAcceptable && isChallengePage(string(data)):
			origin := req.URL.Scheme + "://" + req.URL.Host
			if err := SolveChallenge(ctx, origin, data); err != nil {
				if !errors.Is(err, errNoChallengePage) {
					return nil, fmt.Errorf("Fastly anti-bot challenge: %w", err)
				}
				if err := solveFastlyChallenge(ctx); err != nil {
					return nil, fmt.Errorf("Fastly anti-bot challenge: %w", err)
				}
			}
		case resp.StatusCode == http.StatusNotAcceptable:
			return nil, fmt.Errorf("%w on %s", errHardBlock, host)
		default:
			return nil, newFxaAPIError(resp.StatusCode, data)
		}
	}
	return nil, fmt.Errorf("Fastly anti-bot challenge still failing after %d attempts (HTTP 406)", maxChallengeAttempts)
}

// EmailFromIDToken reads the email claim from the id_token
// of a browser code exchange. No signature check is needed —
// or meaningful — here: the token arrived in the token
// endpoint's own TLS response to our exchange, never from
// anywhere else; the claim is used only as the account's
// display/store identity, while every privileged call uses
// the access token itself.
func EmailFromIDToken(tok *TokenResponse) string {
	if tok == nil || tok.IDToken == "" {
		return ""
	}
	parts := strings.Split(tok.IDToken, ".")
	if len(parts) != 3 {
		return ""
	}
	payload := parts[1]
	if m := len(payload) % 4; m != 0 {
		payload += strings.Repeat("=", 4-m)
	}
	raw, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return ""
	}
	var claims struct {
		Email string `json:"email"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		return ""
	}
	return claims.Email
}
