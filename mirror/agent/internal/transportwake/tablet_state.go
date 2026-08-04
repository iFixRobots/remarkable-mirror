package transportwake

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultMountInfoPath     = "/proc/self/mountinfo"
	defaultInspectionTimeout = 750 * time.Millisecond
	maxSystemctlOutput       = 2 << 10
	maxJournalOutput         = 32 << 10
)

type commandRunner interface {
	Output(context.Context, string, []string, int) ([]byte, error)
}

type osTabletInspector struct {
	mountInfoPath string
	readFile      func(string) ([]byte, error)
	runner        commandRunner
	timeout       time.Duration
}

func newOSTabletInspector() *osTabletInspector {
	return &osTabletInspector{
		mountInfoPath: defaultMountInfoPath,
		readFile:      os.ReadFile,
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

	display, displayErr := inspector.inspectDisplayState(inspectionContext)
	observation.DisplayState = display
	return observation, errors.Join(mountErr, displayErr)
}

func (inspector *osTabletInspector) inspectDisplayState(ctx context.Context) (displayState, error) {
	properties, err := inspector.runner.Output(ctx, "systemctl", []string{
		"show",
		"xochitl.service",
		"--property=ActiveState",
		"--property=InvocationID",
		"--no-pager",
	}, maxSystemctlOutput)
	if err != nil {
		return displayUnknown, fmt.Errorf("inspect xochitl invocation: %w", err)
	}
	values := parseProperties(properties)
	invocationID := values["InvocationID"]
	if values["ActiveState"] != "active" || !validInvocationID(invocationID) {
		return displayUnknown, nil
	}

	transition, err := inspector.runner.Output(ctx, "journalctl", []string{
		"--quiet",
		"--no-pager",
		"--output=cat",
		"--lines=64",
		"_SYSTEMD_INVOCATION_ID=" + invocationID,
	}, maxJournalOutput)
	if err != nil {
		return displayUnknown, fmt.Errorf("inspect xochitl display state: %w", err)
	}
	state := parseDisplayTransition(transition)
	if state == displayUnknown {
		return displayUnknown, nil
	}
	return state, nil
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
