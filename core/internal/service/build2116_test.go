package service

// Build 2116, batch B1 (service half):
//   - B1-5 (2105-R7): the fast-failover deadline bounds
//     completions, the first establish included — an
//     attempt still running at the deadline is abandoned
//     and counts as that server's failure.
//   - B1-4: the missing-lists retry ladder — a failed
//     download with the lists still missing retries on
//     the short ladder; anything else returns to the
//     hourly check with the ladder reset.

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/armanlife/firefox-vpn-client/core/internal/proxy"
)

func TestBuild2116DeadlineBoundsFirstEstablish(t *testing.T) {
	// The establish blocks until released — far past the
	// deadline. With a nil failover the walk is exactly
	// this one attempt; the deadline must still cut it.
	release := make(chan struct{})
	establish := func(cfg proxy.ControllerConfig, _ time.Time) (*proxy.Controller, error) {
		<-release
		return nil, errors.New("late failure")
	}
	deadline := time.Now().Add(150 * time.Millisecond)
	start := time.Now()
	_, _, walked, _, err := establishWalk(
		establish, proxy.ControllerConfig{}, nil, nil, deadline,
	)
	close(release)
	if walked {
		t.Fatalf("walked = true with a nil failover")
	}
	if !errors.Is(err, errEstablishDeadline) {
		t.Fatalf("err = %v, want the deadline error", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("the attempt ran %s; the deadline did not bound it", elapsed)
	}
}

func TestBuild2116DeadlineBoundsWalkAttempts(t *testing.T) {
	// With a failover, a first server that hangs past the
	// deadline counts as its failure and the walk moves
	// on within the same budget instead of overrunning it.
	release := make(chan struct{})
	defer close(release)
	establish := func(cfg proxy.ControllerConfig, _ time.Time) (*proxy.Controller, error) {
		<-release
		return nil, errors.New("late failure")
	}
	failover := proxy.NewServerFailover(t.TempDir() + "/selection.json")
	location := []proxy.Candidate{
		{Addr: "one.example:443"},
		{Addr: "two.example:443"},
	}
	cfg := proxy.ControllerConfig{Server: location[0]}
	deadline := time.Now().Add(200 * time.Millisecond)
	start := time.Now()
	_, _, _, _, err := establishWalk(establish, cfg, failover, location, deadline)
	if err == nil {
		t.Fatalf("err = nil, want a failure")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("the walk ran %s; the deadline did not bound it", elapsed)
	}
}

func TestBuild2116WalkTriedSetIsCanonical(t *testing.T) {
	// 2105-R11: the same server spelled two ways (a bare
	// host:port and its URL form) is ONE tried entry — the
	// walk must not spend a second attempt on the duplicate.
	// A genuinely different server is still walked to.
	dead := func() (string, error) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return "", err
		}
		addr := ln.Addr().String()
		_ = ln.Close()
		return addr, nil
	}
	dead1, err := dead()
	if err != nil {
		t.Fatal(err)
	}
	dead2, err := dead()
	if err != nil {
		t.Fatal(err)
	}
	_, refused := net.DialTimeout("tcp", dead1, time.Second)
	if refused == nil {
		t.Fatal("the dead address answered")
	}
	first := proxy.Candidate{Addr: dead1}
	duplicate := proxy.Candidate{Addr: "https://" + dead1 + "/"}
	other := proxy.Candidate{Addr: dead2}
	location := []proxy.Candidate{first, duplicate, other}
	failover := proxy.NewServerFailover(t.TempDir() + "/selection.json")
	var calls []string
	establish := func(cfg proxy.ControllerConfig, _ time.Time) (*proxy.Controller, error) {
		calls = append(calls, cfg.Server.Addr)
		return nil, refused
	}
	cfg := proxy.ControllerConfig{Server: first}
	_, _, _, _, err = establishWalk(
		establish, cfg, failover, location, time.Now().Add(20*time.Second),
	)
	if err == nil {
		t.Fatal("the walk must fail when every server is dead")
	}
	if len(calls) != 2 {
		t.Fatalf("establish called %d times (%v), want 2 — the duplicate spelling must be skipped", len(calls), calls)
	}
	if calls[1] != dead2 {
		t.Fatalf("second attempt = %q, want the distinct server %q", calls[1], dead2)
	}
}

func TestBuild2116MissingRetryLadder(t *testing.T) {
	// Failure with the lists still missing: wait the
	// rung, double it, cap at the max.
	wait, next := missingRetryLadder(true, true, routingMissingRetryMin)
	if wait != routingMissingRetryMin || next != 2*routingMissingRetryMin {
		t.Fatalf("first rung: wait=%s next=%s", wait, next)
	}
	wait, next = missingRetryLadder(true, true, routingMissingRetryMax)
	if wait != routingMissingRetryMax || next != routingMissingRetryMax {
		t.Fatalf("cap: wait=%s next=%s", wait, next)
	}
	// Success, or lists present after all: hourly + reset.
	for _, tc := range [][2]bool{{false, true}, {true, false}, {false, false}} {
		wait, next = missingRetryLadder(tc[0], tc[1], 2*time.Minute)
		if wait != routingCheckInterval || next != routingMissingRetryMin {
			t.Fatalf("case %v: wait=%s next=%s, want hourly + reset", tc, wait, next)
		}
	}
}
