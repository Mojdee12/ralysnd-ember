package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/crypto/curve25519"
)

// WARP registration: plain WARP needs no dedicated engine — a
// device registration yields an ordinary WireGuard profile.
// This is the small, stable client-API flow the wgcf project
// documents (register a key, receive a config), implemented
// here directly: the service registers once, keeps the
// identity in its own store under ProgramData, and hands the
// shell a ready WireGuard profile that runs on the WG engine
// like any other profile. warp-plus is retired.

var warpAPIBase = "https://api.cloudflareclient.com/v0a2158"

type warpProfile struct {
	PrivateKey    string `json:"privateKey"`
	PublicKey     string `json:"publicKey"`
	ClientID      string `json:"clientId,omitempty"`
	AddressV4     string `json:"addressV4"`
	AddressV6     string `json:"addressV6,omitempty"`
	PeerPublicKey string `json:"peerPublicKey"`
	Endpoint      string `json:"endpoint"`
	AccountID     string `json:"accountId,omitempty"`
	License       string `json:"license,omitempty"`
	RegisteredAt  string `json:"registeredAt,omitempty"`
}

type warpManager struct {
	http  *http.Client
	store string // identity file path
}

func newWarpManager() *warpManager {
	dir := os.Getenv("ProgramData")
	if dir == "" {
		dir = `C:\ProgramData`
	}
	return &warpManager{
		http:  &http.Client{Timeout: 30 * time.Second},
		store: filepath.Join(dir, "Ralysnd Ember", "warp.json"),
	}
}

func (w *warpManager) stored() (*warpProfile, error) {
	b, err := os.ReadFile(w.store)
	if err != nil {
		return nil, err
	}
	var p warpProfile
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, err
	}
	if p.PrivateKey == "" || p.PeerPublicKey == "" {
		return nil, fmt.Errorf("the stored WARP identity is incomplete")
	}
	return &p, nil
}

// register returns the stored profile, or registers a fresh
// device when none exists (or force is set).
func (w *warpManager) register(force bool) (*warpProfile, error) {
	if !force {
		if p, err := w.stored(); err == nil {
			return p, nil
		}
	}
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return nil, err
	}
	// WireGuard key clamping.
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	body, err := json.Marshal(map[string]interface{}{
		"key":       base64.StdEncoding.EncodeToString(pub),
		"install_id": "",
		"fcm_token": "",
		"tos":       time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"type":      "Android",
		"model":     "PC",
		"locale":    "en_US",
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, warpAPIBase+"/reg", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "okhttp/3.12.1")
	resp, err := w.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("WARP registration request: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("WARP registration refused (HTTP %d)", resp.StatusCode)
	}
	var reg struct {
		Account struct {
			ID      string `json:"id"`
			License string `json:"license"`
		} `json:"account"`
		Config struct {
			ClientID string `json:"client_id"`
			Peers    []struct {
				PublicKey string `json:"public_key"`
				Endpoint  struct {
					Host string `json:"host"`
				} `json:"endpoint"`
			} `json:"peers"`
			Interface struct {
				Addresses struct {
					V4 string `json:"v4"`
					V6 string `json:"v6"`
				} `json:"addresses"`
			} `json:"interface"`
		} `json:"config"`
	}
	if err := json.Unmarshal(raw, &reg); err != nil {
		return nil, fmt.Errorf("WARP registration reply unreadable: %w", err)
	}
	if len(reg.Config.Peers) == 0 {
		return nil, fmt.Errorf("WARP registration reply carried no peer")
	}
	p := &warpProfile{
		PrivateKey:    base64.StdEncoding.EncodeToString(priv),
		PublicKey:     base64.StdEncoding.EncodeToString(pub),
		ClientID:      reg.Config.ClientID,
		AddressV4:     reg.Config.Interface.Addresses.V4,
		AddressV6:     reg.Config.Interface.Addresses.V6,
		PeerPublicKey: reg.Config.Peers[0].PublicKey,
		Endpoint:      reg.Config.Peers[0].Endpoint.Host,
		AccountID:     reg.Account.ID,
		License:       reg.Account.License,
		RegisteredAt:  time.Now().UTC().Format(time.RFC3339),
	}
	if err := os.MkdirAll(filepath.Dir(w.store), 0o755); err != nil {
		return nil, err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(w.store, b, 0o600); err != nil {
		return nil, err
	}
	return p, nil
}
