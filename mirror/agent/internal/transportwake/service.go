package transportwake

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	StatusSchema        = "rmmirror.transport-wake/v1"
	DefaultWakeLockName = "rmmirror-usb"
)

type Config struct {
	CarrierPath     string
	WakeLockPath    string
	WakeUnlockPath  string
	StatusPath      string
	WakeLockName    string
	PollInterval    time.Duration
	RenewInterval   time.Duration
	WakeLockTimeout time.Duration
}

func DefaultConfig() Config {
	return Config{
		CarrierPath:     "/sys/class/net/usb0/carrier",
		WakeLockPath:    "/sys/power/wake_lock",
		WakeUnlockPath:  "/sys/power/wake_unlock",
		StatusPath:      "/run/rmmirror-transport-wake.json",
		WakeLockName:    DefaultWakeLockName,
		PollInterval:    time.Second,
		RenewInterval:   20 * time.Second,
		WakeLockTimeout: 60 * time.Second,
	}
}

func (config Config) Validate() error {
	for name, value := range map[string]string{
		"carrier path":     config.CarrierPath,
		"wake lock path":   config.WakeLockPath,
		"wake unlock path": config.WakeUnlockPath,
		"status path":      config.StatusPath,
	} {
		if !path.IsAbs(value) && !filepath.IsAbs(value) {
			return fmt.Errorf("%s must be absolute", name)
		}
	}
	if config.WakeLockName == "" || strings.ContainsAny(config.WakeLockName, " \t\r\n") {
		return errors.New("wake lock name must be one non-empty word")
	}
	if config.PollInterval <= 0 {
		return errors.New("poll interval must be positive")
	}
	if config.RenewInterval <= 0 {
		return errors.New("renew interval must be positive")
	}
	if config.WakeLockTimeout <= config.RenewInterval {
		return errors.New("wake lock timeout must exceed the renew interval")
	}
	return nil
}

type Status struct {
	Schema              string `json:"schema"`
	State               string `json:"state"`
	USBCarrier          bool   `json:"usb_carrier"`
	CarrierKnown        bool   `json:"carrier_known"`
	WakeLockActive      bool   `json:"wake_lock_active"`
	SystemSleepBlocked  bool   `json:"system_sleep_blocked"`
	WakeEndpointHealthy bool   `json:"wake_endpoint_healthy"`
	WakeLockName        string `json:"wake_lock_name"`
	LastRenewalUTC      string `json:"last_renewal_utc,omitempty"`
	UpdatedUTC          string `json:"updated_utc"`
	Error               string `json:"error,omitempty"`
}

type fileAccess interface {
	ReadFile(path string) ([]byte, error)
	WriteExisting(path string, value []byte) error
	WriteStatus(path string, value []byte) error
}

type Service struct {
	config              Config
	files               fileAccess
	policy              systemSleepPolicy
	wakeEndpointHealthy func() bool
	now                 func() time.Time
	logf                func(string, ...any)

	carrierKnown       bool
	usbCarrier         bool
	policyKnown        bool
	systemSleepBlocked bool
	lastPolicyCheck    time.Time
	lockActive         bool
	lastRenewal        time.Time
	lastStatus         string
}

func New(config Config, wakeEndpoint *WakeEndpoint, logf func(string, ...any)) (*Service, error) {
	if wakeEndpoint == nil {
		return nil, errors.New("wake endpoint must not be nil")
	}
	return newService(
		config,
		osFiles{},
		newSystemctlSleepPolicy(),
		wakeEndpoint.Healthy,
		time.Now,
		logf,
	)
}

func newService(
	config Config,
	files fileAccess,
	policy systemSleepPolicy,
	wakeEndpointHealthy func() bool,
	now func() time.Time,
	logf func(string, ...any),
) (*Service, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if policy == nil {
		return nil, errors.New("system sleep policy must not be nil")
	}
	if wakeEndpointHealthy == nil {
		return nil, errors.New("wake endpoint health reporter must not be nil")
	}
	return &Service{
		config:              config,
		files:               files,
		policy:              policy,
		wakeEndpointHealthy: wakeEndpointHealthy,
		now:                 now,
		logf:                logf,
	}, nil
}

func (service *Service) Run(ctx context.Context) error {
	service.reconcile(service.now())

	ticker := time.NewTicker(service.config.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return service.stop(service.now())
		case now := <-ticker.C:
			service.reconcile(now)
		}
	}
}

