package transportwake

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type recordedWrite struct {
	path  string
	value string
}

type fakeFiles struct {
	reads       map[string][]byte
	readErrors  map[string]error
	writeErrors map[string]error
	writes      []recordedWrite
	statuses    []Status
}

type fakeSleepPolicy struct {
	calls  []bool
	errors map[bool]error
}

type fakeEndpointHealth struct {
	healthy bool
}

func (health *fakeEndpointHealth) Healthy() bool {
	return health.healthy
}

func newFakeSleepPolicy() *fakeSleepPolicy {
	return &fakeSleepPolicy{errors: map[bool]error{}}
}

func (policy *fakeSleepPolicy) SetBlocked(blocked bool) error {
	policy.calls = append(policy.calls, blocked)
	return policy.errors[blocked]
}

func newFakeFiles() *fakeFiles {
	return &fakeFiles{
		reads:       map[string][]byte{},
		readErrors:  map[string]error{},
		writeErrors: map[string]error{},
	}
}

func (files *fakeFiles) ReadFile(path string) ([]byte, error) {
	if err := files.readErrors[path]; err != nil {
		return nil, err
	}
	value, ok := files.reads[path]
	if !ok {
		return nil, errors.New("missing fake file")
	}
	return append([]byte(nil), value...), nil
}

func (files *fakeFiles) WriteExisting(path string, value []byte) error {
	files.writes = append(files.writes, recordedWrite{path: path, value: string(value)})
	return files.writeErrors[path]
}

func (files *fakeFiles) WriteStatus(_ string, value []byte) error {
	var status Status
	if err := json.Unmarshal(value, &status); err != nil {
		return err
	}
	files.statuses = append(files.statuses, status)
	return nil
}

func testConfig() Config {
	return Config{
		CarrierPath:     "/carrier",
		WakeLockPath:    "/wake_lock",
		WakeUnlockPath:  "/wake_unlock",
		StatusPath:      "/status",
		WakeLockName:    DefaultWakeLockName,
		PollInterval:    time.Millisecond,
		RenewInterval:   20 * time.Second,
		WakeLockTimeout: 60 * time.Second,
	}
}

func newTestService(t *testing.T, files *fakeFiles) *Service {
	t.Helper()
	service, err := newService(
		testConfig(),
		files,
		newFakeSleepPolicy(),
		(&fakeEndpointHealth{healthy: true}).Healthy,
		time.Now,
		nil,
	)
	if err != nil {
		t.Fatalf("newService returned %v", err)
	}
	return service
}

func TestReconcileBlocksSystemSleepOnlyWhileCarrierIsUp(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1\n")
	policy := newFakeSleepPolicy()
	service, err := newService(
		testConfig(),
		files,
		policy,
		(&fakeEndpointHealth{healthy: true}).Healthy,
		time.Now,
		nil,
	)
	if err != nil {
		t.Fatalf("newService returned %v", err)
	}
	now := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)

	service.reconcile(now)
	service.reconcile(now.Add(time.Second))
	files.reads["/carrier"] = []byte("0\n")
	service.reconcile(now.Add(2 * time.Second))

	want := []bool{true, false}
	if !reflect.DeepEqual(policy.calls, want) {
		t.Fatalf("policy calls = %#v, want %#v", policy.calls, want)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.SystemSleepBlocked {
		t.Fatalf("last status retained system sleep block: %#v", last)
	}
}

func TestReconcileRevalidatesSystemSleepPolicyWhileCarrierStaysUp(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1\n")
	policy := newFakeSleepPolicy()
	service, err := newService(
		testConfig(),
		files,
		policy,
		(&fakeEndpointHealth{healthy: true}).Healthy,
		time.Now,
		nil,
	)
	if err != nil {
		t.Fatalf("newService returned %v", err)
	}
	started := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)

	service.reconcile(started)
	service.reconcile(started.Add(19 * time.Second))
	service.reconcile(started.Add(20 * time.Second))

	want := []bool{true, true}
	if !reflect.DeepEqual(policy.calls, want) {
		t.Fatalf("policy calls = %#v, want periodic drift repair %#v", policy.calls, want)
	}
	last := files.statuses[len(files.statuses)-1]
	if !last.SystemSleepBlocked || last.State != "holding" {
		t.Fatalf("last status = %#v", last)
	}
}

