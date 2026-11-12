package fxa

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/controlplane"
)

const (
	fxaAPIHost = "https://api.accounts.firefox.com"
	fxaSiteURL = "https://accounts.firefox.com/"

	// fastlySolveTimeout bounds one full challenge-solving attempt. It is
	// deliberately longer than a single API call because solving involves
	// several sequential requests (page, script, challenge answer,
	// post-back, probe).
	fastlySolveTimeout = 60 * time.Second

	// maxPostBackRounds caps follow-up challenge rounds returned by
	// fst-post-back ({ch, tok} responses). Fastly issues a new image after
	// a wrong CAPTCHA answer, so rounds also bound CAPTCHA retries.
	maxPostBackRounds = 8
)

var (
	fastlyChallengePrefixRe = regexp.MustCompile(`/_fs-ch-[A-Za-z0-9]+`)
	fastlyInitCallRe        = regexp.MustCompile(`init\s*\(`)

	// powAlphabet is the character set the Fastly proof-of-work solver
	// brute-forces; it mirrors the challenge script's own alphabet.
	powAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

	// challengeSolveSlot serializes solving attempts: two concurrent solvers
	// would race on the control plane client's cookie jar and on the
	// exit-IP-bound cookie. A waiter gives up when its context ends, so a
	// solve waiting for a person (a CAPTCHA in the dashboard) cannot hold up
	// a pass renewal past its timeout.
	challengeSolveSlot = make(chan struct{}, 1)

	// errNoChallengePage signals that a host served regular content
	// instead of a Fastly challenge page.
	errNoChallengePage = errors.New("host did not serve a Fastly challenge page")

	// errChallengeNotAccepted signals that the solved cookie was rejected
	// on the probe request, typically because the exit IP rotated between
	// solving and probing.
	errChallengeNotAccepted = errors.New("challenge cookie not accepted on this exit IP")
)

type fastlyChallenge struct {
	Ty   string          `json:"ty"`
	Data json.RawMessage `json:"data"`
}

type fastlyPowData struct {
	Base    string `json:"base"`
	Expires string `json:"expires"`
	HMAC    string `json:"hmac"`
	Hash    string `json:"hash"`
}

type fastlyPostBack struct {
	Token string        `json:"token"`
	Data  []interface{} `json:"data"`
}

type fastlyPostBackResponse struct {
	Status string            `json:"status"`
	Ch     []fastlyChallenge `json:"ch"`
	Tok    string            `json:"tok"`
}

// solverUserAgent is the User-Agent the challenge solver presents. It is
// the control plane client's own Firefox User-Agent — the same identity
// the API requests carry — so Fastly sees one coherent client fingerprint
// across the challenge handshake and the API call that follows it. (An
// earlier version solved under a stale Chrome/126 UA that no API request
// ever used; FoxyVPN v2.0.2's solver likewise solves under its API UA.)
func solverUserAgent() string {
	return controlplane.FirefoxUserAgent()
}

// isChallengePage reports whether body looks like a Fastly client-challenge
// page: it carries a challenge asset prefix plus at least one challenge
// marker. The marker set mirrors FoxyVPN v2.0.2's detector — the current
// challenge pages do not always carry the "Client Challenge" title.
func isChallengePage(body string) bool {
	if len(body) == 0 || len(body) > 2<<20 {
		return false
	}
	if !fastlyChallengePrefixRe.MatchString(body) {
		return false
	}
	return strings.Contains(strings.ToLower(body), "client challenge") ||
		strings.Contains(body, "script.js") ||
		strings.Contains(body, "fst-post-back")
}

// withSolveSlot runs fn holding the single challenge-solve slot and with
// at least fastlySolveTimeout of deadline.
func withSolveSlot(ctx context.Context, fn func(context.Context) error) error {
	select {
	case challengeSolveSlot <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-challengeSolveSlot }()

	ctx, cancel := contextWithMinDeadline(ctx, fastlySolveTimeout)
	defer cancel()
	return fn(ctx)
}

