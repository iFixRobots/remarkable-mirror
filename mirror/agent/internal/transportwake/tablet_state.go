package transportwake

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	defaultMountInfoPath               = "/proc/self/mountinfo"
	defaultTransportWakeExecutablePath = "/usr/libexec/rmmirror-transport-wake"
	defaultInspectionTimeout           = 1250 * time.Millisecond
	maxSystemctlOutput                 = 2 << 10
	maxJournalOutput                   = 32 << 10
	maxProcessCommandLine              = 4 << 10
)

type commandRunner interface {
	Output(context.Context, string, []string, int) ([]byte, error)
}

type osTabletInspector struct {
	mountInfoPath string
	readFile      func(string) ([]byte, error)
	readLink      func(string) (string, error)
	runner        commandRunner
	timeout       time.Duration
}

func newOSTabletInspector() *osTabletInspector {
	return &osTabletInspector{
		mountInfoPath: defaultMountInfoPath,
		readFile:      os.ReadFile,
		readLink:      os.Readlink,
		runner:        osCommandRunner{},
		timeout:       defaultInspectionTimeout,
	}
}

func (inspector *osTabletInspector) Inspect(ctx context.Context) (tabletObservation, error) {
	inspectionContext, cancel := context.WithTimeout(ctx, inspector.timeout)
	defer cancel()

	observation := tabletObservation{}
	var mountErr error
	mountInfo, err := inspector.readFile(inspector.mountInfoPath)
	if err != nil {
		mountErr = fmt.Errorf("inspect home mount: %w", err)
	} else {
		observation.HomeKnown = true
		observation.HomeMounted = homeIsMounted(mountInfo)
	}

	display, authoritative, displayErr := inspector.inspectDisplayState(inspectionContext)
	observation.DisplayState = display
	observation.DisplayAuthoritative = authoritative
	return observation, errors.Join(mountErr, displayErr)
}

func (inspector *osTabletInspector) inspectDisplayState(
	ctx context.Context,
) (displayState, bool, error) {
	invocationID, active, err := inspector.inspectXochitlInvocation(ctx)
	if err != nil {
		return displayUnknown, false, err
	}
	if !active {
		return displayUnknown, false, nil
	}

	transition, err := inspector.runner.Output(ctx, "journalctl", []string{
		"--quiet",
		"--no-pager",
		"--output=cat",
		"--lines=64",
		"_SYSTEMD_INVOCATION_ID=" + invocationID,
	}, maxJournalOutput)
	if err != nil {
		return displayUnknown, false, fmt.Errorf("inspect xochitl display state: %w", err)
	}
	state := parseDisplayTransition(transition)
	if state != displayDeepSleep {
		return state, false, nil
	}

	// The installed sleep guard is a long-running ExecCondition on the stock
	// suspend executor. Xochitl waits synchronously after entering DeepSleep
	// while that exact condition is running. The invocation-bound transition
	// identifies Xochitl's state, while the current systemd-owned hold removes
	// the journal's timing ambiguity. Verify the unit and exact control command,
	// then re-read both identities to close the process-replacement races.
	currentSleepHold, sleepHoldErr := inspector.inspectCurrentSystemSleepHold(ctx)
	if sleepHoldErr != nil || !currentSleepHold {
		return state, false, sleepHoldErr
	}
	currentInvocationID, stillActive, err := inspector.inspectXochitlInvocation(ctx)
	if err != nil {
		return state, false, err
	}
	return state, stillActive && currentInvocationID == invocationID, nil
}

func (inspector *osTabletInspector) inspectXochitlInvocation(
	ctx context.Context,
) (string, bool, error) {
	properties, err := inspector.runner.Output(ctx, "systemctl", []string{
		"show",
		"xochitl.service",
		"--property=ActiveState",
		"--property=InvocationID",
		"--no-pager",
	}, maxSystemctlOutput)
	if err != nil {
		return "", false, fmt.Errorf("inspect xochitl invocation: %w", err)
	}
	values := parseProperties(properties)
	invocationID := values["InvocationID"]
	if values["ActiveState"] != "active" || !validInvocationID(invocationID) {
		return "", false, nil
	}
	return invocationID, true, nil
}

type systemSleepHoldIdentity struct {
	controlPID   int
	invocationID string
}

