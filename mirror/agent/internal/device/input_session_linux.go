//go:build linux

package device

import (
	"context"
	"errors"
	"io"
	"math/bits"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	physicalMarkerName   = "Elan marker input"
	virtualPenName       = "reMarkable Mirror Pen"
	inputWatchdogCommand = "input-watchdog"
	watchdogControlFD    = 3
)

type managedInputSession struct {
	markerPath   string
	physicalRdev uint64
	virtualRdev  uint64
	lock         *os.File
	backend      *linuxInputBackend
	relay        *physicalMarkerRelay
	watchdog     *inputWatchdog
	wakeLock     *inputSessionWakeLock

	filesFallbackRequested bool
	filesFallbackOwned     bool
	filesState             string
	handoffStarted         bool
	markerHidden           bool
	closeOnce              sync.Once
	closeErr               error
}

type inputWatchdog struct {
	command *exec.Cmd
	control *os.File
}

type physicalMarkerRelay struct {
	file     *os.File
	stop     chan struct{}
	done     chan struct{}
	stopOnce sync.Once

	resultMu sync.Mutex
	result   error
}

type markerEventReader struct {
	fd   int
	stop <-chan struct{}
}

func serveManagedInput(
	ctx context.Context,
	markerPath string,
	heartbeatTimeout time.Duration,
	enableFilesFallback bool,
	reader io.Reader,
	writer io.Writer,
) (result error) {
	if !filepath.IsAbs(markerPath) {
		return codedError{code: "invalid_marker_path"}
	}
	if os.Geteuid() != 0 {
		return codedError{code: "root_required"}
	}

	session, err := acquireManagedInputSession(markerPath, enableFilesFallback)
	if err != nil {
		return err
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = session.Close()
			panic(recovered)
		}
	}()

	if err := session.Prepare(); err != nil {
		if closeErr := session.Close(); closeErr != nil {
			return closeErr
		}
		return err
	}
	protocolContext, cancelProtocol := context.WithCancel(ctx)
	relayMonitorDone := make(chan struct{})
	go func() {
		defer close(relayMonitorDone)
		select {
		case <-session.relay.Done():
			cancelProtocol()
		case <-session.wakeLock.Failed():
			cancelProtocol()
		case <-protocolContext.Done():
		}
	}()
	// Prepare restarted Xochitl, invalidating every pre-restart journal state.
	// Report unknown rather than risk toggling the new process from stale data.
	result = serveInputSessionWithStartupState(
		protocolContext,
		heartbeatTimeout,
		reader,
		writer,
		session.backend,
		"unknown",
		session.filesState,
	)
	cancelProtocol()
	<-relayMonitorDone
	if relayErr := session.relay.Err(); relayErr != nil {
		result = relayErr
	}
	if closeErr := session.Close(); closeErr != nil {
		return closeErr
	}
	return result
}

func acquireManagedInputSession(
	markerPath string,
	enableFilesFallback bool,
) (*managedInputSession, error) {
	return acquireManagedInputSessionWith(
		acquireInputSessionWakeLock,
		func() (*managedInputSession, error) {
			return newManagedInputSession(markerPath, enableFilesFallback)
		},
	)
}

func acquireManagedInputSessionWith(
	acquireWakeLock func() (*inputSessionWakeLock, error),
	construct func() (*managedInputSession, error),
) (*managedInputSession, error) {
	wakeLock, err := acquireWakeLock()
	if err != nil {
		return nil, err
	}
	session, err := construct()
	if err != nil {
		return nil, errors.Join(err, wakeLock.Close())
	}
	session.wakeLock = wakeLock
	return session, nil
}

func newManagedInputSession(
	markerPath string,
	enableFilesFallback bool,
) (*managedInputSession, error) {
	lock, err := acquireInputLock(DefaultInputLockPath, false)
	if err != nil {
		return nil, err
	}
	fail := func(failure error) (*managedInputSession, error) {
		_ = lock.Close()
		return nil, failure
	}

	if !xochitlActive() {
		return fail(codedError{code: "xochitl_not_running"})
	}
	physicalRdev, err := ensurePhysicalMarkerVisible(markerPath)
	if err != nil {
		return fail(err)
	}
	marker, err := os.OpenFile(markerPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fail(codedError{code: "marker_open_failed"})
	}

	genericBackend, err := newInputBackend()
	if err != nil {
		_ = marker.Close()
		return fail(err)
	}
	backend := genericBackend.(*linuxInputBackend)
	virtualRdev, err := findInputDeviceRdev(virtualPenName)
	if err != nil {
		_ = backend.Close()
		_ = marker.Close()
		return fail(err)
	}
	relay := startPhysicalMarkerRelay(marker, backend.pen)
	return &managedInputSession{
		markerPath: markerPath, physicalRdev: physicalRdev, virtualRdev: virtualRdev,
		lock: lock, backend: backend, relay: relay,
		filesFallbackRequested: enableFilesFallback,
	}, nil
}

