package accounts

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/guardian"
	"github.com/armanlife/firefox-vpn-client/core/internal/securefile"
)

// passFileName is the persisted Guardian ProxyPass of one account
// (build 2034). It lives in the account's own directory, so Store.Remove
// deletes it with the account, and it holds ONLY the pass — Kumiho's
// prepared-pass model: with an unexpired pass stored, the engine
// connects directly without touching the region-blocked control plane.
const passFileName = "pass.json"

// passRecord is the on-disk shape of a stored pass: everything
// guardian.RestorePass needs to rebuild the ProxyPassInfo.
type passRecord struct {
	Token      string    `json:"token"`
	QuotaMax   string    `json:"quota_max,omitempty"`
	QuotaLeft  string    `json:"quota_left,omitempty"`
	QuotaReset string    `json:"quota_reset,omitempty"`
	ReceivedAt time.Time `json:"received_at"`
}

// SavePass persists the account's freshly fetched pass, replacing any
// older one. Best-effort by contract of its callers: a failed save
// only means the next start fetches again.
func (s *Store) SavePass(id string, pass *guardian.ProxyPassInfo) error {
	if err := validID(id); err != nil {
		return err
	}
	if pass == nil || pass.RawToken == "" {
		return errors.New("no pass to store")
	}
	rec := passRecord{
		Token:      pass.RawToken,
		QuotaMax:   pass.QuotaMax,
		QuotaLeft:  pass.QuotaLeft,
		QuotaReset: pass.QuotaReset,
		ReceivedAt: pass.ReceivedAt,
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := securefile.EnsurePrivateDir(filepath.Join(s.dir, id)); err != nil {
		return err
	}
	return securefile.WritePrivate(filepath.Join(s.dir, id, passFileName), append(data, '\n'))
}

// LoadPass returns the account's stored pass, rebuilt as a
// ProxyPassInfo. ok is false when no pass is stored or the record is
// damaged — a damaged record is dropped rather than retried forever.
func (s *Store) LoadPass(id string) (pass *guardian.ProxyPassInfo, ok bool, err error) {
	if err := validID(id); err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	data, err := os.ReadFile(filepath.Join(s.dir, id, passFileName))
	s.mu.Unlock()
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	var rec passRecord
	if json.Unmarshal(data, &rec) != nil || rec.Token == "" {
		_ = s.DeletePass(id)
		return nil, false, nil
	}
	restored, err := guardian.RestorePass(rec.Token, rec.QuotaMax, rec.QuotaLeft, rec.QuotaReset, rec.ReceivedAt)
	if err != nil {
		_ = s.DeletePass(id)
		return nil, false, nil
	}
	return restored, true, nil
}

// DeletePass removes the account's stored pass, if any.
func (s *Store) DeletePass(id string) error {
	if err := validID(id); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	err := os.Remove(filepath.Join(s.dir, id, passFileName))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("removing stored pass: %w", err)
	}
	return nil
}
