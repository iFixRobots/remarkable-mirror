//go:build linux

package device

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type inputWakeWrite struct {
	path  string
	value string
}

type manualInputSessionWakeTicker struct {
	ticks   chan time.Time
	stopped chan struct{}
	stop    sync.Once
}

func newManualInputSessionWakeTicker() *manualInputSessionWakeTicker {
	return &manualInputSessionWakeTicker{
		ticks:   make(chan time.Time, 1),
		stopped: make(chan struct{}),
	}
}

func (ticker *manualInputSessionWakeTicker) Chan() <-chan time.Time {
	return ticker.ticks
}

func (ticker *manualInputSessionWakeTicker) Stop() {
	ticker.stop.Do(func() { close(ticker.stopped) })
}

func waitForInputWakeWrite(t *testing.T, writes <-chan inputWakeWrite) inputWakeWrite {
	t.Helper()
	select {
	case write := <-writes:
		return write
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for wake-lock write")
		return inputWakeWrite{}
	}
}

func TestInputSessionWakeLockAcquiresRenewsAndReleases(t *testing.T) {
	ticker := newManualInputSessionWakeTicker()
	writes := make(chan inputWakeWrite, 3)
	lease, err := acquireInputSessionWakeLockWithTicker(
		func(path string, value []byte) error {
			writes <- inputWakeWrite{path: path, value: string(value)}
			return nil
		},
		"rmmirror-input-test",
		5*time.Millisecond,
		50*time.Millisecond,
		func(time.Duration) inputSessionWakeTicker { return ticker },
	)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	initial := waitForInputWakeWrite(t, writes)
	ticker.ticks <- time.Unix(1, 0)
	renewal := waitForInputWakeWrite(t, writes)
	if err := lease.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	release := waitForInputWakeWrite(t, writes)
	if initial.path != inputSessionWakeLockPath ||
		initial.value != "rmmirror-input-test 50000000\n" {
		t.Fatalf("initial write = %#v", initial)
	}
	if renewal != initial {
		t.Fatalf("renewal write = %#v, want %#v", renewal, initial)
	}
	if release != (inputWakeWrite{
		path: inputSessionWakeUnlockPath, value: "rmmirror-input-test\n",
	}) {
		t.Fatalf("release write = %#v", release)
	}
	select {
	case <-ticker.stopped:
	default:
		t.Fatal("ticker was not stopped")
	}
}

func TestInputSessionWakeLockPublishesRenewalFailure(t *testing.T) {
	ticker := newManualInputSessionWakeTicker()
	var lockWrites atomic.Int32
	lease, err := acquireInputSessionWakeLockWithTicker(
		func(string, []byte) error {
			if lockWrites.Add(1) == 2 {
				return errors.New("renew failed")
			}
			return nil
		},
		"rmmirror-input-renew-failure",
		5*time.Millisecond,
		50*time.Millisecond,
		func(time.Duration) inputSessionWakeTicker { return ticker },
	)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	ticker.ticks <- time.Unix(1, 0)
	select {
	case <-lease.Failed():
	case <-time.After(time.Second):
		t.Fatal("renewal failure was not published")
	}
	if ErrorCode(lease.Err()) != "input_wake_lock_failed" {
		t.Fatalf("renewal error = %v", lease.Err())
	}
	if err := lease.Close(); ErrorCode(err) != "input_wake_lock_failed" {
		t.Fatalf("close error = %v", err)
	}
}

func TestInputSessionWakeLockRefusesFailedAcquire(t *testing.T) {
	lease, err := acquireInputSessionWakeLockWith(
		func(string, []byte) error { return errors.New("write failed") },
		"rmmirror-input-acquire-failure",
		time.Second,
		2*time.Second,
	)
	if lease != nil || ErrorCode(err) != "input_wake_lock_failed" {
		t.Fatalf("lease = %#v, err = %v", lease, err)
	}
}

func TestInputSessionWakeLockReportsFailedRelease(t *testing.T) {
	writes := 0
	lease, err := acquireInputSessionWakeLockWith(
		func(string, []byte) error {
			writes++
			if writes > 1 {
				return errors.New("release failed")
			}
			return nil
		},
		"rmmirror-input-release-failure",
		time.Hour,
		2*time.Hour,
	)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := lease.Close(); ErrorCode(err) != "input_wake_unlock_failed" {
		t.Fatalf("close error = %v", err)
	}
}