func (session *managedInputSession) Prepare() error {
	var watchdog *inputWatchdog
	claim, filesWarning, err := prepareFilesFallbackSession(
		session.filesFallbackRequested,
		claimFilesFallbackAddress,
		func(owned bool) error {
			var startErr error
			watchdog, startErr = startInputWatchdog(session.markerPath, owned)
			return startErr
		},
		cleanupFilesFallbackSession,
	)
	session.filesFallbackOwned = claim.Owned
	session.watchdog = watchdog
	if err != nil {
		return err
	}
	session.handoffStarted = true

	startWarning, fatal := startXochitlWithFilesFallback(
		claim,
		func() error {
			return runSystemctl("stop", "xochitl_stop_failed")
		},
		func() error {
			if err := hidePhysicalMarker(session.markerPath); err != nil {
				return err
			}
			session.markerHidden = true
			return nil
		},
		func() error {
			return runIntentionalXochitlRestart("start", "xochitl_start_failed")
		},
		func() error {
			return waitForXochitlInput(session.virtualRdev, session.physicalRdev, 12*time.Second)
		},
		activateFilesFallbackAddress,
		stabilizeFilesFallbackAddress,
		cleanupFilesFallbackSession,
	)
	if fatal != nil {
		return fatal
	}
	if filesWarning == nil {
		filesWarning = startWarning
	}
	if err := unhidePhysicalMarker(session.markerPath); err != nil {
		return err
	}
	session.markerHidden = false
	if _, err := verifyPhysicalMarker(session.markerPath); err != nil {
		return err
	}
	if filesWarning != nil {
		session.filesState = filesStateUnavailable
	} else {
		session.filesState = probeFilesState(session.filesFallbackRequested)
	}
	if err := session.wakeLock.Err(); err != nil {
		return err
	}
	return nil
}

func (session *managedInputSession) Close() error {
	session.closeOnce.Do(func() {
		session.closeErr = session.close()
	})
	return session.closeErr
}

func (session *managedInputSession) close() error {
	var restoreErr error
	var filesCleanupErr error
	if session.backend != nil {
		if err := session.backend.Reset(); err != nil {
			restoreErr = codedError{code: "input_reset_failed"}
		}
	}
	if session.handoffStarted {
		if err := runSystemctl("stop", "xochitl_stop_failed"); err != nil && restoreErr == nil {
			restoreErr = err
		}
	}
	if session.markerHidden || exactMountPoint(session.markerPath) {
		if err := unhidePhysicalMarker(session.markerPath); err != nil && restoreErr == nil {
			restoreErr = err
		}
		session.markerHidden = false
	}
	if session.relay != nil {
		if err := session.relay.Close(); err != nil && restoreErr == nil {
			restoreErr = codedError{code: "marker_close_failed"}
		}
		session.relay = nil
	}
	if session.backend != nil {
		if err := session.backend.Close(); err != nil && restoreErr == nil {
			restoreErr = codedError{code: "input_backend_close_failed"}
		}
		session.backend = nil
	}
	if session.filesFallbackOwned {
		// Files cleanup must never be reported as failed physical-input
		// restoration. A failure is delegated to the detached watchdog,
		// which retries it before independently restoring physical input.
		filesCleanupErr = prepareFilesFallbackStockRestore()
	}
	if !session.handoffStarted && filesCleanupErr == nil && session.filesFallbackOwned {
		filesCleanupErr = finalizeFilesFallbackStockRestore()
	}

	if session.handoffStarted {
		if _, err := ensurePhysicalMarkerVisible(session.markerPath); err != nil && restoreErr == nil {
			restoreErr = err
		}
		if err := runIntentionalXochitlRestart("restart", "xochitl_restore_failed"); err != nil && restoreErr == nil {
			restoreErr = err
		}
		if restoreErr == nil {
			restoreErr = waitForXochitlInput(session.physicalRdev, 0, 12*time.Second)
		}
		if restoreErr == nil && filesCleanupErr == nil && session.filesFallbackOwned {
			filesCleanupErr = finalizeFilesFallbackStockRestore()
		}
	}

	if session.watchdog != nil {
		if !inputWatchdogRecoveryRequired(restoreErr, filesCleanupErr) {
			if err := session.watchdog.Finish(true); err != nil {
				restoreErr = codedError{code: "watchdog_stop_failed"}
			}
			_ = session.lock.Close()
			session.lock = nil
		} else {
			session.watchdog.Signal(false)
			_ = session.lock.Close()
			session.lock = nil
			if err := session.watchdog.Wait(); err == nil {
				restoreErr = nil
				filesCleanupErr = nil
			} else {
				watchdogErr := codedError{code: "watchdog_restore_failed"}
				if restoreErr != nil {
					restoreErr = errors.Join(restoreErr, watchdogErr)
				} else if filesCleanupErr != nil {
					filesCleanupErr = errors.Join(filesCleanupErr, watchdogErr)
				} else {
					restoreErr = watchdogErr
				}
			}
		}
		session.watchdog = nil
	}
	if session.lock != nil {
		_ = session.lock.Close()
		session.lock = nil
	}
	var wakeLockErr error
	if session.wakeLock != nil {
		wakeLockErr = session.wakeLock.Close()
		session.wakeLock = nil
	}
	if restoreErr != nil {
		return errors.Join(
			codedError{code: "physical_restore_failed"},
			restoreErr,
			filesCleanupErr,
			wakeLockErr,
		)
	}
	if filesCleanupErr != nil {
		return errors.Join(filesCleanupErr, wakeLockErr)
	}
	if wakeLockErr != nil {
		return wakeLockErr
	}
	return nil
}

