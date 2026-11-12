package fxa

import "time"

// SavedTokens are an account's stored OAuth credentials.
type SavedTokens struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	Scope        string    `json:"scope"`
	ObtainedAt   time.Time `json:"obtained_at"`
	ExpiresIn    int       `json:"expires_in"`
	// ClientID is the OAuth client that minted the tokens
	// (build 2033): refresh grants are client-bound, and a
	// browser sign-in mints Fenix tokens while the password
	// flow mints desktop-client ones. "" (every pre-2033
	// record) means the desktop client.
	ClientID string `json:"client_id,omitempty"`
}
