package fxa

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestSolvePowFindsSuffix(t *testing.T) {
	t.Parallel()

	base := "challenge-base-string"
	target := sha256.Sum256([]byte(base + "Xk"))

	answer, ok := solvePow(base, hex.EncodeToString(target[:]))
	if !ok {
		t.Fatal("solvePow did not find a solution")
	}
	if answer != "Xk" {
		t.Fatalf("expected answer Xk, got %q", answer)
	}
}

func TestSolvePowRejectsInvalidTarget(t *testing.T) {
	t.Parallel()

	if _, ok := solvePow("base", "not-hex"); ok {
		t.Fatal("expected failure for non-hex target")
	}
	// A hash that does not end on any two-character alphanumeric suffix.
	missing := make([]byte, sha256.Size)
	if _, ok := solvePow("base-that-does-not-match", hex.EncodeToString(missing)); ok {
		t.Fatal("expected no solution for zero hash")
	}
}

func TestParseChallengeInitExtractsToken(t *testing.T) {
	t.Parallel()

	script := `var noise = {init:function(){}};something.init([1,2]);` +
		`;init([{"ty":"pat","data":{}}], "token-abc", "/_fs-ch-1T1wmsGaOgGaSxcX", true);`

	challenges, token, err := parseChallengeInit(script)
	if err != nil {
		t.Fatalf("parseChallengeInit returned error: %v", err)
	}
	if token != "token-abc" {
		t.Fatalf("expected token-abc, got %q", token)
	}
	if len(challenges) != 1 || challenges[0].Ty != "pat" {
		t.Fatalf("unexpected challenges: %+v", challenges)
	}
}

func TestParseChallengeInitPowData(t *testing.T) {
	t.Parallel()

	script := `;init([{"ty":"pow","data":{"base":"b","expires":"123","hmac":"h","hash":"00"}}], "tok", "/_fs-ch-x", true);`
	challenges, _, err := parseChallengeInit(script)
	if err != nil {
		t.Fatalf("parseChallengeInit returned error: %v", err)
	}
	if len(challenges) != 1 || challenges[0].Ty != "pow" {
		t.Fatalf("unexpected challenges: %+v", challenges)
	}

	var d fastlyPowData
	if err := json.Unmarshal(challenges[0].Data, &d); err != nil {
		t.Fatalf("unmarshalling pow data: %v", err)
	}
	if d.Base != "b" || d.HMAC != "h" || d.Expires != "123" {
		t.Fatalf("unexpected pow data: %+v", d)
	}
}

// The legacy two-argument init form (no script prefix) still parses.
func TestParseChallengeInitLegacyTwoArg(t *testing.T) {
	t.Parallel()

	script := `;init([{"ty":"pow","data":{"base":"b","expires":"1","hmac":"h","hash":"00"}}], "tok-legacy");`
	challenges, token, err := parseChallengeInit(script)
	if err != nil {
		t.Fatalf("parseChallengeInit returned error: %v", err)
	}
	if token != "tok-legacy" || len(challenges) != 1 || challenges[0].Ty != "pow" {
		t.Fatalf("unexpected result: %q %+v", token, challenges)
	}
}

// A three-argument candidate whose script prefix does not match the page
// being solved is skipped in favour of the matching one.
func TestParseChallengeInitPrefixMismatchSkipped(t *testing.T) {
	t.Parallel()

	script := `init([{"ty":"pat","data":{}}], "tok-other", "/_fs-ch-OTHER", true);` +
		`init([{"ty":"pat","data":{}}], "tok-match", "/_fs-ch-MINE", true);`
	challenges, token, err := parseChallengeInitForPrefix(script, "/_fs-ch-MINE")
	if err != nil {
		t.Fatalf("parseChallengeInitForPrefix returned error: %v", err)
	}
	if token != "tok-match" || len(challenges) != 1 {
		t.Fatalf("unexpected result: %q %+v", token, challenges)
	}
}

// Brackets inside challenge data strings must not break extraction (the
// previous regex parser stopped the challenge array at the first "]").
func TestParseChallengeInitBracketInData(t *testing.T) {
	t.Parallel()

	script := `;init([{"ty":"clientmetrics","data":{"note":"a]b"}}], "tok-b", "/_fs-ch-x", true);`
	challenges, token, err := parseChallengeInit(script)
	if err != nil {
		t.Fatalf("parseChallengeInit returned error: %v", err)
	}
	if token != "tok-b" || len(challenges) != 1 || challenges[0].Ty != "clientmetrics" {
		t.Fatalf("unexpected result: %q %+v", token, challenges)
	}
}

// Challenge pages are recognised by any of the current markers, not just
// the "Client Challenge" title.
func TestIsChallengePageMarkers(t *testing.T) {
	t.Parallel()

	if !isChallengePage(`<script src="/_fs-ch-abc/script.js"></script>`) {
		t.Fatal("script.js marker not recognised")
	}
	if !isChallengePage(`<form action="/_fs-ch-abc/fst-post-back">`) {
		t.Fatal("fst-post-back marker not recognised")
	}
	if isChallengePage(`<html>regular page</html>`) {
		t.Fatal("regular page misdetected as challenge")
	}
}

// A caller waiting for another solve gives up when its context ends, and
// leaves the slot to its holder.
func TestChallengeSlotWaiterGivesUp(t *testing.T) {
	challengeSolveSlot <- struct{}{} // another solve holds the slot
	defer func() { <-challengeSolveSlot }()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := solveFastlyChallenge(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("want DeadlineExceeded, got %v", err)
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("the waiter did not give up in time: %s", waited)
	}
	if len(challengeSolveSlot) != 1 {
		t.Fatal("the waiter must not take or release the holder's slot")
	}
}