func RunInputWatchdog(
	markerPath,
	lockPath string,
	filesFallbackOwned bool,
) error {
	control := os.NewFile(watchdogControlFD, "rmmirror-watchdog-control")
	if control == nil {
		return codedError{code: "watchdog_control_missing"}
	}
	defer control.Close()
	var signal [1]byte
	count, _ := control.Read(signal[:])
	if count == 1 && signal[0] == 1 {
		return nil
	}
	recoveryWakeLock, wakeLockErr := acquireInputSessionWakeLock()

	lock, err := acquireInputLock(lockPath, true)
	if err != nil {
		if recoveryWakeLock != nil {
			_ = recoveryWakeLock.Close()
		}
		return errors.Join(wakeLockErr, err)
	}
	defer lock.Close()
	restoreErr := restoreInputAfterFilesCleanup(
		func() error {
			if !filesFallbackOwned {
				return nil
			}
			return prepareFilesFallbackStockRestore()
		},
		func() error {
			if _, err := ensurePhysicalMarkerVisible(markerPath); err != nil {
				return err
			}
			if err := runIntentionalXochitlRestart(
				"restart",
				"xochitl_restore_failed",
			); err != nil {
				return err
			}
			physicalRdev, err := verifyPhysicalMarker(markerPath)
			if err != nil {
				return err
			}
			return waitForXochitlInput(physicalRdev, 0, 12*time.Second)
		},
		func() error {
			if !filesFallbackOwned {
				return nil
			}
			return finalizeFilesFallbackStockRestore()
		},
	)
	var wakeLockCloseErr error
	if recoveryWakeLock != nil {
		wakeLockCloseErr = recoveryWakeLock.Close()
	}
	return errors.Join(wakeLockErr, restoreErr, wakeLockCloseErr)
}

// WaitForPhysicalInputRestored is the handoff barrier between managed input
// cleanup and the next display/input generation. It succeeds only after no
// session owns the input lock, the physical marker is visible, and Xochitl has
// opened that physical device again.
func WaitForPhysicalInputRestored(markerPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		lock, err := acquireInputLock(DefaultInputLockPath, false)
		if err == nil {
			restored := false
			if !exactMountPoint(markerPath) {
				if physicalRdev, verifyErr := verifyPhysicalMarker(markerPath); verifyErr == nil {
					pid := xochitlPID()
					restored = pid > 0 && processHasDevice(pid, physicalRdev)
				}
			}
			_ = lock.Close()
			if restored {
				return nil
			}
		}
		if !time.Now().Before(deadline) {
			return codedError{code: "physical_restore_not_ready"}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func startInputWatchdog(
	markerPath string,
	filesFallbackOwned bool,
) (*inputWatchdog, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, codedError{code: "watchdog_executable_failed"}
	}
	readControl, writeControl, err := os.Pipe()
	if err != nil {
		return nil, codedError{code: "watchdog_pipe_failed"}
	}
	arguments := []string{
		inputWatchdogCommand,
		"--marker", markerPath,
		"--lock", DefaultInputLockPath,
	}
	if filesFallbackOwned {
		arguments = append(arguments, "--files-fallback-owned")
	}
	command := exec.Command(executable, arguments...)
	command.ExtraFiles = []*os.File{readControl}
	command.Stdin = nil
	command.Stdout = nil
	command.Stderr = nil
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		_ = readControl.Close()
		_ = writeControl.Close()
		return nil, codedError{code: "watchdog_start_failed"}
	}
	_ = readControl.Close()
	return &inputWatchdog{command: command, control: writeControl}, nil
}