// solveFastlyChallenge performs the Fastly client-challenge handshake and
// installs the resulting anti-bot cookie into the control plane client's
// cookie jar. The solver shares the control plane client's transport so that
// the request exits through the same proxy (and therefore the same exit IP)
// as the subsequent API call: the issued cookie is bound to the exit IP that
// solved the challenge.
func solveFastlyChallenge(ctx context.Context) error {
	return withSolveSlot(ctx, func(ctx context.Context) error {
		// Prefer the host that actually rejected the API request, but fall
		// back to the site host: the API host usually serves no challenge
		// page at all and the cookie it needs is issued with Domain=firefox.com.
		var lastErr error
		for _, base := range []string{fxaAPIHost, strings.TrimRight(fxaSiteURL, "/")} {
			err := solveChallengeOnHost(ctx, base)
			if err == nil {
				return nil
			}
			lastErr = err
			if errors.Is(err, errNoChallengePage) {
				continue
			}
		}
		if lastErr == nil {
			lastErr = errNoChallengePage
		}
		return lastErr
	})
}

// SolveChallenge solves the Fastly challenge for one origin, following
// FoxyVPN v2.0.2's approach: when the HTTP 406 response body is itself a
// challenge page it is solved directly; otherwise the origin's root page
// is fetched and solved. It is exported for the Guardian client, whose
// endpoint (vpn.mozilla.org) sits behind the same Fastly challenge but is
// not one of the FxA hosts solveFastlyChallenge probes.
func SolveChallenge(ctx context.Context, origin string, challengedBody []byte) error {
	return withSolveSlot(ctx, func(ctx context.Context) error {
		if len(challengedBody) > 0 && isChallengePage(string(challengedBody)) {
			return solveChallengeWithPage(ctx, origin, string(challengedBody))
		}
		return solveChallengeOnHost(ctx, origin)
	})
}

// solveChallengeOnHost runs the whole challenge flow against one host using
// a throw-away client with a fresh cookie jar: re-solving with a client that
// already holds a valid challenge cookie fails because Fastly then serves
// the real page instead of the challenge page.
func solveChallengeOnHost(ctx context.Context, base string) error {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return err
	}
	client := &http.Client{
		Transport: controlplane.Transport(),
		Jar:       jar,
		Timeout:   fastlySolveTimeout,
	}
	pageURL := base + "/"

	page, isChallenge, err := fetchChallengePage(ctx, client, pageURL)
	if err != nil {
		return err
	}
	if !isChallenge {
		return errNoChallengePage
	}
	return solveChallengePage(ctx, client, jar, base, page)
}

// solveChallengeWithPage solves a challenge page that arrived as the body
// of a challenged (HTTP 406) response instead of fetching the host's root
// page: current Fastly deployments serve the challenge on the API request
// itself, and the root page may not carry one.
func solveChallengeWithPage(ctx context.Context, base, page string) error {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return err
	}
	client := &http.Client{
		Transport: controlplane.Transport(),
		Jar:       jar,
		Timeout:   fastlySolveTimeout,
	}
	return solveChallengePage(ctx, client, jar, base, page)
}

// solveChallengePage runs the script/answer/post-back rounds for one
// already-fetched challenge page and installs the earned cookies.
func solveChallengePage(ctx context.Context, client *http.Client, jar http.CookieJar, base, page string) error {
	pageURL := base + "/"

	prefix := fastlyChallengePrefixRe.FindString(page)
	if prefix == "" {
		return fmt.Errorf("challenge asset prefix not found on %s", base)
	}

	script, err := fetchText(ctx, client, base+prefix+"/script.js?reload=true")
	if err != nil {
		return fmt.Errorf("fetching challenge script: %w", err)
	}

	challenges, token, err := parseChallengeInitForPrefix(script, prefix)
	if err != nil {
		return err
	}

	for round := 0; round < maxPostBackRounds; round++ {
		answers := make([]interface{}, 0, len(challenges))
		for _, ch := range challenges {
			answer, err := answerChallenge(ctx, client, base+prefix, token, ch)
			if err != nil {
				return err
			}
			answers = append(answers, answer)
		}

		postBack, err := json.Marshal(fastlyPostBack{Token: token, Data: answers})
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+prefix+"/fst-post-back", strings.NewReader(string(postBack)))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", solverUserAgent())
		req.Header.Set("Origin", baseOrigin(base+prefix))

		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("challenge post-back: %w", err)
		}
		data, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if readErr != nil {
			return readErr
		}
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("challenge post-back returned HTTP %d: %s", resp.StatusCode, truncate(string(data), 256))
		}

		var pbResp fastlyPostBackResponse
		if err := json.Unmarshal(data, &pbResp); err != nil {
			return fmt.Errorf("parsing post-back response: %w", err)
		}
		if pbResp.Status == "success" {
			// Probe before installing the cookie: with rotating-exit
			// proxies the cookie may be bound to an IP the API call
			// will not reuse, and the probe catches that immediately.
			if _, stillChallenged, err := fetchChallengePage(ctx, client, pageURL); err != nil {
				return err
			} else if stillChallenged {
				return errChallengeNotAccepted
			}
			return installChallengeCookies(jar, pageURL, base+prefix)
		}
		if len(pbResp.Ch) == 0 || pbResp.Tok == "" {
			return fmt.Errorf("unexpected post-back response: %s", truncate(string(data), 256))
		}
		challenges, token = pbResp.Ch, pbResp.Tok
	}
	return fmt.Errorf("Fastly challenge did not complete within %d rounds", maxPostBackRounds)
}

