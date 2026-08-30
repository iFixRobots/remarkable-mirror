package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/iFixRobots/remarkable-mirror/agent/internal/transportwake"
)

const version = "0.6.0"

type wakeListenFlag struct {
	addresses  *[]string
	overridden bool
}

func (value *wakeListenFlag) String() string {
	if value == nil || value.addresses == nil {
		return ""
	}
	return strings.Join(*value.addresses, ",")
}

func (value *wakeListenFlag) Set(address string) error {
	if !value.overridden {
		*value.addresses = nil
		value.overridden = true
	}
	*value.addresses = append(*value.addresses, address)
	return nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGHUP, syscall.SIGTERM)
	exitCode := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(exitCode)
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "version" || args[0] == "--version") {
		fmt.Fprintln(stdout, version)
		return 0
	}
	if len(args) > 0 && args[0] == "allow-system-sleep" {
		return runSystemSleepCondition(args[1:], stderr, os.ReadFile)
	}
	if len(args) > 0 && args[0] == "hold-system-sleep" {
		return runSystemSleepHold(ctx, args[1:], stderr, os.ReadFile, waitForPoll, time.Now, pingServiceWatchdog)
	}

	config := transportwake.DefaultConfig()
	wakeConfig := transportwake.DefaultWakeEndpointConfig()
	flags := flag.NewFlagSet("rmmirror-transport-wake", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&config.CarrierPath, "carrier", config.CarrierPath, "USB carrier sysfs path")
	flags.StringVar(&config.UDCStatePattern, "udc-state-glob", config.UDCStatePattern, "USB device-controller state sysfs glob")
	flags.StringVar(&config.PowerOnlinePath, "power-online", config.PowerOnlinePath, "USB input power online sysfs path")
	flags.StringVar(&config.WakeLockPath, "wake-lock", config.WakeLockPath, "wake-lock sysfs path")
	flags.StringVar(&config.WakeUnlockPath, "wake-unlock", config.WakeUnlockPath, "wake-unlock sysfs path")
	flags.StringVar(&config.StatusPath, "status", config.StatusPath, "runtime status path")
	flags.DurationVar(&config.PollInterval, "poll-interval", config.PollInterval, "USB carrier polling interval")
	flags.DurationVar(&config.RenewInterval, "renew-interval", config.RenewInterval, "wake-lock renewal interval")
	flags.DurationVar(&config.WakeLockTimeout, "wake-lock-timeout", config.WakeLockTimeout, "kernel wake-lock timeout")
	flags.Var(
		&wakeListenFlag{addresses: &wakeConfig.ListenAddresses},
		"wake-listen",
		"authenticated wake endpoint listen address; repeat for each allowed listener",
	)
	flags.StringVar(&wakeConfig.TokenPath, "wake-token", wakeConfig.TokenPath, "authenticated wake endpoint token path")
	flags.DurationVar(&wakeConfig.RequestTimeout, "wake-request-timeout", wakeConfig.RequestTimeout, "wake endpoint request timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return 2
	}

	wakeEndpoint, err := transportwake.NewWakeEndpoint(wakeConfig)
	if err != nil {
		fmt.Fprintf(stderr, "rmmirror-transport-wake: wake endpoint unavailable: %v\n", err)
		return 1
	}
	service, err := transportwake.New(config, wakeEndpoint, func(format string, values ...any) {
		fmt.Fprintf(stderr, "rmmirror-transport-wake: "+format+"\n", values...)
	})
	if err != nil {
		fmt.Fprintf(stderr, "rmmirror-transport-wake: configuration: %v\n", err)
		return 2
	}
	if err := supervisePeers(ctx, service.Run, wakeEndpoint.Run); err != nil {
		fmt.Fprintf(stderr, "rmmirror-transport-wake: shutdown: %v\n", err)
		return 1
	}
	return 0
}

