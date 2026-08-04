package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSystemSleepConditionBlocksOnlyAnActiveUSBCarrier(t *testing.T) {
	tests := []struct {
		name      string
		carrier   string
		exitCode  int
		wantError string
	}{
		{name: "attached", carrier: "1\n", exitCode: 1},
		{name: "detached", carrier: "0\n", exitCode: 0},
		{name: "unknown fail open", carrier: "unknown\n", exitCode: 0, wantError: "allowing stock sleep"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stderr bytes.Buffer
			exitCode := runSystemSleepCondition(
				[]string{"--carrier", "/carrier"},
				&stderr,
				func(path string) ([]byte, error) {
					if path != "/carrier" {
						t.Fatalf("read path = %q", path)
					}
					return []byte(test.carrier), nil
				},
			)
			if exitCode != test.exitCode {
				t.Fatalf("exit code = %d, want %d", exitCode, test.exitCode)
			}
			if test.wantError != "" && !strings.Contains(stderr.String(), test.wantError) {
				t.Fatalf("stderr = %q, want %q", stderr.String(), test.wantError)
			}
		})
	}
}

func TestSystemSleepConditionFailsOpenWhenCarrierCannotBeRead(t *testing.T) {
	var stderr bytes.Buffer
	exitCode := runSystemSleepCondition(
		[]string{"--carrier", "/missing"},
		&stderr,
		func(string) ([]byte, error) { return nil, os.ErrNotExist },
	)

	if exitCode != 0 {
		t.Fatalf("exit code = %d, want stock sleep allowed", exitCode)
	}
	if !strings.Contains(stderr.String(), "allowing stock sleep") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestRunDispatchesSystemSleepConditionBeforeConstructingEndpoint(t *testing.T) {
	carrierPath := filepath.Join(t.TempDir(), "carrier")
	if err := os.WriteFile(carrierPath, []byte("1\n"), 0o600); err != nil {
		t.Fatalf("write carrier: %v", err)
	}

	exitCode := run(
		context.Background(),
		[]string{"allow-system-sleep", "--carrier", carrierPath},
		io.Discard,
		io.Discard,
	)
	if exitCode != 1 {
		t.Fatalf("run exit code = %d, want ExecCondition skip code 1", exitCode)
	}
}

func TestSystemSleepHoldWaitsForUSBDetach(t *testing.T) {
	reads := 0
	waits := 0
	pings := 0
	identity := serviceWatchdogIdentity{
		MainPID:      42,
		InvocationID: strings.Repeat("a", 32),
	}
	var stderr bytes.Buffer
	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{"--carrier", "/carrier", "--poll-interval", "1s"},
		&stderr,
		func(path string) ([]byte, error) {
			if path != "/carrier" {
				t.Fatalf("read path = %q", path)
			}
			reads++
			if reads < 3 {
				return []byte("1\n"), nil
			}
			return []byte("0\n"), nil
		},
		func(context.Context, time.Duration) error {
			waits++
			return nil
		},
		func() time.Time { return time.Unix(0, 0) },
		func(_ context.Context, unit string, expected *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			if unit != "xochitl.service" {
				t.Fatalf("watchdog unit = %q", unit)
			}
			if expected != nil {
				t.Fatalf("initial watchdog identity = %+v, want nil", *expected)
			}
			pings++
			return identity, nil
		},
	)

	if exitCode != 0 {
		t.Fatalf("exit code = %d, want stock sleep released", exitCode)
	}
	if waits != 2 {
		t.Fatalf("waits = %d, want 2", waits)
	}
	if pings != 1 {
		t.Fatalf("watchdog pings = %d, want 1", pings)
	}
	if !strings.Contains(stderr.String(), "holding stock sleep") ||
		!strings.Contains(stderr.String(), "releasing stock sleep") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestSystemSleepHoldFailsOpenWithoutConfirmedCarrier(t *testing.T) {
	tests := []struct {
		name      string
		payload   string
		readError error
	}{
		{name: "detached", payload: "0\n"},
		{name: "unknown", payload: "unknown\n"},
		{name: "missing", readError: os.ErrNotExist},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			waited := false
			pinged := false
			exitCode := runSystemSleepHold(
				context.Background(),
				[]string{"--carrier", "/carrier"},
				io.Discard,
				func(string) ([]byte, error) { return []byte(test.payload), test.readError },
				func(context.Context, time.Duration) error {
					waited = true
					return nil
				},
				func() time.Time { return time.Unix(0, 0) },
				func(context.Context, string, *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
					pinged = true
					return serviceWatchdogIdentity{}, nil
				},
			)
			if exitCode != 0 {
				t.Fatalf("exit code = %d, want stock sleep allowed", exitCode)
			}
			if waited {
				t.Fatal("unconfirmed carrier unexpectedly waited")
			}
			if pinged {
				t.Fatal("unconfirmed carrier unexpectedly renewed watchdog")
			}
		})
	}
}

