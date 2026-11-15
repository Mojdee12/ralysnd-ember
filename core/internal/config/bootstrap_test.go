package config

import "testing"

func TestValidateBootstrapSocks(t *testing.T) {
	valid := []string{"", "127.0.0.1:1080", "127.0.0.1:20870", "[::1]:1080", "localhost:10808"}
	for _, raw := range valid {
		if err := ValidateBootstrapSocks(raw); err != nil {
			t.Errorf("ValidateBootstrapSocks(%q) = %v, want nil", raw, err)
		}
	}
	invalid := []string{"10.0.0.5:1080", "example.com:1080", "127.0.0.1:0", "127.0.0.1:70000", "127.0.0.1", "127.0.0.1:abc", "socks5://127.0.0.1:1080"}
	for _, raw := range invalid {
		if err := ValidateBootstrapSocks(raw); err == nil {
			t.Errorf("ValidateBootstrapSocks(%q) = nil, want an error", raw)
		}
	}
}

func TestValidateBootstrapRelay(t *testing.T) {
	if err := ValidateBootstrapRelay("", ""); err != nil {
		t.Fatalf("empty pair: %v", err)
	}
	if err := ValidateBootstrapRelay("https://ember-relay.example.workers.dev", "a-key"); err != nil {
		t.Fatalf("valid pair: %v", err)
	}
	cases := [][2]string{
		{"https://relay.example", ""},            // key missing
		{"", "a-key"},                            // url missing
		{"http://relay.example", "a-key"},        // not https
		{"https://relay.example/?k=v", "a-key"},  // query
		{"https://user@relay.example", "a-key"},  // credentials
		{"https://relay.example/#frag", "a-key"}, // fragment
	}
	for _, c := range cases {
		if err := ValidateBootstrapRelay(c[0], c[1]); err == nil {
			t.Errorf("ValidateBootstrapRelay(%q, %q) = nil, want an error", c[0], c[1])
		}
	}
}