type carrierFileReader func(string) ([]byte, error)
type pollWaiter func(context.Context, time.Duration) error
type clockNow func() time.Time
type serviceWatchdogIdentity struct {
	MainPID      int
	InvocationID string
}
type watchdogPinger func(
	context.Context,
	string,
	*serviceWatchdogIdentity,
) (serviceWatchdogIdentity, error)

// runSystemSleepCondition is the systemd ExecCondition used by the stock
// suspend-then-hibernate executor. Exit 1 skips that executor without marking
// it failed while USB is attached. Every unconfirmed carrier state fails open
// so a missing interface or detach cannot strand normal tablet sleep.
func runSystemSleepCondition(args []string, stderr io.Writer, readFile carrierFileReader) int {
	carrierPath := transportwake.DefaultConfig().CarrierPath
	udcStatePattern := ""
	flags := flag.NewFlagSet("allow-system-sleep", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&carrierPath, "carrier", carrierPath, "USB carrier sysfs path")
	flags.StringVar(&udcStatePattern, "udc-state-glob", udcStatePattern, "USB device-controller state sysfs glob")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(stderr, "rmmirror-transport-wake: invalid system sleep condition; allowing stock sleep")
		return 0
	}

	signals, signalErr := transportwake.ReadUSBSignals(
		readFile,
		carrierPath,
		udcStatePattern,
		"",
	)
	var connectionLatch transportwake.USBConnectionLatch
	connected, connectionKnown := connectionLatch.Resolve(signals)
	if !connectionKnown {
		if signalErr != nil {
			fmt.Fprintf(stderr, "rmmirror-transport-wake: USB data state unavailable; allowing stock sleep: %v\n", signalErr)
		} else {
			fmt.Fprintln(stderr, "rmmirror-transport-wake: USB data state is unknown; allowing stock sleep")
		}
		return 0
	}
	if connected {
		return 1
	}
	return 0
}