func TestReconcilePublishesWakeEndpointHealthTransitions(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1\n")
	health := &fakeEndpointHealth{}
	service, err := newService(
		testConfig(),
		files,
		newFakeSleepPolicy(),
		health.Healthy,
		time.Now,
		nil,
	)
	if err != nil {
		t.Fatalf("newService returned %v", err)
	}
	now := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)

	service.reconcile(now)
	first := files.statuses[len(files.statuses)-1]
	if first.WakeEndpointHealthy {
		t.Fatalf("initial status reported an unhealthy endpoint as healthy: %#v", first)
	}

	health.healthy = true
	service.reconcile(now.Add(time.Second))
	last := files.statuses[len(files.statuses)-1]
	if !last.WakeEndpointHealthy {
		t.Fatalf("updated status did not report the healthy endpoint: %#v", last)
	}
}

func TestReconcileHoldsAndRenewsTimedWakeLockOnlyWhileCarrierIsUp(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1\n")
	service := newTestService(t, files)
	started := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)

	service.reconcile(started)
	service.reconcile(started.Add(19 * time.Second))
	service.reconcile(started.Add(20 * time.Second))

	wantWrites := []recordedWrite{
		{path: "/wake_lock", value: "rmmirror-usb 60000000000\n"},
		{path: "/wake_lock", value: "rmmirror-usb 60000000000\n"},
	}
	if !reflect.DeepEqual(files.writes, wantWrites) {
		t.Fatalf("writes = %#v, want %#v", files.writes, wantWrites)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "holding" || !last.USBCarrier || !last.CarrierKnown || !last.WakeLockActive {
		t.Fatalf("last status = %#v", last)
	}
	if last.LastRenewalUTC != started.Add(20*time.Second).Format(time.RFC3339Nano) {
		t.Fatalf("last renewal = %q", last.LastRenewalUTC)
	}
}

func TestReconcileDoesNotTakeWakeLockWhileCarrierIsDown(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("0\n")
	service := newTestService(t, files)

	service.reconcile(time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC))

	if len(files.writes) != 0 {
		t.Fatalf("writes = %#v, want none", files.writes)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "idle" || last.USBCarrier || !last.CarrierKnown || last.WakeLockActive {
		t.Fatalf("last status = %#v", last)
	}
}

