//go:build linux

package device

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestManagedInputSessionWakeLockPrecedesConstructionAndReleasesOnFailure(t *testing.T) {
	ticker := newManualInputSessionWakeTicker()
	var events []string
	session, err := acquireManagedInputSessionWith(
		func() (*inputSessionWakeLock, error) {
			events = append(events, "acquire")
			return acquireInputSessionWakeLockWithTicker(
				func(path string, _ []byte) error {
					if path == inputSessionWakeLockPath {
						events = append(events, "lock")
					} else {
						events = append(events, "unlock")
					}
					return nil
				},
				"rmmirror-input-construction-failure",
				time.Hour,
				2*time.Hour,
				func(time.Duration) inputSessionWakeTicker { return ticker },
			)
		},
		func() (*managedInputSession, error) {
			events = append(events, "construct")
			return nil, codedError{code: "constructor_failed"}
		},
	)
	if session != nil || ErrorCode(err) != "constructor_failed" {
		t.Fatalf("session = %#v, err = %v", session, err)
	}
	want := []string{"acquire", "lock", "construct", "unlock"}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestManagedInputSessionCloseReleasesWakeLock(t *testing.T) {
	ticker := newManualInputSessionWakeTicker()
	var unlocks int
	session, err := acquireManagedInputSessionWith(
		func() (*inputSessionWakeLock, error) {
			return acquireInputSessionWakeLockWithTicker(
				func(path string, _ []byte) error {
					if path == inputSessionWakeUnlockPath {
						unlocks++
					}
					return nil
				},
				"rmmirror-input-normal-close",
				time.Hour,
				2*time.Hour,
				func(time.Duration) inputSessionWakeTicker { return ticker },
			)
		},
		func() (*managedInputSession, error) {
			return &managedInputSession{}, nil
		},
	)
	if err != nil {
		t.Fatalf("acquireManagedInputSessionWith: %v", err)
	}
	if session.wakeLock == nil {
		t.Fatal("session did not own acquired wake lock")
	}
	if err := session.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if unlocks != 1 {
		t.Fatalf("wake unlocks = %d, want 1", unlocks)
	}
	if err := session.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if unlocks != 1 {
		t.Fatalf("wake unlocks after second Close = %d, want 1", unlocks)
	}
}

func TestManagedInputSessionConstructionFailureSurfacesWakeUnlockFailure(t *testing.T) {
	ticker := newManualInputSessionWakeTicker()
	session, err := acquireManagedInputSessionWith(
		func() (*inputSessionWakeLock, error) {
			return acquireInputSessionWakeLockWithTicker(
				func(path string, _ []byte) error {
					if path == inputSessionWakeUnlockPath {
						return codedError{code: "input_wake_unlock_failed"}
					}
					return nil
				},
				"rmmirror-input-unlock-failure",
				time.Hour,
				2*time.Hour,
				func(time.Duration) inputSessionWakeTicker { return ticker },
			)
		},
		func() (*managedInputSession, error) {
			return nil, codedError{code: "constructor_failed"}
		},
	)
	if session != nil || ErrorCode(err) != "constructor_failed" {
		t.Fatalf("session = %#v, err = %v", session, err)
	}
	if !errors.Is(err, codedError{code: "input_wake_unlock_failed"}) {
		t.Fatalf("constructor error did not retain wake unlock failure: %v", err)
	}
}

func TestInputLockRejectsOverlappingSession(t *testing.T) {
	path := filepath.Join(t.TempDir(), "input.lock")
	first, err := acquireInputLock(path, false)
	if err != nil {
		t.Fatalf("first acquireInputLock returned %v", err)
	}
	defer first.Close()

	second, err := acquireInputLock(path, false)
	if second != nil {
		second.Close()
		t.Fatal("second acquireInputLock unexpectedly succeeded")
	}
	if ErrorCode(err) != "input_session_busy" {
		t.Fatalf("ErrorCode(%v) = %q, want input_session_busy", err, ErrorCode(err))
	}
}

func TestLinuxDeviceNumbersDecodeInputDevice(t *testing.T) {
	// Linux old/new device encoding for major 13, minor 66.
	device := uint64((13 << 8) | 66)
	if major := linuxDeviceMajor(device); major != 13 {
		t.Fatalf("major = %d, want 13", major)
	}
	if minor := linuxDeviceMinor(device); minor != 66 {
		t.Fatalf("minor = %d, want 66", minor)
	}
}