func (watchdog *inputWatchdog) Signal(clean bool) {
	if watchdog == nil || watchdog.control == nil {
		return
	}
	if clean {
		_, _ = watchdog.control.Write([]byte{1})
	}
	_ = watchdog.control.Close()
	watchdog.control = nil
}

func (watchdog *inputWatchdog) Wait() error {
	if watchdog == nil || watchdog.command == nil {
		return nil
	}
	err := watchdog.command.Wait()
	watchdog.command = nil
	return err
}

func (watchdog *inputWatchdog) Finish(clean bool) error {
	watchdog.Signal(clean)
	return watchdog.Wait()
}

func acquireInputLock(path string, wait bool) (*os.File, error) {
	lock, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, codedError{code: "input_lock_open_failed"}
	}
	operation := syscall.LOCK_EX
	if !wait {
		operation |= syscall.LOCK_NB
	}
	for {
		err = syscall.Flock(int(lock.Fd()), operation)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		_ = lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, codedError{code: "input_session_busy"}
		}
		return nil, codedError{code: "input_lock_failed"}
	}
	return lock, nil
}

func ensurePhysicalMarkerVisible(markerPath string) (uint64, error) {
	if exactMountPoint(markerPath) {
		if err := unhidePhysicalMarker(markerPath); err != nil {
			return 0, err
		}
	}
	return verifyPhysicalMarker(markerPath)
}

func verifyPhysicalMarker(markerPath string) (uint64, error) {
	eventName := filepath.Base(markerPath)
	if !strings.HasPrefix(eventName, "event") || filepath.Dir(markerPath) != "/dev/input" {
		return 0, codedError{code: "invalid_marker_path"}
	}
	nameBytes, err := os.ReadFile(filepath.Join("/sys/class/input", eventName, "device/name"))
	if err != nil || strings.TrimSpace(string(nameBytes)) != physicalMarkerName {
		return 0, codedError{code: "unexpected_marker_device"}
	}
	info, err := os.Stat(markerPath)
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return 0, codedError{code: "marker_stat_failed"}
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || linuxDeviceMajor(uint64(stat.Rdev)) == 1 {
		return 0, codedError{code: "unexpected_marker_device"}
	}
	return uint64(stat.Rdev), nil
}

func hidePhysicalMarker(markerPath string) error {
	if exactMountPoint(markerPath) {
		return codedError{code: "marker_already_hidden"}
	}
	if err := syscall.Mount("/dev/null", markerPath, "", syscall.MS_BIND, ""); err != nil {
		return codedError{code: "marker_hide_failed"}
	}
	info, err := os.Stat(markerPath)
	if err != nil {
		_ = syscall.Unmount(markerPath, 0)
		return codedError{code: "marker_hide_failed"}
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || linuxDeviceMajor(uint64(stat.Rdev)) != 1 || linuxDeviceMinor(uint64(stat.Rdev)) != 3 {
		_ = syscall.Unmount(markerPath, 0)
		return codedError{code: "marker_hide_failed"}
	}
	return nil
}

func unhidePhysicalMarker(markerPath string) error {
	if !exactMountPoint(markerPath) {
		return nil
	}
	if err := syscall.Unmount(markerPath, 0); err != nil {
		return codedError{code: "marker_unhide_failed"}
	}
	return nil
}

func exactMountPoint(path string) bool {
	contents, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(contents), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 4 && strings.ReplaceAll(fields[4], `\040`, " ") == path {
			return true
		}
	}
	return false
}