// runSystemSleepHold keeps the stock suspend executor pending while USB is
// attached. Returning immediately would make Xochitl believe the suspend cycle
// completed and wake its display again. A detach or an unconfirmed carrier
// state releases the normal system sleep path. Cancellation skips the executor
// so stopping the pending systemd job cannot accidentally start a suspend.
func runSystemSleepHold(
	ctx context.Context,
	args []string,
	stderr io.Writer,
	readFile carrierFileReader,
	wait pollWaiter,
	now clockNow,
	pingWatchdog watchdogPinger,
) int {
	carrierPath := transportwake.DefaultConfig().CarrierPath
	udcStatePattern := ""
	powerOnlinePath := ""
	pollInterval := time.Second
	watchdogInterval := 20 * time.Second
	watchdogTimeout := 5 * time.Second
	watchdogUnit := "xochitl.service"
	flags := flag.NewFlagSet("hold-system-sleep", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&carrierPath, "carrier", carrierPath, "USB carrier sysfs path")
	flags.StringVar(&udcStatePattern, "udc-state-glob", udcStatePattern, "USB device-controller state sysfs glob")
	flags.StringVar(&powerOnlinePath, "power-online", powerOnlinePath, "USB input power online sysfs path")
	flags.DurationVar(&pollInterval, "poll-interval", pollInterval, "USB carrier polling interval")
	flags.StringVar(&watchdogUnit, "watchdog-unit", watchdogUnit, "blocked caller service watchdog unit")
	flags.DurationVar(&watchdogInterval, "watchdog-interval", watchdogInterval, "blocked caller watchdog renewal interval")
	flags.DurationVar(&watchdogTimeout, "watchdog-timeout", watchdogTimeout, "caller watchdog renewal timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 ||
		pollInterval <= 0 || watchdogInterval <= 0 || watchdogTimeout <= 0 ||
		strings.TrimSpace(watchdogUnit) == "" {
		fmt.Fprintln(stderr, "rmmirror-transport-wake: invalid system sleep hold; allowing stock sleep")
		return 0
	}

	holdingLogged := false
	var connectionLatch transportwake.USBConnectionLatch
	var nextWatchdog time.Time
	var watchdogIdentity *serviceWatchdogIdentity
	for {
		if ctx.Err() != nil {
			fmt.Fprintln(stderr, "rmmirror-transport-wake: system sleep hold canceled; skipping stock sleep")
			return 1
		}
		signals, signalErr := transportwake.ReadUSBSignals(
			readFile,
			carrierPath,
			udcStatePattern,
			powerOnlinePath,
		)
		if ctx.Err() != nil {
			fmt.Fprintln(stderr, "rmmirror-transport-wake: system sleep hold canceled; skipping stock sleep")
			return 1
		}
		connected, connectionKnown := connectionLatch.Resolve(signals)
		switch {
		case !connectionKnown:
			if signalErr != nil {
				fmt.Fprintf(stderr, "rmmirror-transport-wake: USB attachment unavailable; allowing stock sleep: %v\n", signalErr)
			} else {
				fmt.Fprintln(stderr, "rmmirror-transport-wake: USB attachment is unknown; allowing stock sleep")
			}
			return 0
		case !connected:
			if holdingLogged {
				fmt.Fprintln(stderr, "rmmirror-transport-wake: qualified USB attachment ended; releasing stock sleep")
			}
			return 0
		case connected:
			if !holdingLogged {
				fmt.Fprintln(stderr, "rmmirror-transport-wake: USB data attachment qualified; holding stock sleep until powered detach")
				holdingLogged = true
			}
			pingStarted := now()
			if nextWatchdog.IsZero() || !pingStarted.Before(nextWatchdog) {
				pingContext, cancelPing := context.WithTimeout(ctx, watchdogTimeout)
				identity, err := pingWatchdog(pingContext, watchdogUnit, watchdogIdentity)
				cancelPing()
				if err != nil {
					fmt.Fprintf(stderr, "rmmirror-transport-wake: caller watchdog renewal failed; skipping stock sleep: %v\n", err)
					return 1
				}
				watchdogIdentity = &identity
				// Schedule from the start of the successful renewal rather than
				// after it completes. A slow systemd-notify call therefore consumes
				// part of the interval instead of extending the watchdog gap.
				nextWatchdog = pingStarted.Add(watchdogInterval)
			}
		}

		if err := wait(ctx, pollInterval); err != nil {
			fmt.Fprintln(stderr, "rmmirror-transport-wake: system sleep hold canceled; skipping stock sleep")
			return 1
		}
	}
}

func waitForPoll(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func pingServiceWatchdog(
	ctx context.Context,
	unit string,
	expected *serviceWatchdogIdentity,
) (serviceWatchdogIdentity, error) {
	before, err := readServiceWatchdogIdentity(ctx, unit)
	if err != nil {
		return serviceWatchdogIdentity{}, err
	}
	if expected != nil && before != *expected {
		return serviceWatchdogIdentity{}, fmt.Errorf(
			"%s invocation changed from %d/%s to %d/%s",
			unit,
			expected.MainPID,
			expected.InvocationID,
			before.MainPID,
			before.InvocationID,
		)
	}

	notify := exec.CommandContext(ctx, "/usr/bin/systemd-notify", "--pid="+strconv.Itoa(before.MainPID), "WATCHDOG=1")
	notify.Env = appendWithoutNotifySocket(os.Environ(), "/run/systemd/notify")
	if payload, err := notify.CombinedOutput(); err != nil {
		detail := strings.TrimSpace(string(payload))
		if detail == "" {
			return serviceWatchdogIdentity{}, fmt.Errorf("renew %s watchdog: %w", unit, err)
		}
		return serviceWatchdogIdentity{}, fmt.Errorf("renew %s watchdog: %w: %s", unit, err, detail)
	}
	after, err := readServiceWatchdogIdentity(ctx, unit)
	if err != nil {
		return serviceWatchdogIdentity{}, err
	}
	if after != before {
		return serviceWatchdogIdentity{}, fmt.Errorf(
			"%s invocation changed during watchdog renewal from %d/%s to %d/%s",
			unit,
			before.MainPID,
			before.InvocationID,
			after.MainPID,
			after.InvocationID,
		)
	}
	return before, nil
}

func readServiceWatchdogIdentity(ctx context.Context, unit string) (serviceWatchdogIdentity, error) {
	show := exec.CommandContext(
		ctx,
		"/usr/bin/systemctl",
		"show",
		unit,
		"--property=MainPID",
		"--property=InvocationID",
		"--property=ActiveState",
		"--property=SubState",
		"--no-pager",
	)
	payload, err := show.Output()
	if err != nil {
		return serviceWatchdogIdentity{}, fmt.Errorf("read %s watchdog identity: %w", unit, err)
	}
	properties := make(map[string]string, 4)
	for _, line := range strings.Split(string(payload), "\n") {
		name, value, found := strings.Cut(line, "=")
		if found {
			properties[name] = strings.TrimSpace(value)
		}
	}
	if properties["ActiveState"] != "active" || properties["SubState"] != "running" {
		return serviceWatchdogIdentity{}, fmt.Errorf(
			"%s is not active/running: %s/%s",
			unit,
			properties["ActiveState"],
			properties["SubState"],
		)
	}
	pidText := properties["MainPID"]
	pid, err := strconv.Atoi(pidText)
	if err != nil || pid <= 1 {
		return serviceWatchdogIdentity{}, fmt.Errorf("invalid %s main PID %q", unit, pidText)
	}
	invocationID := properties["InvocationID"]
	if len(invocationID) != 32 {
		return serviceWatchdogIdentity{}, fmt.Errorf("invalid %s invocation ID %q", unit, invocationID)
	}
	for _, character := range invocationID {
		if !strings.ContainsRune("0123456789abcdef", character) {
			return serviceWatchdogIdentity{}, fmt.Errorf("invalid %s invocation ID %q", unit, invocationID)
		}
	}
	return serviceWatchdogIdentity{MainPID: pid, InvocationID: invocationID}, nil
}

func appendWithoutNotifySocket(environment []string, notifySocket string) []string {
	result := make([]string, 0, len(environment)+1)
	for _, value := range environment {
		if !strings.HasPrefix(value, "NOTIFY_SOCKET=") {
			result = append(result, value)
		}
	}
	return append(result, "NOTIFY_SOCKET="+notifySocket)
}

type peerResult struct {
	name string
	err  error
}

func supervisePeers(
	ctx context.Context,
	transportPolicy func(context.Context) error,
	wakeEndpoint func(context.Context) error,
) error {
	peerContext, cancelPeers := context.WithCancel(ctx)
	defer cancelPeers()

	results := make(chan peerResult, 2)
	start := func(name string, run func(context.Context) error) {
		go func() {
			results <- peerResult{name: name, err: run(peerContext)}
		}()
	}
	start("wake endpoint", wakeEndpoint)
	start("transport policy", transportPolicy)

	first := <-results
	parentCanceled := ctx.Err() != nil
	cancelPeers()
	second := <-results

	var resultErr error
	if first.err != nil {
		if !parentCanceled || !errors.Is(first.err, context.Canceled) {
			resultErr = errors.Join(resultErr, fmt.Errorf("%s: %w", first.name, first.err))
		}
	} else if !parentCanceled {
		resultErr = errors.Join(resultErr, fmt.Errorf("%s stopped unexpectedly", first.name))
	}
	if second.err != nil && !errors.Is(second.err, context.Canceled) {
		resultErr = errors.Join(resultErr, fmt.Errorf("%s: %w", second.name, second.err))
	}
	return resultErr
}
