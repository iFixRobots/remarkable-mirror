package device

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"path"
	"strings"
)

const (
	xoviActivationSchema       = "rmmirror.xovi-activation/v1"
	xoviRootPath               = "/home/root/xovi"
	xoviActivationGuardName    = "zz-rmmirror-activation-guard.conf"
	xochitlVendorDropInName    = "xochitl-service-override.conf"
	xoviActivationGuardContent = "[Service]\nRestart=no\n"
	xochitlVendorOnFailure     = "emergency.target remarkable-fail.service"
	xochitlVendorRestart       = "on-failure"

	xoviActivationRunning          = "running"
	xoviActivationReadyAlready     = "ready_already"
	xoviActivationReadyStarted     = "ready_started"
	xoviActivationFailedUnchanged  = "failed_unchanged"
	xoviActivationFailedRolledBack = "failed_rolled_back"
	xoviActivationFailedUnknown    = "failed_unknown"
)

var xoviActivationOutcomes = map[string]bool{
	xoviActivationRunning:          true,
	xoviActivationReadyAlready:     true,
	xoviActivationReadyStarted:     true,
	xoviActivationFailedUnchanged:  true,
	xoviActivationFailedRolledBack: true,
	xoviActivationFailedUnknown:    true,
}

// XoviActivationStatus is the complete, content-free handoff between the
// detached tablet worker and the Windows client.
type XoviActivationStatus struct {
	Schema    string `json:"schema"`
	Attempt   string `json:"attempt"`
	Outcome   string `json:"outcome"`
	ErrorCode string `json:"error_code,omitempty"`
}

func newXoviActivationStatus(attempt, outcome, errorCode string) XoviActivationStatus {
	return XoviActivationStatus{
		Schema:    xoviActivationSchema,
		Attempt:   attempt,
		Outcome:   outcome,
		ErrorCode: errorCode,
	}
}

func validateXoviAttempt(attempt string) error {
	if len(attempt) != 32 {
		return codedError{code: "xovi_activation_attempt_invalid"}
	}
	for _, character := range attempt {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return codedError{code: "xovi_activation_attempt_invalid"}
		}
	}
	return nil
}

func validateXoviActivationStatus(status XoviActivationStatus) error {
	if status.Schema != xoviActivationSchema {
		return codedError{code: "xovi_activation_status_invalid"}
	}
	if err := validateXoviAttempt(status.Attempt); err != nil {
		return codedError{code: "xovi_activation_status_invalid"}
	}
	if !xoviActivationOutcomes[status.Outcome] {
		return codedError{code: "xovi_activation_status_invalid"}
	}
	failed := strings.HasPrefix(status.Outcome, "failed_")
	if failed == (status.ErrorCode == "") {
		return codedError{code: "xovi_activation_status_invalid"}
	}
	if status.ErrorCode != "" && !validXoviErrorCode(status.ErrorCode) {
		return codedError{code: "xovi_activation_status_invalid"}
	}
	return nil
}

func validXoviErrorCode(value string) bool {
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if (character < 'a' || character > 'z') &&
			(character < '0' || character > '9') && character != '_' {
			return false
		}
	}
	return true
}