func (inspector *osTabletInspector) inspectCurrentSystemSleepHold(
	ctx context.Context,
) (bool, error) {
	before, holding, err := inspector.inspectSystemSleepHoldIdentity(ctx)
	if err != nil || !holding {
		return false, err
	}

	executablePath := fmt.Sprintf("/proc/%d/exe", before.controlPID)
	if inspector.readLink == nil {
		return false, errors.New("inspect system sleep hold executable: reader is unavailable")
	}
	executable, err := inspector.readLink(executablePath)
	if err != nil {
		return false, fmt.Errorf("inspect system sleep hold executable: %w", err)
	}
	if executable != defaultTransportWakeExecutablePath {
		return false, nil
	}

	commandLinePath := fmt.Sprintf("/proc/%d/cmdline", before.controlPID)
	commandLine, err := inspector.readFile(commandLinePath)
	if err != nil {
		return false, fmt.Errorf("inspect system sleep hold command: %w", err)
	}
	if len(commandLine) > maxProcessCommandLine || !isTransportWakeSleepHold(commandLine) {
		return false, nil
	}

	after, stillHolding, err := inspector.inspectSystemSleepHoldIdentity(ctx)
	if err != nil {
		return false, err
	}
	return stillHolding && after == before, nil
}

func (inspector *osTabletInspector) inspectSystemSleepHoldIdentity(
	ctx context.Context,
) (systemSleepHoldIdentity, bool, error) {
	properties, err := inspector.runner.Output(ctx, "systemctl", []string{
		"show",
		guardedSystemSleepService,
		"--property=ActiveState",
		"--property=SubState",
		"--property=ControlPID",
		"--property=InvocationID",
		"--no-pager",
	}, maxSystemctlOutput)
	if err != nil {
		return systemSleepHoldIdentity{}, false,
			fmt.Errorf("inspect system sleep hold: %w", err)
	}
	values := parseProperties(properties)
	if values["ActiveState"] != "activating" || values["SubState"] != "condition" {
		return systemSleepHoldIdentity{}, false, nil
	}
	controlPID, err := strconv.Atoi(values["ControlPID"])
	if err != nil || controlPID <= 1 {
		return systemSleepHoldIdentity{}, false, nil
	}
	invocationID := values["InvocationID"]
	if !validInvocationID(invocationID) {
		return systemSleepHoldIdentity{}, false, nil
	}
	return systemSleepHoldIdentity{
		controlPID:   controlPID,
		invocationID: invocationID,
	}, true, nil
}

func isTransportWakeSleepHold(commandLine []byte) bool {
	arguments := bytes.Split(commandLine, []byte{0})
	return len(arguments) >= 3 && len(arguments[len(arguments)-1]) == 0 &&
		string(arguments[0]) == defaultTransportWakeExecutablePath &&
		string(arguments[1]) == "hold-system-sleep"
}

func homeIsMounted(mountInfo []byte) bool {
	for _, line := range bytes.Split(mountInfo, []byte{'\n'}) {
		fields := bytes.Fields(line)
		if len(fields) >= 5 && bytes.Equal(fields[4], []byte("/home")) {
			return true
		}
	}
	return false
}

func parseProperties(payload []byte) map[string]string {
	properties := make(map[string]string)
	for _, line := range strings.Split(string(payload), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			properties[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return properties
}

func validInvocationID(value string) bool {
	if len(value) != 32 {
		return false
	}
	for _, character := range value {
		if !((character >= '0' && character <= '9') ||
			(character >= 'a' && character <= 'f') ||
			(character >= 'A' && character <= 'F')) {
			return false
		}
	}
	return true
}

func parseDisplayTransition(payload []byte) displayState {
	lines := strings.Split(strings.TrimSpace(string(payload)), "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSpace(lines[index])
		switch {
		case strings.Contains(line, "-> DeepSleep"),
			strings.Contains(line, "Changing display state from Normal to DeepSleep"):
			return displayDeepSleep
		case strings.Contains(line, "-> Normal"),
			strings.Contains(line, "Changing display state from DeepSleep to Normal"):
			return displayNormal
		}
	}
	return displayUnknown
}

type osCommandRunner struct{}

func (osCommandRunner) Output(
	ctx context.Context,
	name string,
	arguments []string,
	limit int,
) ([]byte, error) {
	command := exec.CommandContext(ctx, name, arguments...)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		return nil, err
	}

	payload, readErr := io.ReadAll(io.LimitReader(stdout, int64(limit+1)))
	if len(payload) > limit {
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, errors.New("command output exceeded limit")
	}
	waitErr := command.Wait()
	if readErr != nil {
		return nil, readErr
	}
	if waitErr != nil {
		return nil, waitErr
	}
	return payload, nil
}