func TestSystemSleepHoldCancellationAlwaysSkipsExecutor(t *testing.T) {
	tests := []struct {
		name      string
		payload   string
		readError error
	}{
		{name: "attached", payload: "1\n"},
		{name: "detached", payload: "0\n"},
		{name: "unknown", payload: "unknown\n"},
		{name: "missing", readError: os.ErrNotExist},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			exitCode := runSystemSleepHold(
				ctx,
				[]string{"--carrier", "/carrier"},
				io.Discard,
				func(string) ([]byte, error) { return []byte(test.payload), test.readError },
				waitForPoll,
				func() time.Time { return time.Unix(0, 0) },
				func(context.Context, string, *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
					return serviceWatchdogIdentity{}, nil
				},
			)
			if exitCode != 1 {
				t.Fatalf("exit code = %d, want clean ExecCondition skip", exitCode)
			}
		})
	}
}

func TestSystemSleepHoldInvalidArgumentsFailOpen(t *testing.T) {
	read := false
	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{"--poll-interval", "0s"},
		io.Discard,
		func(string) ([]byte, error) {
			read = true
			return []byte("1\n"), nil
		},
		waitForPoll,
		func() time.Time { return time.Unix(0, 0) },
		func(context.Context, string, *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			return serviceWatchdogIdentity{}, nil
		},
	)
	if exitCode != 0 {
		t.Fatalf("exit code = %d, want stock sleep allowed", exitCode)
	}
	if read {
		t.Fatal("invalid arguments unexpectedly read carrier")
	}
}

func TestSystemSleepHoldSkipsExecutorWhenWatchdogCannotBeRenewed(t *testing.T) {
	waited := false
	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{"--carrier", "/carrier"},
		io.Discard,
		func(string) ([]byte, error) { return []byte("1\n"), nil },
		func(context.Context, time.Duration) error {
			waited = true
			return nil
		},
		func() time.Time { return time.Unix(0, 0) },
		func(context.Context, string, *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			return serviceWatchdogIdentity{}, errors.New("notify failed")
		},
	)
	if exitCode != 1 {
		t.Fatalf("exit code = %d, want clean ExecCondition skip", exitCode)
	}
	if waited {
		t.Fatal("watchdog failure unexpectedly continued holding sleep")
	}
}

func TestSystemSleepHoldKeepsWatchdogRenewalsOnMonotonicCadence(t *testing.T) {
	started := time.Now()
	current := started
	identity := serviceWatchdogIdentity{
		MainPID:      42,
		InvocationID: strings.Repeat("a", 32),
	}
	var pingTimes []time.Time

	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{
			"--carrier", "/carrier",
			"--poll-interval", "1s",
			"--watchdog-interval", "10s",
		},
		io.Discard,
		func(string) ([]byte, error) {
			if len(pingTimes) == 3 {
				return []byte("0\n"), nil
			}
			return []byte("1\n"), nil
		},
		func(_ context.Context, duration time.Duration) error {
			if duration != time.Second {
				t.Fatalf("poll duration = %s, want 1s", duration)
			}
			current = current.Add(duration)
			return nil
		},
		func() time.Time { return current },
		func(_ context.Context, _ string, expected *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			if len(pingTimes) == 0 {
				if expected != nil {
					t.Fatalf("initial watchdog identity = %+v, want nil", *expected)
				}
			} else if expected == nil || *expected != identity {
				t.Fatalf("renewal watchdog identity = %+v, want %+v", expected, identity)
			}
			pingTimes = append(pingTimes, current)
			// Model a slow renewal without using wall-clock sleeps. The next
			// renewal must remain anchored to this call's start time.
			current = current.Add(4 * time.Second)
			return identity, nil
		},
	)

	if exitCode != 0 {
		t.Fatalf("exit code = %d, want stock sleep released", exitCode)
	}
	wantOffsets := []time.Duration{0, 10 * time.Second, 20 * time.Second}
	if len(pingTimes) != len(wantOffsets) {
		t.Fatalf("watchdog pings = %d, want %d", len(pingTimes), len(wantOffsets))
	}
	for index, want := range wantOffsets {
		if got := pingTimes[index].Sub(started); got != want {
			t.Fatalf("watchdog ping %d offset = %s, want %s", index, got, want)
		}
	}
}