// fetchChallengePage fetches pageURL and reports whether the response is a
// Fastly client-challenge page.
func fetchChallengePage(ctx context.Context, client *http.Client, pageURL string) (string, bool, error) {
	body, err := fetchText(ctx, client, pageURL)
	if err != nil {
		return "", false, err
	}
	return body, isChallengePage(body), nil
}

func fetchText(ctx context.Context, client *http.Client, rawURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", solverUserAgent())
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	resp.Body.Close()
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s returned HTTP %d", rawURL, resp.StatusCode)
	}
	return string(data), nil
}

// parseChallengeInit extracts the challenge list and the challenge token
// from the trailing init([...], "token", "prefix", ...) call in the script.
func parseChallengeInit(script string) ([]fastlyChallenge, string, error) {
	return parseChallengeInitForPrefix(script, "")
}

// parseChallengeInitForPrefix mirrors FoxyVPN v2.0.2's tolerant init-call
// parser. The challenge script's init call has drifted across Fastly
// deployments (an optional script-prefix argument, a legacy two-argument
// form, unrelated init(...) calls in the same file), and the previous
// single-regex extraction broke on the current format. Candidates are
// scanned from the last init( in the script backwards; a candidate is a
// JSON challenge array whose every item names a challenge type, followed
// by the token string and — in the three-argument form — the script
// prefix, which must match the prefix of the page being solved when one
// is known. A two-argument init([...], "token") is kept as a legacy
// fallback when no three-argument candidate validates.
func parseChallengeInitForPrefix(script, prefix string) ([]fastlyChallenge, string, error) {
	positions := fastlyInitCallRe.FindAllStringIndex(script, -1)

	type candidate struct {
		challenges []fastlyChallenge
		token      string
	}
	var legacy *candidate

	skipSpaces := func(s string) string { return strings.TrimLeft(s, " \t\r\n") }

	for i := len(positions) - 1; i >= 0; i-- {
		rest := script[positions[i][1]:]

		dec := json.NewDecoder(strings.NewReader(rest))
		var challenges []fastlyChallenge
		if err := dec.Decode(&challenges); err != nil {
			continue
		}
		if len(challenges) == 0 || len(challenges) > 16 {
			continue
		}
		valid := true
		for _, ch := range challenges {
			if ch.Ty == "" {
				valid = false
				break
			}
		}
		if !valid {
			continue
		}

		rest = skipSpaces(rest[dec.InputOffset():])
		if !strings.HasPrefix(rest, ",") {
			continue
		}
		rest = skipSpaces(rest[1:])

		tokenDec := json.NewDecoder(strings.NewReader(rest))
		var token string
		if err := tokenDec.Decode(&token); err != nil || token == "" {
			continue
		}
		rest = skipSpaces(rest[tokenDec.InputOffset():])

		if strings.HasPrefix(rest, ")") {
			// Legacy two-argument form; keep the last one in the script
			// (the first met scanning backwards) as a fallback.
			if legacy == nil {
				legacy = &candidate{challenges, token}
			}
			continue
		}
		if !strings.HasPrefix(rest, ",") {
			continue
		}
		rest = skipSpaces(rest[1:])

		thirdDec := json.NewDecoder(strings.NewReader(rest))
		var thirdRaw json.RawMessage
		if err := thirdDec.Decode(&thirdRaw); err != nil {
			continue
		}
		var thirdString string
		_ = json.Unmarshal(thirdRaw, &thirdString)
		if prefix != "" && thirdString != prefix {
			continue
		}
		rest = skipSpaces(rest[thirdDec.InputOffset():])
		if !strings.HasPrefix(rest, ")") && !strings.HasPrefix(rest, ",") {
			continue
		}
		return challenges, token, nil
	}

	if legacy != nil {
		return legacy.challenges, legacy.token, nil
	}
	return nil, "", fmt.Errorf("could not read the Fastly challenge init call in script")
}

