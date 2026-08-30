package transportwake

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

type recordedSystemctlCall []string

func TestSleepPolicyConfirmsLoadedExecutorGuardWhileUSBIsAttached(t *testing.T) {
	var calls []recordedSystemctlCall
	policy := systemctlSleepPolicy{
		guardPath: "/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf",
		run: func(_ context.Context, arguments ...string) ([]byte, error) {
			calls = append(calls, append([]string(nil), arguments...))
			return []byte("/usr/lib/systemd/system/other.conf /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf\n"), nil
		},
	}

	if err := policy.SetBlocked(true); err != nil {
		t.Fatalf("SetBlocked(true) returned %v", err)
	}
	wantCalls := []recordedSystemctlCall{{
		"show",
		"--property=DropInPaths",
		"--value",
		"--",
		"systemd-suspend-then-hibernate.service",
	}}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("systemctl calls = %#v, want %#v", calls, wantCalls)
	}
}

func TestSleepPolicyAllowsStockBehaviorOnDetachWithoutChangingSystemd(t *testing.T) {
	called := false
	policy := systemctlSleepPolicy{
		run: func(_ context.Context, arguments ...string) ([]byte, error) {
			called = true
			return nil, nil
		},
	}

	if err := policy.SetBlocked(false); err != nil {
		t.Fatalf("SetBlocked(false) returned %v", err)
	}
	if called {
		t.Fatal("SetBlocked(false) changed systemd instead of relying on the live carrier condition")
	}
}

func TestSleepPolicyRejectsMissingLoadedExecutorGuard(t *testing.T) {
	policy := systemctlSleepPolicy{
		guardPath: "/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf",
		run: func(_ context.Context, arguments ...string) ([]byte, error) {
			return []byte("/usr/lib/systemd/system/other.conf\n"), nil
		},
	}

	err := policy.SetBlocked(true)
	if err == nil || !strings.Contains(err.Error(), "executor guard is not loaded") {
		t.Fatalf("SetBlocked(true) error = %v, want missing-guard error", err)
	}
}

func TestSleepPolicyReportsSystemctlFailure(t *testing.T) {
	policy := systemctlSleepPolicy{
		run: func(_ context.Context, arguments ...string) ([]byte, error) {
			return []byte("manager unavailable\n"), errors.New("exit status 1")
		},
	}

	err := policy.SetBlocked(true)
	if err == nil || !strings.Contains(err.Error(), "manager unavailable") {
		t.Fatalf("SetBlocked(true) error = %v, want systemctl detail", err)
	}
}
