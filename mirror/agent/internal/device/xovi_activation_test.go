package device

import (
	"fmt"
	"strings"
	"testing"
)

const testXoviAttempt = "0123456789abcdef0123456789abcdef"

func TestValidateXoviAttemptRequiresExactLowercaseHex(t *testing.T) {
	if err := validateXoviAttempt(testXoviAttempt); err != nil {
		t.Fatalf("validateXoviAttempt(valid) returned %v", err)
	}
	for _, invalid := range []string{
		"", "0123456789abcdef", "0123456789ABCDEF0123456789ABCDEF",
		"g123456789abcdef0123456789abcdef", testXoviAttempt + "0",
	} {
		if err := validateXoviAttempt(invalid); ErrorCode(err) != "xovi_activation_attempt_invalid" {
			t.Fatalf("validateXoviAttempt(%q) error = %v, want attempt_invalid", invalid, err)
		}
	}
}

func TestValidateXoviActivationStatusEnforcesOutcomeErrorRelationship(t *testing.T) {
	valid := []XoviActivationStatus{
		newXoviActivationStatus(testXoviAttempt, xoviActivationRunning, ""),
		newXoviActivationStatus(testXoviAttempt, xoviActivationReadyAlready, ""),
		newXoviActivationStatus(testXoviAttempt, xoviActivationReadyStarted, ""),
		newXoviActivationStatus(testXoviAttempt, xoviActivationFailedUnchanged, "xovi_configuration_missing"),
		newXoviActivationStatus(testXoviAttempt, xoviActivationFailedRolledBack, "xovi_runtime_not_ready"),
		newXoviActivationStatus(testXoviAttempt, xoviActivationFailedUnknown, "xovi_rollback_failed"),
	}
	for _, status := range valid {
		if err := validateXoviActivationStatus(status); err != nil {
			t.Fatalf("validateXoviActivationStatus(%#v) returned %v", status, err)
		}
	}

	invalid := []XoviActivationStatus{
		{Schema: "wrong", Attempt: testXoviAttempt, Outcome: xoviActivationRunning},
		newXoviActivationStatus(testXoviAttempt, "ready", ""),
		newXoviActivationStatus(testXoviAttempt, xoviActivationRunning, "unexpected_error"),
		newXoviActivationStatus(testXoviAttempt, xoviActivationFailedUnknown, ""),
		newXoviActivationStatus(testXoviAttempt, xoviActivationFailedUnknown, "NOT-SANITIZED"),
	}
	for _, status := range invalid {
		if err := validateXoviActivationStatus(status); ErrorCode(err) != "xovi_activation_status_invalid" {
			t.Fatalf("validateXoviActivationStatus(%#v) error = %v, want status_invalid", status, err)
		}
	}
}

func TestDecodeXoviActivationStatusRejectsUnknownTrailingAndOversizedInput(t *testing.T) {
	validJSON := fmt.Sprintf(
		`{"schema":"%s","attempt":"%s","outcome":"running"}`,
		xoviActivationSchema,
		testXoviAttempt,
	)
	status, err := decodeXoviActivationStatus(strings.NewReader(validJSON + "\n"))
	if err != nil || status.Outcome != xoviActivationRunning {
		t.Fatalf("decode valid = %#v, %v", status, err)
	}

	for name, input := range map[string]string{
		"unknown":   strings.TrimSuffix(validJSON, "}") + `,"extra":true}`,
		"trailing":  validJSON + `{}`,
		"oversized": validJSON + strings.Repeat(" ", 4097),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeXoviActivationStatus(strings.NewReader(input)); ErrorCode(err) != "xovi_activation_status_invalid" {
				t.Fatalf("decode error = %v, want status_invalid", err)
			}
		})
	}
}