// answerChallenge produces the fst-post-back answer payload for one
// challenge task.
func answerChallenge(ctx context.Context, client *http.Client, prefixURL, token string, ch fastlyChallenge) (interface{}, error) {
	switch ch.Ty {
	case "pow":
		var d fastlyPowData
		if err := json.Unmarshal(ch.Data, &d); err != nil {
			return nil, fmt.Errorf("parsing pow challenge: %w", err)
		}
		answer, ok := solvePow(d.Base, d.Hash)
		if !ok {
			return nil, fmt.Errorf("no proof-of-work solution found for base %q", d.Base)
		}
		return map[string]interface{}{
			"ty":      "pow",
			"base":    d.Base,
			"answer":  answer,
			"hmac":    d.HMAC,
			"expires": d.Expires,
		}, nil
	case "pat":
		auth, err := fetchPAT(ctx, client, prefixURL, token)
		if err != nil {
			return nil, err
		}
		return map[string]interface{}{"ty": "pat", "auth": auth}, nil
	case "clientmetrics":
		return clientMetricsAnswer(), nil
	case "captcha":
		solver := captchaSolverFrom(ctx)
		if solver == nil {
			return nil, fmt.Errorf("Fastly requires an image CAPTCHA; sign in from the dashboard to answer it")
		}
		var d struct {
			Image string `json:"image_b64"`
		}
		if err := json.Unmarshal(ch.Data, &d); err != nil || !strings.HasPrefix(d.Image, "data:image/") {
			return nil, fmt.Errorf("unrecognized CAPTCHA challenge data")
		}
		answer, err := solver(ctx, d.Image)
		if err != nil {
			return nil, fmt.Errorf("CAPTCHA: %w", err)
		}
		return map[string]interface{}{"ty": "captcha", "answer": strings.TrimSpace(answer)}, nil
	default:
		return nil, fmt.Errorf("unsupported Fastly challenge type %q", ch.Ty)
	}
}

// solvePow brute-forces the two-character suffix the challenge script looks
// for: SHA256(base + suffix) must equal the target hash. The search space
// is 62*62, so this is instant.
func solvePow(base, targetHex string) (string, bool) {
	target, err := hex.DecodeString(targetHex)
	if err != nil || len(target) != sha256.Size {
		return "", false
	}
	buf := make([]byte, len(base)+2)
	copy(buf, base)
	for i := 0; i < len(powAlphabet); i++ {
		buf[len(base)] = powAlphabet[i]
		for j := 0; j < len(powAlphabet); j++ {
			buf[len(base)+1] = powAlphabet[j]
			sum := sha256.Sum256(buf)
			if bytes.Equal(sum[:], target) {
				return string(buf[len(base):]), true
			}
		}
	}
	return "", false
}