func findInputDeviceRdev(name string) (uint64, error) {
	deadline := time.Now().Add(3 * time.Second)
	for {
		result, matches := inputDeviceRdevMatches(name)
		if matches == 1 {
			return result, nil
		}
		if matches > 1 {
			return 0, codedError{code: "virtual_pen_ambiguous"}
		}
		if time.Now().After(deadline) {
			return 0, codedError{code: "virtual_pen_not_found"}
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func inputDeviceRdevMatches(name string) (uint64, int) {
	paths, _ := filepath.Glob("/sys/class/input/event*/device/name")
	var result uint64
	matches := 0
	for _, path := range paths {
		value, err := os.ReadFile(path)
		if err != nil || strings.TrimSpace(string(value)) != name {
			continue
		}
		eventName := filepath.Base(filepath.Dir(filepath.Dir(path)))
		info, err := os.Stat(filepath.Join("/dev/input", eventName))
		if err != nil || info.Mode()&os.ModeCharDevice == 0 {
			continue
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			continue
		}
		matches++
		result = uint64(stat.Rdev)
	}
	return result, matches
}

func waitForXochitlInput(requiredRdev, forbiddenRdev uint64, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		pid := xochitlPID()
		if pid > 0 {
			hasRequired := processHasDevice(pid, requiredRdev)
			hasForbidden := forbiddenRdev != 0 && processHasDevice(pid, forbiddenRdev)
			if hasRequired && !hasForbidden {
				return nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return codedError{code: "xochitl_input_not_selected"}
}

func xochitlPID() int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		name, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "comm"))
		if err == nil && strings.TrimSpace(string(name)) == "xochitl" {
			return pid
		}
	}
	return 0
}

func processHasDevice(pid int, rdev uint64) bool {
	paths, _ := filepath.Glob(filepath.Join("/proc", strconv.Itoa(pid), "fd", "*"))
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil || info.Mode()&os.ModeCharDevice == 0 {
			continue
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if ok && uint64(stat.Rdev) == rdev {
			return true
		}
	}
	return false
}

func xochitlActive() bool {
	command := exec.Command("systemctl", "is-active", "--quiet", xochitlService)
	return command.Run() == nil
}

func runSystemctl(action, errorCode string) error {
	if err := runRawSystemctl(action, xochitlService); err != nil {
		return codedError{code: errorCode}
	}
	return nil
}

func runIntentionalXochitlRestart(action, errorCode string) error {
	return runIntentionalXochitlRestartWith(runRawSystemctl, action, errorCode)
}

func runRawSystemctl(action, unit string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "systemctl", action, unit)
	return command.Run()
}

func linuxDeviceMajor(device uint64) uint64 {
	return (device >> 8) & 0xfff
}

func linuxDeviceMinor(device uint64) uint64 {
	return (device & 0xff) | ((device >> 12) & 0xfff00)
}

func startPhysicalMarkerRelay(file *os.File, pen *uinputDevice) *physicalMarkerRelay {
	relay := &physicalMarkerRelay{
		file: file,
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	go relay.run(pen)
	return relay
}

func (relay *physicalMarkerRelay) run(pen *uinputDevice) {
	reader := markerEventReader{fd: int(relay.file.Fd()), stop: relay.stop}
	err := relayMarkerFrames(&reader, pen.EmitRawFrame)
	select {
	case <-relay.stop:
		err = nil
	default:
	}
	relay.resultMu.Lock()
	relay.result = err
	relay.resultMu.Unlock()
	close(relay.done)
}

func (relay *physicalMarkerRelay) Close() error {
	relay.stopOnce.Do(func() { close(relay.stop) })
	<-relay.done
	return relay.file.Close()
}

func (relay *physicalMarkerRelay) Done() <-chan struct{} {
	return relay.done
}

func (relay *physicalMarkerRelay) Err() error {
	select {
	case <-relay.done:
		relay.resultMu.Lock()
		defer relay.resultMu.Unlock()
		return relay.result
	default:
		return nil
	}
}

func (reader *markerEventReader) Read(buffer []byte) (int, error) {
	for {
		select {
		case <-reader.stop:
			return 0, io.EOF
		default:
		}

		var readSet syscall.FdSet
		if reader.fd < 0 || reader.fd/bits.UintSize >= len(readSet.Bits) {
			return 0, syscall.EINVAL
		}
		readSet.Bits[reader.fd/bits.UintSize] |= 1 << uint(reader.fd%bits.UintSize)
		timeout := syscall.Timeval{Usec: 250_000}
		ready, err := syscall.Select(reader.fd+1, &readSet, nil, nil, &timeout)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return 0, err
		}
		if ready == 0 {
			continue
		}
		count, err := syscall.Read(reader.fd, buffer)
		if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
			continue
		}
		if count == 0 && err == nil {
			return 0, io.EOF
		}
		return count, err
	}
}
