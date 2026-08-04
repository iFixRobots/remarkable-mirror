//go:build linux

package device

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	xoviActivationStatusPath = "/run/rmmirror-xovi-activation.json"
	xoviActivationLockPath   = "/run/rmmirror-xovi-activation.lock"
	xoviActivationWorkerEnv  = "RMMIRROR_XOVI_ACTIVATION_WORKER"
	xoviActivationWorkerFD   = 3

	xoviStartTimeout     = 25 * time.Second
	xoviRollbackTimeout  = 25 * time.Second
	xoviReadinessTimeout = 30 * time.Second
)

var xoviActivationGuardPath = filepath.Join(
	"/run/systemd/system/xochitl.service.d",
	xoviActivationGuardName,
)

const (
	xoviEmergencyTargetPath    = "/etc/systemd/system/emergency.target"
	xoviRemarkableFailMaskPath = "/run/systemd/system/remarkable-fail.service"
	xoviFailureMaskTarget      = "/dev/null"
	xoviProcessMountInfoPath   = "/proc/self/mountinfo"
)

func StartXoviActivation(ctx context.Context, attempt string) (XoviActivationStatus, error) {
	if err := validateXoviAttempt(attempt); err != nil {
		return XoviActivationStatus{}, err
	}
	if os.Geteuid() != 0 {
		return XoviActivationStatus{}, codedError{code: "root_required"}
	}
	if os.Getenv(xoviActivationWorkerEnv) == attempt {
		return runDetachedXoviActivation(ctx, attempt)
	}
	return launchDetachedXoviActivation(attempt)
}

func ReadXoviActivationStatus() (XoviActivationStatus, error) {
	status, err := readXoviActivationStatusFile()
	if err != nil {
		return XoviActivationStatus{}, err
	}
	if status.Outcome == xoviActivationRunning {
		held, lockErr := xoviActivationLockHeld()
		if lockErr != nil || !held {
			return XoviActivationStatus{}, codedError{code: "xovi_activation_status_stale"}
		}
	}
	return status, nil
}

func launchDetachedXoviActivation(attempt string) (XoviActivationStatus, error) {
	lock, err := acquireXoviActivationLock()
	if err != nil {
		if ErrorCode(err) == "xovi_activation_busy" {
			status, statusErr := ReadXoviActivationStatus()
			if statusErr == nil && status.Attempt == attempt && status.Outcome == xoviActivationRunning {
				return status, nil
			}
		}
		return XoviActivationStatus{}, err
	}
	defer lock.Close()

	if existing, readErr := readXoviActivationStatusFile(); readErr == nil && existing.Attempt == attempt {
		if existing.Outcome == xoviActivationRunning {
			return XoviActivationStatus{}, codedError{code: "xovi_activation_attempt_stale"}
		}
		return existing, nil
	}

	running := newXoviActivationStatus(attempt, xoviActivationRunning, "")
	if err := writeXoviActivationStatus(running); err != nil {
		return XoviActivationStatus{}, err
	}

	executable, err := os.Executable()
	if err != nil {
		failed := newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "xovi_worker_executable_failed")
		_ = writeXoviActivationStatus(failed)
		return failed, codedError{code: failed.ErrorCode}
	}
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		failed := newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "xovi_worker_start_failed")
		_ = writeXoviActivationStatus(failed)
		return failed, codedError{code: failed.ErrorCode}
	}
	defer null.Close()

	command := exec.Command(executable, "xovi-activate", "--attempt", attempt)
	command.Env = xoviActivationWorkerEnvironment(attempt)
	command.ExtraFiles = []*os.File{lock}
	command.Stdin = null
	command.Stdout = null
	command.Stderr = null
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		failed := newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "xovi_worker_start_failed")
		_ = writeXoviActivationStatus(failed)
		return failed, codedError{code: failed.ErrorCode}
	}
	if err := command.Process.Release(); err != nil {
		// The child is already detached. The runtime status remains authoritative.
		return running, nil
	}
	return running, nil
}

