package main

import (
	"strings"
	"testing"
)

// Audit C6: management-protocol quoting, not Go %q.

func TestMgmtQuote(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain", "hunter2", `"hunter2"`},
		{"empty", "", `""`},
		{"embedded quote", `say "hi" now`, `"say \"hi\" now"`},
		{"backslash", `C:\path\to`, `"C:\\path\\to"`},
		{"backslash before quote", `\"`, `"\\\""`},
		// Non-ASCII passes through as UTF-8, never \u-escaped.
		{"non-ascii password", "pässwörd-密碼-پسورد", `"pässwörd-密碼-پسورد"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mgmtQuote(tc.in); got != tc.want {
				t.Fatalf("mgmtQuote(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// Review W9: the management protocol is line-delimited, so
// CR/LF in a credential would inject whole extra management
// commands. Quoting cannot fix a line break — auth must
// refuse such credentials before anything is sent.
func TestMgmtValueSafeRejectsCRLF(t *testing.T) {
	for _, in := range []string{
		"user\rname",
		"user\nname",
		"pass\r\nword",
		"trailing\n",
		"\rleading",
		"ok\"with\\escapes", // quotes/backslashes are quotable — safe
		"plain",
		"",
	} {
		want := !strings.ContainsAny(in, "\r\n")
		if got := mgmtValueSafe(in); got != want {
			t.Errorf("mgmtValueSafe(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestOvpnAuthRejectsCRLFCredentials(t *testing.T) {
	o := newOvpnManager(nil, newBroadcaster())
	// The credential check runs before the session lookup,
	// so even an unknown session surfaces the CR/LF refusal —
	// and a clean credential pair surfaces the session error,
	// proving the CR/LF cases were stopped by the new guard.
	for _, tc := range [][2]string{
		{"user\nname", "hunter2"},
		{"user", "pass\rword"},
		{"user\r\nsignal SIGTERM", "hunter2"},
	} {
		err := o.auth("nope", tc[0], tc[1])
		if err == nil || !strings.Contains(err.Error(), "CR or LF") {
			t.Errorf("auth(%q, %q) error = %v, want a CR/LF refusal", tc[0], tc[1], err)
		}
	}
	if err := o.auth("nope", "user", "hunter2"); err == nil ||
		!strings.Contains(err.Error(), "no openvpn session") {
		t.Fatalf("clean credentials error = %v, want the session lookup error", err)
	}
}

func TestOvpnAuthCommandsUseMgmtQuoting(t *testing.T) {
	cmds := ovpnAuthCommands(`user"name`, `pä\ss"1`)
	wantUser := `username "Auth" "user\"name"`
	wantPass := `password "Auth" "pä\\ss\"1"`
	if cmds[0] != wantUser {
		t.Fatalf("username line = %q, want %q", cmds[0], wantUser)
	}
	if cmds[1] != wantPass {
		t.Fatalf("password line = %q, want %q", cmds[1], wantPass)
	}
}
