package transportwake

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

type commandCall struct {
	name      string
	arguments []string
	limit     int
}

type fakeCommandRunner struct {
	outputs map[string][]byte
	errors  map[string]error
	calls   []commandCall
}

func (runner *fakeCommandRunner) Output(
	_ context.Context,
	name string,
	arguments []string,
	limit int,
) ([]byte, error) {
	runner.calls = append(runner.calls, commandCall{name: name, arguments: arguments, limit: limit})
	return runner.outputs[name], runner.errors[name]
}

func TestHomeIsMountedRequiresExactMountPoint(t *testing.T) {
	mountInfo := []byte(strings.Join([]string{
		"25 1 179:2 / / rw,relatime - ext4 /dev/root rw",
		"31 25 0:29 / /home/root/.cache rw,nosuid - tmpfs tmpfs rw",
		"32 25 253:0 / /home rw,relatime - ext4 /dev/mapper/home-encrypted-disk rw",
	}, "\n"))
	if !homeIsMounted(mountInfo) {
		t.Fatal("exact /home mount was not detected")
	}
	if homeIsMounted([]byte("31 25 0:29 / /home/root/.cache rw - tmpfs tmpfs rw\n")) {
		t.Fatal("a /home submount was treated as the encrypted home mount")
	}
}

func TestInspectorUsesOnlyActiveXochitlInvocation(t *testing.T) {
	invocationID := "0123456789abcdef0123456789abcdef"
	runner := &fakeCommandRunner{
		outputs: map[string][]byte{
			"systemctl":  []byte("ActiveState=active\nInvocationID=" + invocationID + "\n"),
			"journalctl": []byte("PowerStateController: state transition Normal -> DeepSleep\n"),
		},
		errors: map[string]error{},
	}
	inspector := &osTabletInspector{
		mountInfoPath: "/mountinfo",
		readFile: func(string) ([]byte, error) {
			return []byte("32 25 253:0 / /home rw - ext4 /dev/mapper/home rw\n"), nil
		},
		runner:  runner,
		timeout: time.Second,
	}

	observation, err := inspector.Inspect(context.Background())
	if err != nil {
		t.Fatalf("Inspect returned %v", err)
	}
	want := tabletObservation{HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep}
	if !reflect.DeepEqual(observation, want) {
		t.Fatalf("observation = %#v, want %#v", observation, want)
	}
	if len(runner.calls) != 2 || runner.calls[1].name != "journalctl" {
		t.Fatalf("calls = %#v", runner.calls)
	}
	if !containsArgument(runner.calls[1].arguments, "_SYSTEMD_INVOCATION_ID="+invocationID) {
		t.Fatalf("journal arguments do not bind the current invocation: %#v", runner.calls[1].arguments)
	}
	for _, argument := range runner.calls[1].arguments {
		if strings.HasPrefix(argument, "--grep") {
			t.Fatalf("journal arguments require optional PCRE2 support: %#v", runner.calls[1].arguments)
		}
	}
}

func TestInspectorKeepsFreshActiveInvocationUnknownWithoutATransition(t *testing.T) {
	invocationID := "0123456789abcdef0123456789abcdef"
	runner := &fakeCommandRunner{
		outputs: map[string][]byte{
			"systemctl":  []byte("ActiveState=active\nInvocationID=" + invocationID + "\n"),
			"journalctl": []byte("Xochitl started without a power transition\n"),
		},
		errors: map[string]error{},
	}
	inspector := &osTabletInspector{
		mountInfoPath: "/mountinfo",
		readFile: func(string) ([]byte, error) {
			return []byte("32 25 253:0 / /home rw - ext4 /dev/mapper/home rw\n"), nil
		},
		runner:  runner,
		timeout: time.Second,
	}

	observation, err := inspector.Inspect(context.Background())
	if err != nil {
		t.Fatalf("Inspect returned %v", err)
	}
	if observation.DisplayState != displayUnknown {
		t.Fatalf("display state = %v, want Unknown", observation.DisplayState)
	}
}