func TestSystemSleepHoldBoundsWatchdogPingWithTimeout(t *testing.T) {
	waited := false
	timedOut := false
	var stderr bytes.Buffer
	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{
			"--carrier", "/carrier",
			"--watchdog-timeout", "10ms",
		},
		&stderr,
		func(string) ([]byte, error) { return []byte("1\n"), nil },
		func(context.Context, time.Duration) error {
			waited = true
			return nil
		},
		func() time.Time { return time.Unix(0, 0) },
		func(ctx context.Context, _ string, _ *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			if _, ok := ctx.Deadline(); !ok {
				return serviceWatchdogIdentity{}, errors.New("watchdog ping context has no deadline")
			}
			select {
			case <-ctx.Done():
				timedOut = errors.Is(ctx.Err(), context.DeadlineExceeded)
				return serviceWatchdogIdentity{}, ctx.Err()
			case <-time.After(time.Second):
				return serviceWatchdogIdentity{}, errors.New("watchdog ping context did not time out")
			}
		},
	)

	if exitCode != 1 {
		t.Fatalf("exit code = %d, want clean ExecCondition skip", exitCode)
	}
	if !timedOut {
		t.Fatal("watchdog ping did not observe its configured deadline")
	}
	if waited {
		t.Fatal("timed-out watchdog ping unexpectedly continued holding sleep")
	}
	if !strings.Contains(stderr.String(), context.DeadlineExceeded.Error()) {
		t.Fatalf("stderr = %q, want deadline error", stderr.String())
	}
}

func TestSystemSleepHoldStopsWhenWatchdogInvocationIdentityChanges(t *testing.T) {
	current := time.Now()
	firstIdentity := serviceWatchdogIdentity{
		MainPID:      42,
		InvocationID: strings.Repeat("a", 32),
	}
	secondIdentity := serviceWatchdogIdentity{
		MainPID:      84,
		InvocationID: strings.Repeat("b", 32),
	}
	waits := 0
	pings := 0
	var stderr bytes.Buffer
	exitCode := runSystemSleepHold(
		context.Background(),
		[]string{
			"--carrier", "/carrier",
			"--poll-interval", "1s",
			"--watchdog-interval", "1s",
		},
		&stderr,
		func(string) ([]byte, error) { return []byte("1\n"), nil },
		func(_ context.Context, duration time.Duration) error {
			waits++
			current = current.Add(duration)
			return nil
		},
		func() time.Time { return current },
		func(_ context.Context, unit string, expected *serviceWatchdogIdentity) (serviceWatchdogIdentity, error) {
			pings++
			switch pings {
			case 1:
				if expected != nil {
					t.Fatalf("initial watchdog identity = %+v, want nil", *expected)
				}
				return firstIdentity, nil
			case 2:
				if expected == nil || *expected != firstIdentity {
					t.Fatalf("renewal watchdog identity = %+v, want %+v", expected, firstIdentity)
				}
				return serviceWatchdogIdentity{}, errors.New(
					unit + " invocation changed from 42/" + firstIdentity.InvocationID +
						" to 84/" + secondIdentity.InvocationID,
				)
			default:
				t.Fatalf("unexpected watchdog ping %d", pings)
				return serviceWatchdogIdentity{}, nil
			}
		},
	)

	if exitCode != 1 {
		t.Fatalf("exit code = %d, want clean ExecCondition skip", exitCode)
	}
	if waits != 1 || pings != 2 {
		t.Fatalf("waits/pings = %d/%d, want 1/2", waits, pings)
	}
	if !strings.Contains(stderr.String(), "invocation changed from") {
		t.Fatalf("stderr = %q, want invocation-change failure", stderr.String())
	}
}