func xoviActivationWorkerEnvironment(attempt string) []string {
	prefix := xoviActivationWorkerEnv + "="
	environment := make([]string, 0, len(os.Environ())+1)
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, prefix) {
			environment = append(environment, value)
		}
	}
	return append(environment, prefix+attempt)
}

func runDetachedXoviActivation(ctx context.Context, attempt string) (result XoviActivationStatus, resultErr error) {
	lock, err := inheritedXoviActivationLock()
	if err != nil {
		return XoviActivationStatus{}, err
	}
	defer lock.Close()
	wakeLock, err := acquireInputSessionWakeLock()
	if err != nil {
		result = newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "input_wake_lock_failed")
		if writeErr := writeXoviActivationStatus(result); writeErr != nil {
			return result, writeErr
		}
		return result, nil
	}
	activationContext, cancelActivation := context.WithCancel(ctx)
	wakeMonitorDone := make(chan struct{})
	go func() {
		defer close(wakeMonitorDone)
		select {
		case <-wakeLock.Failed():
			cancelActivation()
		case <-activationContext.Done():
		}
	}()

	defer func() {
		if recovered := recover(); recovered != nil {
			result = newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_worker_failed")
			resultErr = nil
		}
		if result.Schema == "" {
			result = newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_worker_failed")
		}
		cancelActivation()
		<-wakeMonitorDone
		wakeErr := wakeLock.Err()
		if wakeErr != nil {
			result = xoviStatusAfterWakeFailure(attempt, result)
		}
		closeErr := wakeLock.Close()
		if wakeErr == nil && ErrorCode(closeErr) == "input_wake_lock_failed" {
			result = xoviStatusAfterWakeFailure(attempt, result)
		} else if closeErr != nil && ErrorCode(closeErr) != "input_wake_lock_failed" {
			result = newXoviActivationStatus(attempt, xoviActivationFailedUnknown, ErrorCode(closeErr))
		}
		if err := writeXoviActivationStatus(result); err != nil {
			resultErr = err
		}
	}()

	result = executeXoviActivation(activationContext, attempt)
	return result, nil
}

func xoviStatusAfterWakeFailure(attempt string, status XoviActivationStatus) XoviActivationStatus {
	switch status.Outcome {
	case xoviActivationReadyStarted:
		guardContext, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		guardErr := installXoviActivationGuard(guardContext)
		cancel()
		if guardErr != nil {
			return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "input_wake_lock_failed")
		}
		rolledBack := rollbackXoviActivation(attempt, "input_wake_lock_failed")
		if xoviOutcomeSafeForGuardRemoval(rolledBack.Outcome) {
			if err := removeXoviActivationGuard(); err != nil {
				return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, ErrorCode(err))
			}
		}
		return rolledBack
	case xoviActivationFailedRolledBack:
		return newXoviActivationStatus(attempt, xoviActivationFailedRolledBack, "input_wake_lock_failed")
	case xoviActivationReadyAlready, xoviActivationFailedUnchanged:
		return newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "input_wake_lock_failed")
	default:
		return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "input_wake_lock_failed")
	}
}