func TestInspectorDoesNotUseJournalForInactiveOrInvalidInvocation(t *testing.T) {
	for _, properties := range []string{
		"ActiveState=inactive\nInvocationID=0123456789abcdef0123456789abcdef\n",
		"ActiveState=active\nInvocationID=not-an-invocation\n",
	} {
		runner := &fakeCommandRunner{
			outputs: map[string][]byte{"systemctl": []byte(properties)},
			errors:  map[string]error{},
		}
		inspector := &osTabletInspector{
			mountInfoPath: "/mountinfo",
			readFile:      func(string) ([]byte, error) { return nil, nil },
			runner:        runner,
			timeout:       time.Second,
		}

		observation, err := inspector.Inspect(context.Background())
		if err != nil {
			t.Fatalf("Inspect returned %v", err)
		}
		if observation.DisplayState != displayUnknown || len(runner.calls) != 1 {
			t.Fatalf("observation = %#v, calls = %#v", observation, runner.calls)
		}
	}
}

func TestInspectorKeepsKnownHomeStateWhenDisplayInspectionFails(t *testing.T) {
	runner := &fakeCommandRunner{
		outputs: map[string][]byte{},
		errors:  map[string]error{"systemctl": errors.New("not ready")},
	}
	inspector := &osTabletInspector{
		mountInfoPath: "/mountinfo",
		readFile:      func(string) ([]byte, error) { return []byte(""), nil },
		runner:        runner,
		timeout:       time.Second,
	}

	observation, err := inspector.Inspect(context.Background())
	if err == nil {
		t.Fatal("Inspect hid display inspection failure")
	}
	if !observation.HomeKnown || observation.HomeMounted || observation.DisplayState != displayUnknown {
		t.Fatalf("observation = %#v", observation)
	}
}

func TestParseDisplayTransitionRecognizesCurrentXochitlMessages(t *testing.T) {
	tests := []struct {
		message string
		want    displayState
	}{
		{
			message: "Changing display state from Normal to DeepSleep",
			want:    displayDeepSleep,
		},
		{
			message: "Changing display state from DeepSleep to Normal",
			want:    displayNormal,
		},
	}
	for _, test := range tests {
		if got := parseDisplayTransition([]byte(test.message)); got != test.want {
			t.Errorf("parseDisplayTransition(%q) = %v, want %v", test.message, got, test.want)
		}
	}
}

func TestParseDisplayTransitionUsesNewestRecognizedTransition(t *testing.T) {
	payload := []byte(strings.Join([]string{
		"PowerStateController: Normal -> DeepSleep",
		"Changing display state from DeepSleep to Normal",
	}, "\n"))
	if got := parseDisplayTransition(payload); got != displayNormal {
		t.Fatalf("parseDisplayTransition = %v, want Normal", got)
	}
}

func TestParseDisplayTransitionKeepsArrowCompatibility(t *testing.T) {
	if got := parseDisplayTransition([]byte("PowerStateController: Normal -> DeepSleep")); got != displayDeepSleep {
		t.Fatalf("DeepSleep arrow transition = %v, want DeepSleep", got)
	}
	if got := parseDisplayTransition([]byte("PowerStateController: DeepSleep -> Normal")); got != displayNormal {
		t.Fatalf("Normal arrow transition = %v, want Normal", got)
	}
	if got := parseDisplayTransition([]byte("unrelated output")); got != displayUnknown {
		t.Fatalf("unrelated transition = %v, want unknown", got)
	}
}

func TestInvocationIDValidationIsExact(t *testing.T) {
	if !validInvocationID("0123456789abcdef0123456789ABCDEF") {
		t.Fatal("valid systemd invocation ID was rejected")
	}
	for _, value := range []string{
		"",
		"0123456789abcdef",
		"0123456789abcdef0123456789abcdeg",
		"0123456789abcdef0123456789abcdef00",
	} {
		if validInvocationID(value) {
			t.Fatalf("invalid invocation ID %q was accepted", value)
		}
	}
}

func containsArgument(arguments []string, expected string) bool {
	for _, argument := range arguments {
		if argument == expected {
			return true
		}
	}
	return false
}