func TestClassifyXoviMappedRuntimeRequiresExactSafeSet(t *testing.T) {
	required := []string{
		"/home/root/xovi/xovi.so",
		"/home/root/xovi/extensions.d/framebuffer-spy.so",
		"/home/root/xovi/extensions.d/xovi-message-broker.so",
		"/home/root/xovi/extensions.d/rmmirror-files-loopback.so",
	}
	maps := func(paths ...string) []byte {
		lines := []string{"00400000-00500000 r-xp 00000000 00:00 0 /usr/bin/xochitl"}
		for index, value := range paths {
			lines = append(lines, fmt.Sprintf("%08x-%08x r-xp 00000000 00:00 0 %s", 0x100000+index*0x1000, 0x101000+index*0x1000, value))
		}
		return []byte(strings.Join(lines, "\n"))
	}

	if got := classifyXoviMappedRuntime(xoviRootPath, maps()); got != xoviMappedRuntimeStock {
		t.Fatalf("stock classification = %v", got)
	}
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(required...)); got != xoviMappedRuntimeReady {
		t.Fatalf("required classification = %v", got)
	}
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(required[:3]...)); got != xoviMappedRuntimePartial {
		t.Fatalf("missing required classification = %v", got)
	}
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(append(required, "/home/root/xovi/extensions.d/webserver-remote.so")...)); got != xoviMappedRuntimeForbidden {
		t.Fatalf("webserver classification = %v", got)
	}
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(append(required, "/home/root/xovi/extensions.d/qt-resource-rebuilder.so")...)); got != xoviMappedRuntimeForbidden {
		t.Fatalf("qtr classification = %v", got)
	}
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(append(required, "/home/root/xovi/extensions.d/unknown.so")...)); got != xoviMappedRuntimePartial {
		t.Fatalf("unexpected classification = %v", got)
	}

	deleted := append([]string(nil), required...)
	deleted[3] += " (deleted)"
	if got := classifyXoviMappedRuntime(xoviRootPath, maps(deleted...)); got != xoviMappedRuntimeReady {
		t.Fatalf("deleted required classification = %v", got)
	}
}

func TestXoviRuntimeObservationSeparatesExtensionAndFilesReadinessFromStock(t *testing.T) {
	ready := xoviRuntimeObservation{
		Mapped: xoviMappedRuntimeReady, XochitlActive: true, SyncActive: true,
		BrokerInputFIFO: true, BrokerOutputFIFO: true, FilesLoopbackListening: true,
	}
	if !ready.ready() || !ready.filesReady() || ready.stock() {
		t.Fatalf("ready observation classified incorrectly: %#v", ready)
	}
	ready.FilesLoopbackListening = false
	if !ready.ready() || ready.filesReady() {
		t.Fatal("locked runtime did not keep extension readiness separate from Files readiness")
	}

	stock := xoviRuntimeObservation{Mapped: xoviMappedRuntimeStock, XochitlActive: true, SyncActive: true}
	if !stock.stock() || stock.ready() {
		t.Fatalf("stock observation classified incorrectly: %#v", stock)
	}
	stock.SyncActive = false
	if stock.stock() {
		t.Fatal("stock runtime with unhealthy sync reported healthy")
	}
}

func TestContainsLoopbackFilesListenerRequiresExactListeningSocket(t *testing.T) {
	contents := []byte("  sl  local_address rem_address st\n   0: 0100007F:0050 00000000:0000 0A\n")
	if !containsLoopbackFilesListener(contents) {
		t.Fatal("exact loopback port 80 listener was not recognized")
	}
	for _, invalid := range [][]byte{
		[]byte("0: 00000000:0050 00000000:0000 0A"),
		[]byte("0: 0100007F:0050 00000000:0000 01"),
		[]byte("0: 0100007F:0016 00000000:0000 0A"),
	} {
		if containsLoopbackFilesListener(invalid) {
			t.Fatalf("invalid listener recognized: %q", invalid)
		}
	}
}

func TestXoviActivationGuardOverridesVendorOnFailureLast(t *testing.T) {
	if xoviActivationGuardName <= xochitlVendorDropInName {
		t.Fatalf("guard %q must sort after vendor drop-in %q", xoviActivationGuardName, xochitlVendorDropInName)
	}
	if xoviActivationGuardName != "zz-rmmirror-activation-guard.conf" {
		t.Fatalf("guard name = %q", xoviActivationGuardName)
	}
	if xoviActivationGuardContent != "[Service]\nRestart=no\n" {
		t.Fatalf("guard content = %q", xoviActivationGuardContent)
	}
	if xochitlVendorOnFailure != "emergency.target remarkable-fail.service" || xochitlVendorRestart != "on-failure" {
		t.Fatalf("vendor restore policy = OnFailure %q, Restart %q", xochitlVendorOnFailure, xochitlVendorRestart)
	}
	for _, test := range []struct {
		name      string
		expected  bool
		onFailure string
		restart   string
		want      bool
	}{
		{name: "guard active canonical order", expected: true, onFailure: "emergency.target remarkable-fail.service", restart: "no", want: true},
		{name: "guard active reversed order", expected: true, onFailure: "remarkable-fail.service emergency.target", restart: "no", want: true},
		{name: "guard missing vendor targets", expected: true, onFailure: "", restart: "no"},
		{name: "automatic retry still active", expected: true, onFailure: "", restart: "on-failure"},
		{name: "vendor restored canonical order", expected: false, onFailure: "emergency.target remarkable-fail.service", restart: "on-failure", want: true},
		{name: "vendor restored reversed order", expected: false, onFailure: "remarkable-fail.service emergency.target", restart: "on-failure", want: true},
		{name: "vendor OnFailure missing", expected: false, onFailure: "", restart: "on-failure"},
		{name: "vendor OnFailure target missing", expected: false, onFailure: "emergency.target", restart: "on-failure"},
		{name: "vendor OnFailure extra target", expected: false, onFailure: "emergency.target remarkable-fail.service other.target", restart: "on-failure"},
		{name: "vendor OnFailure duplicate target", expected: false, onFailure: "emergency.target emergency.target", restart: "on-failure"},
		{name: "vendor OnFailure unknown target", expected: false, onFailure: "emergency.target other.target", restart: "on-failure"},
		{name: "vendor Restart missing", expected: false, onFailure: "emergency.target remarkable-fail.service", restart: "no"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := xoviGuardPropertiesMatch(test.expected, test.onFailure, test.restart); got != test.want {
				t.Fatalf("xoviGuardPropertiesMatch() = %t, want %t", got, test.want)
			}
		})
	}
	for outcome, want := range map[string]bool{
		xoviActivationReadyStarted:     true,
		xoviActivationFailedRolledBack: true,
		xoviActivationFailedUnchanged:  true,
		xoviActivationRunning:          false,
		xoviActivationReadyAlready:     false,
		xoviActivationFailedUnknown:    false,
	} {
		if got := xoviOutcomeSafeForGuardRemoval(outcome); got != want {
			t.Fatalf("xoviOutcomeSafeForGuardRemoval(%q) = %t, want %t", outcome, got, want)
		}
	}
}