// fetchPAT requests the Private Access Token for a "pat" challenge. A 401
// with a PrivateToken header means the client cannot mint a PAT (a browser
// platform feature); the challenge script aborts in that case and posts
// back an empty auth, which makes Fastly fall back to solvable challenges.
func fetchPAT(ctx context.Context, client *http.Client, prefixURL, token string) (string, error) {
	patURL := prefixURL + "/pat?token=" + url.QueryEscape(token)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, patURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "text/plain")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", solverUserAgent())
	req.Header.Set("Origin", baseOrigin(prefixURL))

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("PAT request: %w", err)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	if err != nil {
		return "", err
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusBadRequest {
		// Aborted PAT (servers answer 401 or 400 depending on client
		// fingerprint): empty auth triggers the PoW fallback server-side.
		return "", nil
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("PAT request returned HTTP %d: %s", resp.StatusCode, truncate(string(data), 256))
	}

	var out struct {
		Auth string `json:"auth"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", fmt.Errorf("parsing PAT response: %w", err)
	}
	if out.Auth == "" {
		return "", fmt.Errorf("empty PAT auth token")
	}
	return out.Auth, nil
}

// clientMetricsAnswer fabricates a benign browser-metrics payload; Mozilla's
// configuration currently issues only PAT/PoW challenges, so this path is a
// best-effort fallback.
func clientMetricsAnswer() map[string]interface{} {
	return map[string]interface{}{
		"ty":                   "clientmetrics",
		"webdriver":            false,
		"bot_detection_result": map[string]interface{}{"bot_detected": false, "bot_kind": nil},
		"browser_metrics":      map[string]interface{}{"client_data": "{}", "error_trace": nil},
		"detector_results":     map[string]interface{}{},
		"v":                    2,
	}
}

// challengeCookieHosts are the hosts the solved anti-bot cookie is
// installed for, mirroring FoxyVPN v2.0.2's install step: the FxA API and
// site hosts, the OAuth token host, and the Guardian host.
var challengeCookieHosts = []string{
	"api.accounts.firefox.com",
	"accounts.firefox.com",
	"oauth.accounts.firefox.com",
	"vpn.mozilla.org",
}

// installChallengeCookies copies the cookies earned by the solver into the
// control plane client's jar so subsequent API calls carry them. The
// original cookies are installed for the FxA hosts as before (preserving
// a Domain=firefox.com attribute when Fastly issues one); in addition,
// host-scoped copies are installed for every challenged host, as FoxyVPN
// does — a host-only cookie earned on the solving host would otherwise
// never be sent to the OAuth token endpoint or to Guardian, and those
// calls would stay challenged.
func installChallengeCookies(solverJar http.CookieJar, pageURL, prefixURL string) error {
	seen := map[string]bool{}
	var cookies []*http.Cookie
	for _, raw := range []string{pageURL, prefixURL} {
		parsed, err := url.Parse(raw)
		if err != nil {
			return err
		}
		for _, c := range solverJar.Cookies(parsed) {
			key := c.Name + "\x00" + c.Value
			if seen[key] {
				continue
			}
			seen[key] = true
			cookies = append(cookies, c)
		}
	}
	if len(cookies) == 0 {
		return fmt.Errorf("challenge completed but no cookies were issued")
	}

	apiURL, err := url.Parse(fxaAuthServer + "/")
	if err != nil {
		return err
	}
	controlplane.SetCookies(apiURL, cookies)
	siteURL, err := url.Parse(fxaSiteURL)
	if err != nil {
		return err
	}
	controlplane.SetCookies(siteURL, cookies)

	for _, host := range challengeCookieHosts {
		u := &url.URL{Scheme: "https", Host: host, Path: "/"}
		copies := make([]*http.Cookie, 0, len(cookies))
		for _, c := range cookies {
			copies = append(copies, &http.Cookie{
				Name:     c.Name,
				Value:    c.Value,
				Path:     "/",
				Secure:   c.Secure,
				HttpOnly: c.HttpOnly,
				Expires:  c.Expires,
			})
		}
		controlplane.SetCookies(u, copies)
	}
	return nil
}

// contextWithMinDeadline returns a context with at least d of deadline left.
// When the parent already has a longer deadline it is returned unchanged;
// otherwise the deadline is extended while the parent's cancellation still
// propagates.
func contextWithMinDeadline(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) >= d {
		return ctx, func() {}
	}
	extended, cancel := context.WithTimeout(context.WithoutCancel(ctx), d)
	watcherDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			cancel()
		case <-watcherDone:
		}
	}()
	return extended, func() {
		close(watcherDone)
		cancel()
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// baseOrigin derives the Origin header value for challenge requests from a
// "/_fs-ch-..." prefixed URL.
func baseOrigin(prefixURL string) string {
	if idx := strings.Index(prefixURL, "/_fs-ch-"); idx > 0 {
		return prefixURL[:idx]
	}
	return prefixURL
}
