package proxy

// Build 2119, audit F-01 (core half):
//   - established-session failures are counted by class,
//     separately from tunnel-open give-ups — rot that a
//     rebuild absorbed used to leave no count at all;
//   - both summaries are emitted on change by the timer
//     loop's emit step, not only on renewal outcome
//     lines (~8-minute cadence), so a ~2-minute death
//     reaches the log while it is still the story.

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/armanlife/firefox-vpn-client/core/internal/logx"
)

func TestBuild2119EstablishedFailureCounts(t *testing.T) {
	c := &Controller{}
	c.noteEstablishedFailure(errors.New("dial tcp: connection refused"))
	c.noteEstablishedFailure(errors.New("dial tcp: connection refused"))
	c.noteEstablishedFailure(nil) // never counted
	if got := c.establishedFailureSummary(); !strings.Contains(got, "=2") {
		t.Fatalf("established summary = %q, want a class counted twice", got)
	}
	// The two counters are independent: nothing was a
	// tunnel-open give-up on this controller.
	if got := c.upstreamFailureSummary(); got != "none" {
		t.Fatalf("open summary = %q, want none (counters are separate)", got)
	}
	c2 := &Controller{}
	if got := c2.establishedFailureSummary(); got != "none" {
		t.Fatalf("empty established summary = %q, want none", got)
	}
}

func TestBuild2119EstablishedFailureLogsFirstOfClass(t *testing.T) {
	var buf bytes.Buffer
	logx.SetOutput(&buf)
	defer logx.SetOutput(os.Stderr)
	c := &Controller{}
	c.noteEstablishedFailure(errors.New("boom"))
	if !strings.Contains(buf.String(), "established session failure class=") ||
		!strings.Contains(buf.String(), "count=1") {
		t.Fatalf("log = %q, want the first-of-class line", buf.String())
	}
}

func TestBuild2119FailureSummaryEmitsOnChangeOnly(t *testing.T) {
	var buf bytes.Buffer
	logx.SetOutput(&buf)
	defer logx.SetOutput(os.Stderr)
	c := &Controller{}
	// Nothing counted: the zero state is the initial
	// last-emission only after the first emit; the first
	// call records it without a duplicate on the second.
	if !c.emitUpstreamFailureSummary() {
		t.Fatalf("first emit = false, want the baseline recorded with a line")
	}
	if c.emitUpstreamFailureSummary() {
		t.Fatalf("second emit with no change = true, want silence")
	}
	c.noteUpstreamFailure(errors.New("dial tcp: connection refused"))
	c.noteEstablishedFailure(errors.New("boom"))
	if !c.emitUpstreamFailureSummary() {
		t.Fatalf("emit after new failures = false, want a line")
	}
	if !strings.Contains(buf.String(), "upstream failure summary") ||
		!strings.Contains(buf.String(), "open=") ||
		!strings.Contains(buf.String(), "established=") {
		t.Fatalf("log = %q, want one summary line carrying both counters", buf.String())
	}
	if c.emitUpstreamFailureSummary() {
		t.Fatalf("emit again with no change = true, want silence")
	}
}