func (service *Service) reconcile(now time.Time) {
	carrier, carrierErr := service.readCarrier()
	service.carrierKnown = carrierErr == nil
	service.usbCarrier = carrierErr == nil && carrier

	policyCheckDue := service.usbCarrier &&
		(service.lastPolicyCheck.IsZero() ||
			now.Before(service.lastPolicyCheck) ||
			now.Sub(service.lastPolicyCheck) >= service.config.RenewInterval)
	var policyErr error
	if !service.policyKnown ||
		service.systemSleepBlocked != service.usbCarrier ||
		policyCheckDue {
		policyErr = service.policy.SetBlocked(service.usbCarrier)
		if policyErr == nil {
			service.policyKnown = true
			service.systemSleepBlocked = service.usbCarrier
			service.lastPolicyCheck = now
		} else {
			// A failed live check cannot support a positive status claim. Keep the
			// last successful timestamp so the next poll retries immediately.
			service.policyKnown = false
			service.systemSleepBlocked = false
		}
	}

	var wakeLockErr error
	if service.usbCarrier {
		if !service.lockActive || service.lastRenewal.IsZero() ||
			now.Before(service.lastRenewal) ||
			now.Sub(service.lastRenewal) >= service.config.RenewInterval {
			wakeLockErr = service.renew(now)
		}
	} else if service.lockActive {
		wakeLockErr = service.release()
	}

	service.publishStatus(now, false, errors.Join(carrierErr, policyErr, wakeLockErr))
}

func (service *Service) stop(now time.Time) error {
	// Always ask the ownership-aware policy to clean up. A failed block may
	// have published its restart journal before systemctl returned an error.
	policyErr := service.policy.SetBlocked(false)
	if policyErr == nil {
		service.systemSleepBlocked = false
	}
	var releaseErr error
	if service.lockActive {
		releaseErr = service.release()
	}
	statusErr := service.publishStatus(now, true, errors.Join(policyErr, releaseErr))
	return errors.Join(policyErr, releaseErr, statusErr)
}

func (service *Service) readCarrier() (bool, error) {
	value, err := service.files.ReadFile(service.config.CarrierPath)
	if err != nil {
		return false, fmt.Errorf("read USB carrier: %w", err)
	}
	switch strings.TrimSpace(string(value)) {
	case "1":
		return true, nil
	case "0":
		return false, nil
	default:
		return false, fmt.Errorf("read USB carrier: unexpected value %q", strings.TrimSpace(string(value)))
	}
}

func (service *Service) renew(now time.Time) error {
	timeout := strconv.FormatInt(service.config.WakeLockTimeout.Nanoseconds(), 10)
	value := []byte(service.config.WakeLockName + " " + timeout + "\n")
	if err := service.files.WriteExisting(service.config.WakeLockPath, value); err != nil {
		return fmt.Errorf("renew wake lock: %w", err)
	}
	service.lockActive = true
	service.lastRenewal = now.UTC()
	return nil
}

func (service *Service) release() error {
	value := []byte(service.config.WakeLockName + "\n")
	if err := service.files.WriteExisting(service.config.WakeUnlockPath, value); err != nil {
		return fmt.Errorf("release wake lock: %w", err)
	}
	service.lockActive = false
	return nil
}

func (service *Service) publishStatus(now time.Time, stopped bool, operationErr error) error {
	state := "idle"
	if stopped {
		state = "stopped"
	} else if operationErr != nil {
		state = "degraded"
	} else if service.lockActive {
		state = "holding"
	}

	status := Status{
		Schema:              StatusSchema,
		State:               state,
		USBCarrier:          service.usbCarrier,
		CarrierKnown:        service.carrierKnown,
		WakeLockActive:      service.lockActive,
		SystemSleepBlocked:  service.systemSleepBlocked,
		WakeEndpointHealthy: service.wakeEndpointHealthy(),
		WakeLockName:        service.config.WakeLockName,
		UpdatedUTC:          now.UTC().Format(time.RFC3339Nano),
	}
	if !service.lastRenewal.IsZero() {
		status.LastRenewalUTC = service.lastRenewal.UTC().Format(time.RFC3339Nano)
	}
	if operationErr != nil {
		status.Error = operationErr.Error()
	}

	statusKey := strings.Join([]string{
		status.State,
		strconv.FormatBool(status.USBCarrier),
		strconv.FormatBool(status.CarrierKnown),
		strconv.FormatBool(status.WakeLockActive),
		strconv.FormatBool(status.SystemSleepBlocked),
		strconv.FormatBool(status.WakeEndpointHealthy),
		status.LastRenewalUTC,
		status.Error,
	}, "|")
	if statusKey == service.lastStatus {
		return nil
	}

	payload, err := json.Marshal(status)
	if err != nil {
		return fmt.Errorf("encode status: %w", err)
	}
	payload = append(payload, '\n')
	if err := service.files.WriteStatus(service.config.StatusPath, payload); err != nil {
		service.logf("status write failed: %v", err)
		return fmt.Errorf("write status: %w", err)
	}
	service.lastStatus = statusKey
	if operationErr != nil {
		service.logf("%s", operationErr)
	}
	return nil
}

type osFiles struct{}

func (osFiles) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (osFiles) WriteExisting(path string, value []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(value)
	closeErr := file.Close()
	return errors.Join(writeErr, closeErr)
}

func (osFiles) WriteStatus(path string, value []byte) (resultErr error) {
	temporaryPath := path + ".new"
	file, err := os.OpenFile(temporaryPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if resultErr != nil {
			_ = os.Remove(temporaryPath)
		}
	}()

	if _, err := file.Write(value); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}

	published, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if !bytes.Equal(published, value) {
		return errors.New("published status does not match requested value")
	}
	return nil
}