func executeXoviActivation(ctx context.Context, attempt string) (result XoviActivationStatus) {
	baseline, err := observeXoviRuntime(ctx)
	if err != nil {
		return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_runtime_unavailable")
	}
	if err := validateXoviConfiguration(); err != nil {
		outcome := xoviActivationFailedUnknown
		if baseline.stock() || baseline.ready() {
			outcome = xoviActivationFailedUnchanged
		}
		return newXoviActivationStatus(attempt, outcome, ErrorCode(err))
	}
	if baseline.ready() {
		if err := removeXoviActivationGuard(); err != nil {
			return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, ErrorCode(err))
		}
		return newXoviActivationStatus(attempt, xoviActivationReadyAlready, "")
	}
	if !baseline.stock() {
		return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_baseline_not_stock")
	}
	if err := installXoviActivationGuard(ctx); err != nil {
		outcome := xoviActivationFailedUnchanged
		if ErrorCode(err) == "xovi_guard_state_unknown" {
			outcome = xoviActivationFailedUnknown
		}
		return newXoviActivationStatus(attempt, outcome, ErrorCode(err))
	}
	guardInstalled := true
	mutationStarted := false
	defer func() {
		if recovered := recover(); recovered != nil {
			if mutationStarted {
				result = rollbackXoviActivation(attempt, "xovi_worker_failed")
			} else {
				result = newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "xovi_worker_failed")
			}
		}
		if guardInstalled && xoviOutcomeSafeForGuardRemoval(result.Outcome) {
			if err := removeXoviActivationGuard(); err != nil {
				result = newXoviActivationStatus(attempt, xoviActivationFailedUnknown, ErrorCode(err))
			}
		}
	}()
	if ctx.Err() != nil {
		return newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, "xovi_activation_cancelled")
	}
	if err := resetXochitlRestartBudget(ctx); err != nil {
		return newXoviActivationStatus(attempt, xoviActivationFailedUnchanged, ErrorCode(err))
	}

	mutationStarted = true
	startErr := runBoundedProcess(ctx, xoviStartTimeout, filepath.Join(xoviRootPath, "start"))
	ready, readinessErr := waitForXoviRuntime(ctx, xoviReadinessTimeout, true)
	if ready {
		return newXoviActivationStatus(attempt, xoviActivationReadyStarted, "")
	}
	failureCode := ErrorCode(readinessErr)
	if failureCode == "" {
		failureCode = "xovi_runtime_not_ready"
	}
	if startErr != nil {
		failureCode = "xovi_start_failed"
	}
	return rollbackXoviActivation(attempt, failureCode)
}

func rollbackXoviActivation(attempt, failureCode string) XoviActivationStatus {
	rollbackContext, cancel := context.WithTimeout(context.Background(), 55*time.Second)
	defer cancel()
	if err := resetXochitlRestartBudget(rollbackContext); err != nil {
		return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_rollback_budget_reset_failed")
	}
	_ = runBoundedProcess(rollbackContext, xoviRollbackTimeout, filepath.Join(xoviRootPath, "stock"))
	if stock, _ := waitForXoviRuntime(rollbackContext, xoviReadinessTimeout, false); stock {
		return newXoviActivationStatus(attempt, xoviActivationFailedRolledBack, failureCode)
	}
	return newXoviActivationStatus(attempt, xoviActivationFailedUnknown, "xovi_rollback_failed")
}

func installXoviActivationGuard(ctx context.Context) error {
	directory := filepath.Dir(xoviActivationGuardPath)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || !rootOwnedInfo(info) {
		return codedError{code: "xovi_guard_install_failed"}
	}

	if existing, readErr := os.ReadFile(xoviActivationGuardPath); readErr == nil {
		guardInfo, statErr := os.Lstat(xoviActivationGuardPath)
		if statErr != nil || !guardInfo.Mode().IsRegular() || guardInfo.Mode().Perm() != 0o644 || !rootOwnedInfo(guardInfo) ||
			string(existing) != xoviActivationGuardContent {
			return codedError{code: "xovi_guard_conflict"}
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return codedError{code: "xovi_guard_conflict"}
	} else if err := writeAtomicXoviGuard(); err != nil {
		return err
	}
	if err := installXoviFailureMasks(ctx); err != nil {
		if cleanupErr := removeXoviActivationGuard(); cleanupErr != nil {
			return codedError{code: "xovi_guard_state_unknown"}
		}
		return err
	}

	if err := reloadAndVerifyXoviGuard(ctx, true); err != nil {
		if cleanupErr := removeXoviActivationGuard(); cleanupErr != nil {
			return codedError{code: "xovi_guard_state_unknown"}
		}
		return err
	}
	return nil
}

func writeAtomicXoviGuard() error {
	directory := filepath.Dir(xoviActivationGuardPath)
	temporary, err := os.CreateTemp(directory, ".rmmirror-activation-guard-*")
	if err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o644); err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	if _, err := io.WriteString(temporary, xoviActivationGuardContent); err != nil ||
		temporary.Sync() != nil || temporary.Close() != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	if err := os.Rename(temporaryPath, xoviActivationGuardPath); err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	committed = true
	return nil
}

