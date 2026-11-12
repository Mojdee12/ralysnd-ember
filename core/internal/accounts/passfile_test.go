package accounts

import (
	"encoding/base64"
	"fmt"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/fxa"
	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
)

func passJWT(exp time.Time) string {
	now := time.Now()
	claims := fmt.Sprintf(`{"sub":"fixture","aud":"https://vpn.mozilla.org","iss":"https://vpn.mozilla.org","iat":%d,"nbf":%d,"exp":%d}`, now.Unix(), now.Unix(), exp.Unix())
	return "e30." + base64.RawURLEncoding.EncodeToString([]byte(claims)) + ".local-only"
}

func TestPassFileRoundTrip(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	acc, _, err := store.Add("pass@example.com", &fxa.SavedTokens{
		AccessToken: "access", RefreshToken: "refresh", ObtainedAt: time.Now(), ExpiresIn: 3600,
	}, time.Now())
	if err != nil {
		t.Fatal(err)
	}

	if _, ok, err := store.LoadPass(acc.ID); err != nil || ok {
		t.Fatalf("LoadPass before save: ok=%v err=%v", ok, err)
	}

	exp := time.Now().Add(time.Hour)
	pass, err := guardian.RestorePass(passJWT(exp), "1000", "400", "2026-12-01T00:00:00Z", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SavePass(acc.ID, pass); err != nil {
		t.Fatal(err)
	}
	loaded, ok, err := store.LoadPass(acc.ID)
	if err != nil || !ok {
		t.Fatalf("LoadPass after save: ok=%v err=%v", ok, err)
	}
	if loaded.RawToken != pass.RawToken || loaded.QuotaLeft != "400" {
		t.Fatalf("round trip mismatch: %+v", loaded)
	}
	if diff := loaded.ExpiresAt().Sub(exp); diff > 2*time.Second || diff < -2*time.Second {
		t.Fatalf("expiry drifted: got %s want %s", loaded.ExpiresAt(), exp)
	}

	if err := store.DeletePass(acc.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := store.LoadPass(acc.ID); err != nil || ok {
		t.Fatalf("LoadPass after delete: ok=%v err=%v", ok, err)
	}
	// Deleting twice is not an error.
	if err := store.DeletePass(acc.ID); err != nil {
		t.Fatal(err)
	}
}

func TestPassFileRejectsBadAccount(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	pass, err := guardian.RestorePass(passJWT(time.Now().Add(time.Hour)), "", "", "", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SavePass("../escape", pass); err == nil {
		t.Fatal("SavePass accepted a path-escaping account id")
	}
}