func decodeXoviActivationStatus(reader io.Reader) (XoviActivationStatus, error) {
	contents, err := io.ReadAll(io.LimitReader(reader, 4097))
	if err != nil || len(contents) == 0 || len(contents) > 4096 {
		return XoviActivationStatus{}, codedError{code: "xovi_activation_status_invalid"}
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var status XoviActivationStatus
	if err := decoder.Decode(&status); err != nil {
		return XoviActivationStatus{}, codedError{code: "xovi_activation_status_invalid"}
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return XoviActivationStatus{}, codedError{code: "xovi_activation_status_invalid"}
	}
	if err := validateXoviActivationStatus(status); err != nil {
		return XoviActivationStatus{}, err
	}
	return status, nil
}

type xoviMappedRuntime uint8

const (
	xoviMappedRuntimeStock xoviMappedRuntime = iota
	xoviMappedRuntimeReady
	xoviMappedRuntimePartial
	xoviMappedRuntimeForbidden
)

type xoviRuntimeObservation struct {
	Mapped                 xoviMappedRuntime
	XochitlActive          bool
	SyncActive             bool
	BrokerInputFIFO        bool
	BrokerOutputFIFO       bool
	FilesLoopbackListening bool
}

func (observation xoviRuntimeObservation) ready() bool {
	// Xochitl 3.28 deliberately closes DeviceWebServer while the passcode is
	// locked. The Xovi mapping and input broker must remain usable so Mirror can
	// accept the unlock; Files readiness is a separate, transient capability.
	return observation.Mapped == xoviMappedRuntimeReady &&
		observation.XochitlActive && observation.SyncActive &&
		observation.BrokerInputFIFO && observation.BrokerOutputFIFO
}

func (observation xoviRuntimeObservation) filesReady() bool {
	return observation.ready() && observation.FilesLoopbackListening
}

func (observation xoviRuntimeObservation) stock() bool {
	return observation.Mapped == xoviMappedRuntimeStock &&
		observation.XochitlActive && observation.SyncActive
}

func xoviReadyFailureCode(observation xoviRuntimeObservation, observed bool) string {
	if !observed {
		return "xovi_runtime_unavailable"
	}
	switch observation.Mapped {
	case xoviMappedRuntimeStock:
		return "xovi_runtime_not_loaded"
	case xoviMappedRuntimePartial:
		return "xovi_mapping_incomplete"
	case xoviMappedRuntimeForbidden:
		return "xovi_mapping_forbidden"
	}
	if !observation.XochitlActive {
		return "xovi_xochitl_not_ready"
	}
	if !observation.SyncActive {
		return "xovi_sync_not_ready"
	}
	if !observation.BrokerInputFIFO || !observation.BrokerOutputFIFO {
		return "xovi_broker_not_ready"
	}
	return "xovi_runtime_not_ready"
}

func classifyXoviMappedRuntime(root string, maps []byte) xoviMappedRuntime {
	root = path.Clean(root)
	required := map[string]bool{
		path.Join(root, "xovi.so"):                                    false,
		path.Join(root, "extensions.d", "framebuffer-spy.so"):         false,
		path.Join(root, "extensions.d", "xovi-message-broker.so"):     false,
		path.Join(root, "extensions.d", "rmmirror-files-loopback.so"): false,
	}
	forbidden := map[string]bool{
		path.Join(root, "extensions.d", "qt-resource-rebuilder.so"): false,
		path.Join(root, "extensions.d", "webserver-remote.so"):      false,
	}

	seenRootMapping := false
	unexpectedRootMapping := false
	scanner := bufio.NewScanner(strings.NewReader(string(maps)))
	for scanner.Scan() {
		path := procMapsPath(scanner.Text())
		if path == "" || (path != root && !strings.HasPrefix(path, root+"/")) {
			continue
		}
		seenRootMapping = true
		if _, exists := forbidden[path]; exists {
			return xoviMappedRuntimeForbidden
		}
		if _, exists := required[path]; exists {
			required[path] = true
			continue
		}
		if strings.HasSuffix(path, ".so") {
			unexpectedRootMapping = true
		}
	}

	if !seenRootMapping {
		return xoviMappedRuntimeStock
	}
	if unexpectedRootMapping {
		return xoviMappedRuntimePartial
	}
	for _, present := range required {
		if !present {
			return xoviMappedRuntimePartial
		}
	}
	return xoviMappedRuntimeReady
}

func procMapsPath(line string) string {
	fields := strings.Fields(line)
	if len(fields) < 6 {
		return ""
	}
	last := fields[len(fields)-1]
	if last == "(deleted)" {
		if len(fields) < 7 {
			return ""
		}
		last = fields[len(fields)-2]
	}
	if !path.IsAbs(last) {
		return ""
	}
	return path.Clean(last)
}

func containsLoopbackFilesListener(contents []byte) bool {
	for _, line := range strings.Split(string(contents), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 4 && strings.EqualFold(fields[1], "0100007F:0050") && fields[3] == "0A" {
			return true
		}
	}
	return false
}

func xoviGuardPropertiesMatch(expected bool, onFailure, restart string) bool {
	if !xochitlVendorOnFailureMatches(onFailure) {
		return false
	}
	if expected {
		return restart == "no"
	}
	return restart == xochitlVendorRestart
}

func xochitlVendorOnFailureMatches(value string) bool {
	targets := strings.Fields(value)
	if len(targets) != 2 {
		return false
	}
	return targets[0] == "emergency.target" && targets[1] == "remarkable-fail.service" ||
		targets[0] == "remarkable-fail.service" && targets[1] == "emergency.target"
}

func xochitlFailureActionsSafe(failureAction, startLimitAction string) bool {
	return failureAction == "none" && startLimitAction == "none"
}

func mountInfoContainsTarget(contents []byte, target string) bool {
	for _, line := range strings.Split(string(contents), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 6 && fields[4] == target {
			return true
		}
	}
	return false
}

func xoviOutcomeSafeForGuardRemoval(outcome string) bool {
	return outcome == xoviActivationReadyStarted ||
		outcome == xoviActivationFailedRolledBack ||
		outcome == xoviActivationFailedUnchanged
}
