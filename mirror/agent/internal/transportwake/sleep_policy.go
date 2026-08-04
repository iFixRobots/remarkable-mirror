package transportwake

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	guardedSystemSleepService = "systemd-suspend-then-hibernate.service"
	defaultSleepGuardPath     = "/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf"
)

type systemSleepPolicy interface {
	SetBlocked(bool) error
}

type sleepPolicyCommand func(context.Context, ...string) ([]byte, error)

// systemctlSleepPolicy verifies the persistent systemd executor guard while
// USB is attached. The guard itself reads the live carrier for every suspend
// attempt, so detaching restores the stock executor without changing units or
// leaving a runtime ownership marker behind.
type systemctlSleepPolicy struct {
	guardPath string
	run       sleepPolicyCommand
}

func newSystemctlSleepPolicy() systemctlSleepPolicy {
	return systemctlSleepPolicy{
		guardPath: defaultSleepGuardPath,
		run: func(ctx context.Context, arguments ...string) ([]byte, error) {
			return exec.CommandContext(ctx, "systemctl", arguments...).CombinedOutput()
		},
	}
}

func (policy systemctlSleepPolicy) SetBlocked(blocked bool) error {
	if !blocked {
		return nil
	}
	if policy.guardPath == "" {
		policy.guardPath = defaultSleepGuardPath
	}
	if policy.run == nil {
		policy.run = newSystemctlSleepPolicy().run
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := policy.run(
		ctx,
		"show",
		"--property=DropInPaths",
		"--value",
		"--",
		guardedSystemSleepService,
	)
	if ctx.Err() != nil {
		return fmt.Errorf("inspect system sleep executor guard: %w", ctx.Err())
	}
	if err != nil {
		return commandError("inspect system sleep executor guard", err, output)
	}

	wantPath := filepath.Clean(policy.guardPath)
	for _, loadedPath := range strings.Fields(string(output)) {
		if filepath.Clean(loadedPath) == wantPath {
			return nil
		}
	}
	return fmt.Errorf("system sleep executor guard is not loaded: %s", policy.guardPath)
}

func commandError(action string, err error, output []byte) error {
	detail := strings.TrimSpace(string(output))
	if len(detail) > 800 {
		detail = detail[len(detail)-800:]
	}
	if detail == "" {
		return fmt.Errorf("%s: %w", action, err)
	}
	return fmt.Errorf("%s: %w: %s", action, err, detail)
}