func TestAppendWithoutNotifySocketReplacesExistingValue(t *testing.T) {
	environment := appendWithoutNotifySocket(
		[]string{"A=1", "NOTIFY_SOCKET=/old", "B=2"},
		"/run/systemd/notify",
	)
	joined := strings.Join(environment, "|")
	if joined != "A=1|B=2|NOTIFY_SOCKET=/run/systemd/notify" {
		t.Fatalf("environment = %q", joined)
	}
}

func TestRunReturnsFailureWhenWakeEndpointCannotBeConstructed(t *testing.T) {
	missingToken := filepath.Join(t.TempDir(), "missing-token")
	var stderr bytes.Buffer

	exitCode := run(
		context.Background(),
		[]string{"--wake-token", missingToken},
		io.Discard,
		&stderr,
	)

	if exitCode != 1 {
		t.Fatalf("run exit code = %d, want 1", exitCode)
	}
	if !strings.Contains(stderr.String(), "wake endpoint unavailable") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestWakeListenFlagReplacesDefaultsAndAcceptsExactPair(t *testing.T) {
	addresses := []string{"127.0.0.1:51337", "10.11.99.1:51337"}
	value := &wakeListenFlag{addresses: &addresses}
	if err := value.Set("127.0.0.1:60000"); err != nil {
		t.Fatalf("set loopback listener: %v", err)
	}
	if err := value.Set("10.11.99.1:60000"); err != nil {
		t.Fatalf("set USB listener: %v", err)
	}
	want := "127.0.0.1:60000,10.11.99.1:60000"
	if got := value.String(); got != want {
		t.Fatalf("wake listeners = %q, want %q", got, want)
	}
}

func TestSupervisePeersPropagatesEndpointFailureAndStopsPolicy(t *testing.T) {
	endpointErr := errors.New("listen failed")
	policyStopped := make(chan struct{})
	policyRun := func(ctx context.Context) error {
		<-ctx.Done()
		close(policyStopped)
		return nil
	}
	endpointRun := func(context.Context) error {
		return endpointErr
	}

	err := supervisePeers(context.Background(), policyRun, endpointRun)
	if !errors.Is(err, endpointErr) || !strings.Contains(err.Error(), "wake endpoint") {
		t.Fatalf("supervisePeers error = %v, want labeled endpoint failure", err)
	}
	select {
	case <-policyStopped:
	case <-time.After(time.Second):
		t.Fatal("policy peer was not stopped after endpoint failure")
	}
}

func TestSupervisePeersPropagatesPolicyFailureAndStopsEndpoint(t *testing.T) {
	policyErr := errors.New("policy failed")
	endpointStopped := make(chan struct{})
	policyRun := func(context.Context) error {
		return policyErr
	}
	endpointRun := func(ctx context.Context) error {
		<-ctx.Done()
		close(endpointStopped)
		return nil
	}

	err := supervisePeers(context.Background(), policyRun, endpointRun)
	if !errors.Is(err, policyErr) || !strings.Contains(err.Error(), "transport policy") {
		t.Fatalf("supervisePeers error = %v, want labeled policy failure", err)
	}
	select {
	case <-endpointStopped:
	case <-time.After(time.Second):
		t.Fatal("endpoint peer was not stopped after policy failure")
	}
}

func TestSupervisePeersTreatsUnexpectedCleanExitAsFailure(t *testing.T) {
	policyRun := func(ctx context.Context) error {
		<-ctx.Done()
		return nil
	}
	endpointRun := func(context.Context) error {
		return nil
	}

	err := supervisePeers(context.Background(), policyRun, endpointRun)
	if err == nil || !strings.Contains(err.Error(), "wake endpoint stopped unexpectedly") {
		t.Fatalf("supervisePeers error = %v, want unexpected-stop failure", err)
	}
}

func TestSupervisePeersAllowsCoordinatedCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	peerRun := func(ctx context.Context) error {
		<-ctx.Done()
		return nil
	}
	done := make(chan error, 1)
	go func() {
		done <- supervisePeers(ctx, peerRun, peerRun)
	}()

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("supervisePeers returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("supervisePeers did not return after cancellation")
	}
}