func TestXochitlFailureActionsSafe(t *testing.T) {
	for _, test := range []struct {
		failureAction    string
		startLimitAction string
		want             bool
	}{
		{failureAction: "none", startLimitAction: "none", want: true},
		{failureAction: "reboot", startLimitAction: "none"},
		{failureAction: "none", startLimitAction: "reboot"},
		{failureAction: "", startLimitAction: "none"},
	} {
		if got := xochitlFailureActionsSafe(test.failureAction, test.startLimitAction); got != test.want {
			t.Fatalf("xochitlFailureActionsSafe(%q, %q) = %t, want %t", test.failureAction, test.startLimitAction, got, test.want)
		}
	}
}

func TestMountInfoContainsTarget(t *testing.T) {
	contents := []byte("41 23 0:31 / /run rw,nosuid - tmpfs tmpfs rw\n" +
		"77 23 0:6 /null /etc/systemd/system/emergency.target rw - devtmpfs devtmpfs rw\n")
	if !mountInfoContainsTarget(contents, "/etc/systemd/system/emergency.target") {
		t.Fatal("exact emergency target mount was not recognized")
	}
	for _, target := range []string{
		"/etc/systemd/system/emergency",
		"/etc/systemd/system/emergency.target/child",
	} {
		if mountInfoContainsTarget(contents, target) {
			t.Fatalf("non-exact mount target recognized: %q", target)
		}
	}
	if !mountInfoContainsTarget(contents, "/run") {
		t.Fatal("second exact mount target was not recognized")
	}
}

func TestXoviReadyFailureCode(t *testing.T) {
	ready := xoviRuntimeObservation{
		Mapped:                 xoviMappedRuntimeReady,
		XochitlActive:          true,
		SyncActive:             true,
		BrokerInputFIFO:        true,
		BrokerOutputFIFO:       true,
		FilesLoopbackListening: true,
	}
	for _, test := range []struct {
		name        string
		observation xoviRuntimeObservation
		observed    bool
		want        string
	}{
		{name: "not observed", want: "xovi_runtime_unavailable"},
		{name: "not loaded", observation: xoviRuntimeObservation{Mapped: xoviMappedRuntimeStock}, observed: true, want: "xovi_runtime_not_loaded"},
		{name: "mapping incomplete", observation: xoviRuntimeObservation{Mapped: xoviMappedRuntimePartial}, observed: true, want: "xovi_mapping_incomplete"},
		{name: "mapping forbidden", observation: xoviRuntimeObservation{Mapped: xoviMappedRuntimeForbidden}, observed: true, want: "xovi_mapping_forbidden"},
		{name: "xochitl", observation: func() xoviRuntimeObservation { value := ready; value.XochitlActive = false; return value }(), observed: true, want: "xovi_xochitl_not_ready"},
		{name: "sync", observation: func() xoviRuntimeObservation { value := ready; value.SyncActive = false; return value }(), observed: true, want: "xovi_sync_not_ready"},
		{name: "broker", observation: func() xoviRuntimeObservation { value := ready; value.BrokerOutputFIFO = false; return value }(), observed: true, want: "xovi_broker_not_ready"},
		{name: "ready fallback", observation: ready, observed: true, want: "xovi_runtime_not_ready"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := xoviReadyFailureCode(test.observation, test.observed); got != test.want {
				t.Fatalf("xoviReadyFailureCode() = %q, want %q", got, test.want)
			}
		})
	}
}
