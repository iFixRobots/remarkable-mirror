package device

import (
	"errors"
	"reflect"
	"testing"
)

func TestIntentionalXochitlRestartClearsOnlyXochitlBudgetBeforeHandoffStart(t *testing.T) {
	var calls []systemctlCall
	run := func(action, unit string) error {
		calls = append(calls, systemctlCall{action: action, unit: unit})
		return nil
	}

	if err := runIntentionalXochitlRestartWith(run, "start", "xochitl_start_failed"); err != nil {
		t.Fatalf("runIntentionalXochitlRestartWith returned %v", err)
	}

	want := []systemctlCall{
		{action: "reset-failed", unit: xochitlService},
		{action: "start", unit: xochitlService},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("systemctl calls = %#v, want %#v", calls, want)
	}
}

func TestIntentionalXochitlRestartClearsBudgetBeforeRestorationRestart(t *testing.T) {
	var calls []systemctlCall
	run := func(action, unit string) error {
		calls = append(calls, systemctlCall{action: action, unit: unit})
		return nil
	}

	if err := runIntentionalXochitlRestartWith(run, "restart", "xochitl_restore_failed"); err != nil {
		t.Fatalf("runIntentionalXochitlRestartWith returned %v", err)
	}

	want := []systemctlCall{
		{action: "reset-failed", unit: xochitlService},
		{action: "restart", unit: xochitlService},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("systemctl calls = %#v, want %#v", calls, want)
	}
}

func TestIntentionalXochitlRestartPropagatesBudgetResetFailure(t *testing.T) {
	var calls []systemctlCall
	run := func(action, unit string) error {
		calls = append(calls, systemctlCall{action: action, unit: unit})
		return errors.New("reset failed")
	}

	err := runIntentionalXochitlRestartWith(run, "restart", "xochitl_restore_failed")
	if code := ErrorCode(err); code != "xochitl_restart_budget_reset_failed" {
		t.Fatalf("ErrorCode(%v) = %q, want xochitl_restart_budget_reset_failed", err, code)
	}

	want := []systemctlCall{{action: "reset-failed", unit: xochitlService}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("systemctl calls = %#v, want %#v", calls, want)
	}
}

func TestIntentionalXochitlRestartPropagatesActionFailure(t *testing.T) {
	var calls []systemctlCall
	run := func(action, unit string) error {
		calls = append(calls, systemctlCall{action: action, unit: unit})
		if action == "restart" {
			return errors.New("restart failed")
		}
		return nil
	}

	err := runIntentionalXochitlRestartWith(run, "restart", "xochitl_restore_failed")
	if code := ErrorCode(err); code != "xochitl_restore_failed" {
		t.Fatalf("ErrorCode(%v) = %q, want xochitl_restore_failed", err, code)
	}

	want := []systemctlCall{
		{action: "reset-failed", unit: xochitlService},
		{action: "restart", unit: xochitlService},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("systemctl calls = %#v, want %#v", calls, want)
	}
}

type systemctlCall struct {
	action string
	unit   string
}