func removeXoviActivationGuard() error {
	guardPresent := false
	info, err := os.Lstat(xoviActivationGuardPath)
	if err == nil {
		contents, readErr := os.ReadFile(xoviActivationGuardPath)
		if readErr != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o644 || !rootOwnedInfo(info) ||
			string(contents) != xoviActivationGuardContent {
			return codedError{code: "xovi_guard_conflict"}
		}
		guardPresent = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	if err := removeXoviFailureMasks(); err != nil {
		return err
	}
	if guardPresent {
		if err := os.Remove(xoviActivationGuardPath); err != nil {
			return codedError{code: "xovi_guard_cleanup_failed"}
		}
	}

	cleanupContext, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if err := reloadAndVerifyXoviGuard(cleanupContext, false); err != nil {
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	return nil
}

func reloadAndVerifyXoviGuard(ctx context.Context, expected bool) error {
	if err := runBoundedProcess(ctx, 8*time.Second, "systemctl", "daemon-reload"); err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	dropIns, err := runBoundedProcessOutput(
		ctx,
		3*time.Second,
		256,
		"systemctl", "show", "--property=DropInPaths", "--value", xochitlService,
	)
	dropInText := strings.TrimSpace(string(dropIns))
	if err != nil || strings.ContainsAny(dropInText, "\r\n") {
		return codedError{code: "xovi_guard_install_failed"}
	}
	loaded := strings.Contains(dropInText, xoviActivationGuardPath)
	if loaded != expected {
		return codedError{code: "xovi_guard_install_failed"}
	}
	onFailure, err := readXochitlUnitProperty(ctx, "OnFailure")
	if err != nil {
		return codedError{code: "xovi_guard_ineffective"}
	}
	restart, err := readXochitlUnitProperty(ctx, "Restart")
	if err != nil {
		return codedError{code: "xovi_guard_ineffective"}
	}
	if !xoviGuardPropertiesMatch(expected, onFailure, restart) {
		if expected {
			return codedError{code: "xovi_guard_ineffective"}
		}
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	failureAction, err := readXochitlUnitProperty(ctx, "FailureAction")
	if err != nil {
		return codedError{code: "xovi_guard_ineffective"}
	}
	startLimitAction, err := readXochitlUnitProperty(ctx, "StartLimitAction")
	if err != nil || !xochitlFailureActionsSafe(failureAction, startLimitAction) {
		if expected {
			return codedError{code: "xovi_guard_ineffective"}
		}
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	emergencyLoadState, err := readUnitProperty(ctx, "emergency.target", "LoadState")
	if err != nil {
		return codedError{code: "xovi_guard_ineffective"}
	}
	remarkableFailLoadState, err := readUnitProperty(ctx, "remarkable-fail.service", "LoadState")
	if err != nil {
		return codedError{code: "xovi_guard_ineffective"}
	}
	filesystemMasksMatch, err := xoviFailureMasksMatch(expected)
	if err != nil || !filesystemMasksMatch ||
		(expected && (emergencyLoadState != "masked" || remarkableFailLoadState != "masked")) ||
		(!expected && (emergencyLoadState == "masked" || remarkableFailLoadState == "masked")) {
		if expected {
			return codedError{code: "xovi_guard_ineffective"}
		}
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	return nil
}

func readXochitlUnitProperty(ctx context.Context, property string) (string, error) {
	return readUnitProperty(ctx, xochitlService, property)
}

func readUnitProperty(ctx context.Context, unit, property string) (string, error) {
	value, err := runBoundedProcessOutput(
		ctx,
		3*time.Second,
		128,
		"systemctl", "show", "--property="+property, "--value", unit,
	)
	if err != nil {
		return "", err
	}
	trimmed := strings.TrimSpace(string(value))
	if strings.ContainsAny(trimmed, "\r\n") {
		return "", codedError{code: "xovi_guard_property_invalid"}
	}
	return trimmed, nil
}

func installXoviFailureMasks(ctx context.Context) error {
	mounted, err := xoviEmergencyTargetMounted()
	if err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	if mounted {
		if !xoviEmergencyTargetIsDevNull() {
			return codedError{code: "xovi_guard_conflict"}
		}
	} else {
		if !xoviEmergencyTargetOriginal() {
			return codedError{code: "xovi_guard_conflict"}
		}
		if err := runBoundedProcess(
			ctx,
			5*time.Second,
			"mount", "--bind", xoviFailureMaskTarget, xoviEmergencyTargetPath,
		); err != nil {
			return codedError{code: "xovi_guard_install_failed"}
		}
	}

	info, err := os.Lstat(xoviRemarkableFailMaskPath)
	if err == nil {
		if info.Mode()&os.ModeSymlink == 0 {
			return codedError{code: "xovi_guard_conflict"}
		}
		target, readErr := os.Readlink(xoviRemarkableFailMaskPath)
		if readErr != nil || target != xoviFailureMaskTarget {
			return codedError{code: "xovi_guard_conflict"}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return codedError{code: "xovi_guard_install_failed"}
	} else if err := os.Symlink(xoviFailureMaskTarget, xoviRemarkableFailMaskPath); err != nil {
		return codedError{code: "xovi_guard_install_failed"}
	}
	return nil
}

func removeXoviFailureMasks() error {
	mounted, err := xoviEmergencyTargetMounted()
	if err != nil {
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	if mounted && !xoviEmergencyTargetIsDevNull() {
		return codedError{code: "xovi_guard_conflict"}
	}

	removeRemarkableFailMask := false
	info, err := os.Lstat(xoviRemarkableFailMaskPath)
	if err == nil {
		if info.Mode()&os.ModeSymlink == 0 {
			return codedError{code: "xovi_guard_conflict"}
		}
		target, readErr := os.Readlink(xoviRemarkableFailMaskPath)
		if readErr != nil || target != xoviFailureMaskTarget {
			return codedError{code: "xovi_guard_conflict"}
		}
		removeRemarkableFailMask = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return codedError{code: "xovi_guard_cleanup_failed"}
	}

	if removeRemarkableFailMask {
		if err := os.Remove(xoviRemarkableFailMaskPath); err != nil {
			return codedError{code: "xovi_guard_cleanup_failed"}
		}
	}
	if mounted {
		cleanupContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		unmountErr := runBoundedProcess(cleanupContext, 4*time.Second, "umount", xoviEmergencyTargetPath)
		cancel()
		if unmountErr != nil {
			return codedError{code: "xovi_guard_cleanup_failed"}
		}
	}
	if !xoviEmergencyTargetOriginal() {
		return codedError{code: "xovi_guard_cleanup_failed"}
	}
	return nil
}

func xoviFailureMasksMatch(expected bool) (bool, error) {
	mounted, err := xoviEmergencyTargetMounted()
	if err != nil {
		return false, err
	}
	remarkableFailMasked := false
	info, err := os.Lstat(xoviRemarkableFailMaskPath)
	if err == nil {
		if info.Mode()&os.ModeSymlink == 0 {
			return false, nil
		}
		target, readErr := os.Readlink(xoviRemarkableFailMaskPath)
		remarkableFailMasked = readErr == nil && target == xoviFailureMaskTarget
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if expected {
		return mounted && xoviEmergencyTargetIsDevNull() && remarkableFailMasked, nil
	}
	return !mounted && xoviEmergencyTargetOriginal() && !remarkableFailMasked, nil
}

func xoviEmergencyTargetMounted() (bool, error) {
	contents, err := os.ReadFile(xoviProcessMountInfoPath)
	if err != nil {
		return false, err
	}
	return mountInfoContainsTarget(contents, xoviEmergencyTargetPath), nil
}

func xoviEmergencyTargetIsDevNull() bool {
	targetInfo, targetErr := os.Stat(xoviEmergencyTargetPath)
	nullInfo, nullErr := os.Stat(xoviFailureMaskTarget)
	return targetErr == nil && nullErr == nil && os.SameFile(targetInfo, nullInfo)
}

func xoviEmergencyTargetOriginal() bool {
	info, err := os.Lstat(xoviEmergencyTargetPath)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm() == 0o644 && rootOwnedInfo(info)
}

func rootOwnedInfo(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == 0
}

func validateXoviConfiguration() error {
	required := []struct {
		path       string
		executable bool
	}{
		{filepath.Join(xoviRootPath, "xovi.so"), false},
		{filepath.Join(xoviRootPath, "start"), true},
		{filepath.Join(xoviRootPath, "stock"), true},
		{filepath.Join(xoviRootPath, "extensions.d", "framebuffer-spy.so"), false},
		{filepath.Join(xoviRootPath, "extensions.d", "xovi-message-broker.so"), false},
		{filepath.Join(xoviRootPath, "extensions.d", "rmmirror-files-loopback.so"), false},
	}
	for _, asset := range required {
		info, err := os.Lstat(asset.path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o444 == 0 ||
			(asset.executable && info.Mode().Perm()&0o111 == 0) {
			return codedError{code: "xovi_configuration_missing"}
		}
	}
	for _, forbiddenPath := range []string{
		filepath.Join(xoviRootPath, "services", "xochitl.service", "qt-resource-rebuilder.conf"),
		filepath.Join(xoviRootPath, "services", "xochitl.service", "99-rmmirror-activation-guard.conf"),
		filepath.Join(xoviRootPath, "services", "xochitl.service", xoviActivationGuardName),
	} {
		if _, err := os.Lstat(forbiddenPath); err == nil {
			return codedError{code: "xovi_configuration_forbidden"}
		} else if !errors.Is(err, os.ErrNotExist) {
			return codedError{code: "xovi_configuration_missing"}
		}
	}

	extensionsPath := filepath.Join(xoviRootPath, "extensions.d")
	entries, err := os.ReadDir(extensionsPath)
	if err != nil {
		return codedError{code: "xovi_configuration_missing"}
	}
	allowed := map[string]bool{
		"framebuffer-spy.so":         true,
		"xovi-message-broker.so":     true,
		"rmmirror-files-loopback.so": true,
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == "qt-resource-rebuilder.so" || name == "webserver-remote.so" {
			return codedError{code: "xovi_configuration_forbidden"}
		}
		if strings.HasSuffix(name, ".so") && !allowed[name] {
			return codedError{code: "xovi_configuration_unexpected"}
		}
	}
	return nil
}

func observeXoviRuntime(ctx context.Context) (xoviRuntimeObservation, error) {
	xochitl := inspectXochitl()
	if !xochitl.Running || xochitl.PID <= 0 {
		return xoviRuntimeObservation{}, codedError{code: "xovi_runtime_unavailable"}
	}
	maps, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(xochitl.PID), "maps"))
	if err != nil {
		return xoviRuntimeObservation{}, codedError{code: "xovi_runtime_unavailable"}
	}

	xochitlActive := runBoundedProcess(
		ctx,
		3*time.Second,
		"systemctl",
		"is-active", "--quiet", xochitlService,
	) == nil
	syncActive := runBoundedProcess(
		ctx,
		3*time.Second,
		"systemctl",
		"is-active", "--quiet", "rm-sync.service",
	) == nil
	inputFIFO := namedPipePresent(xoviMessageInput)
	outputFIFO := namedPipePresent(xoviMessageOutput)
	tcp, _ := os.ReadFile(filesTCPTablePath)
	return xoviRuntimeObservation{
		Mapped:                 classifyXoviMappedRuntime(xoviRootPath, maps),
		XochitlActive:          xochitlActive,
		SyncActive:             syncActive,
		BrokerInputFIFO:        inputFIFO,
		BrokerOutputFIFO:       outputFIFO,
		FilesLoopbackListening: containsLoopbackFilesListener(tcp),
	}, nil
}

func namedPipePresent(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeNamedPipe != 0
}

func waitForXoviRuntime(ctx context.Context, timeout time.Duration, ready bool) (bool, error) {
	deadline := time.Now().Add(timeout)
	var lastObservation xoviRuntimeObservation
	lastObservationValid := false
	for {
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		observation, err := observeXoviRuntime(ctx)
		if err == nil {
			lastObservation = observation
			lastObservationValid = true
		}
		if err == nil && ((ready && observation.ready()) || (!ready && observation.stock())) {
			return true, nil
		}
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			if ready {
				return false, codedError{code: xoviReadyFailureCode(lastObservation, lastObservationValid)}
			}
			return false, codedError{code: "xovi_runtime_not_ready"}
		}
		timer := time.NewTimer(min(250*time.Millisecond, remaining))
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return false, ctx.Err()
		case <-timer.C:
		}
	}
}

func resetXochitlRestartBudget(ctx context.Context) error {
	if err := runBoundedProcess(ctx, 10*time.Second, "systemctl", "reset-failed", xochitlService); err != nil {
		return codedError{code: "xochitl_restart_budget_reset_failed"}
	}
	return nil
}

func runBoundedProcess(ctx context.Context, timeout time.Duration, name string, arguments ...string) error {
	_, err := runBoundedProcessWithOutput(ctx, timeout, 0, name, arguments...)
	return err
}

func runBoundedProcessOutput(
	ctx context.Context,
	timeout time.Duration,
	maximumBytes int,
	name string,
	arguments ...string,
) ([]byte, error) {
	if maximumBytes <= 0 {
		return nil, codedError{code: "xovi_command_output_invalid"}
	}
	return runBoundedProcessWithOutput(ctx, timeout, maximumBytes, name, arguments...)
}

func runBoundedProcessWithOutput(
	ctx context.Context,
	timeout time.Duration,
	maximumBytes int,
	name string,
	arguments ...string,
) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	command := exec.Command(name, arguments...)
	command.Stdin = nil
	var output *limitedProcessOutput
	if maximumBytes > 0 {
		output = &limitedProcessOutput{maximum: maximumBytes}
		command.Stdout = output
	} else {
		command.Stdout = io.Discard
	}
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return nil, err
	}
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-wait:
		if err != nil {
			return nil, err
		}
		if output != nil && output.overflow {
			return nil, codedError{code: "xovi_command_output_too_large"}
		}
		if output != nil {
			return output.data, nil
		}
		return nil, nil
	case <-ctx.Done():
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		<-wait
		return nil, ctx.Err()
	case <-timer.C:
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		<-wait
		return nil, context.DeadlineExceeded
	}
}

type limitedProcessOutput struct {
	maximum  int
	data     []byte
	overflow bool
}

func (output *limitedProcessOutput) Write(value []byte) (int, error) {
	written := len(value)
	remaining := output.maximum - len(output.data)
	if remaining < len(value) {
		output.overflow = true
		if remaining < 0 {
			remaining = 0
		}
		value = value[:remaining]
	}
	output.data = append(output.data, value...)
	return written, nil
}

func acquireXoviActivationLock() (*os.File, error) {
	fd, err := syscall.Open(
		xoviActivationLockPath,
		syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, codedError{code: "xovi_activation_lock_failed"}
	}
	lock := os.NewFile(uintptr(fd), xoviActivationLockPath)
	if err := lock.Chmod(0o600); err != nil {
		_ = lock.Close()
		return nil, codedError{code: "xovi_activation_lock_failed"}
	}
	if !regularRootOwnedFile(lock) {
		_ = lock.Close()
		return nil, codedError{code: "xovi_activation_lock_failed"}
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, codedError{code: "xovi_activation_busy"}
		}
		return nil, codedError{code: "xovi_activation_lock_failed"}
	}
	return lock, nil
}

func inheritedXoviActivationLock() (*os.File, error) {
	lock := os.NewFile(xoviActivationWorkerFD, xoviActivationLockPath)
	if lock == nil || !sameRegularRootOwnedFile(lock, xoviActivationLockPath) {
		if lock != nil {
			_ = lock.Close()
		}
		return nil, codedError{code: "xovi_activation_worker_invalid"}
	}
	return lock, nil
}

func xoviActivationLockHeld() (bool, error) {
	fd, err := syscall.Open(xoviActivationLockPath, syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return false, err
	}
	file := os.NewFile(uintptr(fd), xoviActivationLockPath)
	defer file.Close()
	if !regularRootOwnedFile(file) {
		return false, codedError{code: "xovi_activation_lock_failed"}
	}
	err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	_ = syscall.Flock(fd, syscall.LOCK_UN)
	return false, nil
}

func regularRootOwnedFile(file *os.File) bool {
	var stat syscall.Stat_t
	return syscall.Fstat(int(file.Fd()), &stat) == nil &&
		stat.Mode&syscall.S_IFMT == syscall.S_IFREG && stat.Mode&0o777 == 0o600 && stat.Uid == 0
}

func sameRegularRootOwnedFile(file *os.File, path string) bool {
	var descriptor syscall.Stat_t
	var target syscall.Stat_t
	return syscall.Fstat(int(file.Fd()), &descriptor) == nil &&
		syscall.Lstat(path, &target) == nil &&
		descriptor.Mode&syscall.S_IFMT == syscall.S_IFREG && descriptor.Mode&0o777 == 0o600 && descriptor.Uid == 0 &&
		descriptor.Dev == target.Dev && descriptor.Ino == target.Ino
}

func readXoviActivationStatusFile() (XoviActivationStatus, error) {
	fd, err := syscall.Open(xoviActivationStatusPath, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return XoviActivationStatus{}, codedError{code: "xovi_activation_status_unavailable"}
	}
	file := os.NewFile(uintptr(fd), xoviActivationStatusPath)
	defer file.Close()
	var stat syscall.Stat_t
	if syscall.Fstat(fd, &stat) != nil || stat.Mode&syscall.S_IFMT != syscall.S_IFREG ||
		stat.Mode&0o777 != 0o600 || stat.Uid != 0 || stat.Size < 1 || stat.Size > 4096 {
		return XoviActivationStatus{}, codedError{code: "xovi_activation_status_invalid"}
	}
	return decodeXoviActivationStatus(file)
}

func writeXoviActivationStatus(status XoviActivationStatus) error {
	if err := validateXoviActivationStatus(status); err != nil {
		return err
	}
	contents, err := json.Marshal(status)
	if err != nil {
		return codedError{code: "xovi_activation_status_write_failed"}
	}
	contents = append(contents, '\n')
	directory := filepath.Dir(xoviActivationStatusPath)
	temporary, err := os.CreateTemp(directory, ".rmmirror-xovi-activation-*")
	if err != nil {
		return codedError{code: "xovi_activation_status_write_failed"}
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return codedError{code: "xovi_activation_status_write_failed"}
	}
	if _, err := temporary.Write(contents); err != nil || temporary.Sync() != nil || temporary.Close() != nil {
		return codedError{code: "xovi_activation_status_write_failed"}
	}
	if err := os.Rename(temporaryPath, xoviActivationStatusPath); err != nil {
		return codedError{code: "xovi_activation_status_write_failed"}
	}
	committed = true
	if directoryHandle, err := os.Open(directory); err == nil {
		_ = directoryHandle.Sync()
		_ = directoryHandle.Close()
	}
	return nil
}