func TestReconcileReleasesWakeLockOnDetach(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1")
	service := newTestService(t, files)
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	service.reconcile(now)

	files.reads["/carrier"] = []byte("0")
	service.reconcile(now.Add(time.Second))

	wantLastWrite := recordedWrite{path: "/wake_unlock", value: "rmmirror-usb\n"}
	if got := files.writes[len(files.writes)-1]; got != wantLastWrite {
		t.Fatalf("last write = %#v, want %#v", got, wantLastWrite)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "idle" || last.WakeLockActive || last.USBCarrier {
		t.Fatalf("last status = %#v", last)
	}
}

func TestReconcileReleasesWakeLockWhenCarrierBecomesUnreadable(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1")
	service := newTestService(t, files)
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	service.reconcile(now)

	files.readErrors["/carrier"] = errors.New("interface disappeared")
	service.reconcile(now.Add(time.Second))

	lastWrite := files.writes[len(files.writes)-1]
	if lastWrite.path != "/wake_unlock" {
		t.Fatalf("last write = %#v, want wake unlock", lastWrite)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "degraded" || last.CarrierKnown || last.WakeLockActive {
		t.Fatalf("last status = %#v", last)
	}
	if !strings.Contains(last.Error, "interface disappeared") {
		t.Fatalf("error = %q", last.Error)
	}
}

func TestRunReleasesWakeLockOnCancellation(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1")
	service := newTestService(t, files)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if err := service.Run(ctx); err != nil {
		t.Fatalf("Run returned %v", err)
	}

	wantWrites := []recordedWrite{
		{path: "/wake_lock", value: "rmmirror-usb 60000000000\n"},
		{path: "/wake_unlock", value: "rmmirror-usb\n"},
	}
	if !reflect.DeepEqual(files.writes, wantWrites) {
		t.Fatalf("writes = %#v, want %#v", files.writes, wantWrites)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "stopped" || last.WakeLockActive {
		t.Fatalf("last status = %#v", last)
	}
}

func TestReconcileRetriesFailedWakeLockWrite(t *testing.T) {
	files := newFakeFiles()
	files.reads["/carrier"] = []byte("1")
	files.writeErrors["/wake_lock"] = errors.New("permission denied")
	service := newTestService(t, files)
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)

	service.reconcile(now)
	delete(files.writeErrors, "/wake_lock")
	service.reconcile(now.Add(time.Second))

	if len(files.writes) != 2 || files.writes[0].path != "/wake_lock" || files.writes[1].path != "/wake_lock" {
		t.Fatalf("writes = %#v, want two wake-lock attempts", files.writes)
	}
	last := files.statuses[len(files.statuses)-1]
	if last.State != "holding" || !last.WakeLockActive || last.Error != "" {
		t.Fatalf("last status = %#v", last)
	}
}

func TestConfigRejectsUnsafeTimingAndRelativePaths(t *testing.T) {
	config := testConfig()
	config.WakeLockTimeout = config.RenewInterval
	if err := config.Validate(); err == nil {
		t.Fatal("Validate accepted a timeout that cannot outlive renewal")
	}

	config = testConfig()
	config.StatusPath = "relative/status"
	if err := config.Validate(); err == nil {
		t.Fatal("Validate accepted a relative status path")
	}
}

func TestRunWithOSFilesPublishesStatusAndReleasesOnShutdown(t *testing.T) {
	directory := t.TempDir()
	carrierPath := filepath.Join(directory, "carrier")
	wakeLockPath := filepath.Join(directory, "wake_lock")
	wakeUnlockPath := filepath.Join(directory, "wake_unlock")
	statusPath := filepath.Join(directory, "status.json")
	for path, value := range map[string]string{
		carrierPath:    "1\n",
		wakeLockPath:   "",
		wakeUnlockPath: "",
	} {
		if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
			t.Fatalf("write fixture %s: %v", path, err)
		}
	}

	config := Config{
		CarrierPath:     carrierPath,
		WakeLockPath:    wakeLockPath,
		WakeUnlockPath:  wakeUnlockPath,
		StatusPath:      statusPath,
		WakeLockName:    DefaultWakeLockName,
		PollInterval:    5 * time.Millisecond,
		RenewInterval:   20 * time.Millisecond,
		WakeLockTimeout: 60 * time.Millisecond,
	}
	service, err := newService(
		config,
		osFiles{},
		newFakeSleepPolicy(),
		(&fakeEndpointHealth{healthy: true}).Healthy,
		time.Now,
		nil,
	)
	if err != nil {
		t.Fatalf("New returned %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- service.Run(ctx)
	}()

	deadline := time.Now().Add(time.Second)
	for {
		payload, readErr := os.ReadFile(statusPath)
		if readErr == nil {
			var status Status
			if json.Unmarshal(payload, &status) == nil && status.State == "holding" {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("service did not publish holding status")
		}
		time.Sleep(5 * time.Millisecond)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
	unlockValue, err := os.ReadFile(wakeUnlockPath)
	if err != nil {
		t.Fatalf("read wake unlock: %v", err)
	}
	if string(unlockValue) != "rmmirror-usb\n" {
		t.Fatalf("wake unlock = %q", unlockValue)
	}
	payload, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("read final status: %v", err)
	}
	var status Status
	if err := json.Unmarshal(payload, &status); err != nil {
		t.Fatalf("decode final status: %v", err)
	}
	if status.State != "stopped" || status.WakeLockActive {
		t.Fatalf("final status = %#v", status)
	}
}
