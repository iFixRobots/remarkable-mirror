package device

import (
	"bytes"
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	filesPrimaryInterface = "usb0"
	// Stock Xochitl already treats usb1 as its carrier-independent fallback.
	// Mirror owns only this session address and removes it during cleanup.
	filesFallbackInterface        = "usb1"
	filesFallbackHost             = "10.11.99.1"
	filesFallbackCIDR             = filesFallbackHost + "/32"
	filesFallbackOwnerPath        = "/run/rmmirror-files-fallback.owner"
	filesFallbackOwnerValue       = "rmmirror.files-fallback/v2\n"
	filesFallbackReadbackAttempts = 8
	filesFallbackReadbackDelay    = 25 * time.Millisecond
	filesTCPTablePath             = "/proc/net/tcp"
	filesReadinessPortHex         = "0050"
	filesReadinessTimeout         = 8 * time.Second
	filesReadinessRetryDelay      = 50 * time.Millisecond
	filesStateReady               = "ready"
	filesStateUnavailable         = "unavailable"
)

type interfaceAddressLister func(interfaceName string) ([]net.Addr, error)
type interfaceCarrierReader func(interfaceName string) (bool, error)
type networkCommandRunner func(name string, args ...string) error

type filesFallbackClaim struct {
	Owned        bool
	UseFallback  bool
	NeedsAddress bool
}

func restoreInputAfterFilesCleanup(
	cleanup func() error,
	restore func() error,
	finalize func() error,
) error {
	// Files is a sidecar, so physical input restoration is always attempted.
	// Its owner marker is finalized only after both stock configuration and
	// physical input have been restored.
	cleanupErr := cleanup()
	restoreErr := restore()
	if cleanupErr != nil || restoreErr != nil {
		return errors.Join(cleanupErr, restoreErr)
	}
	return finalize()
}

func inputWatchdogRecoveryRequired(physicalErr, filesErr error) bool {
	return physicalErr != nil || filesErr != nil
}

// prepareFilesFallbackSession claims Files ownership and establishes the
// watchdog. Network activation is deliberately deferred until the restarted
// Xochitl has opened the managed input devices.
func prepareFilesFallbackSession(
	requested bool,
	claim func() (filesFallbackClaim, error),
	startWatchdog func(owned bool) error,
	cleanup func() error,
) (lease filesFallbackClaim, warning error, fatal error) {
	if requested {
		lease, warning = claim()
	}

	if err := startWatchdog(lease.Owned); err != nil {
		return lease, warning, err
	}

	if !requested {
		return filesFallbackClaim{}, cleanup(), nil
	}
	if warning != nil {
		return lease, warning, nil
	}
	if !lease.UseFallback {
		if lease.Owned {
			warning = cleanup()
		}
		return lease, warning, nil
	}
	return lease, nil, nil
}

// startXochitlWithFilesFallback establishes the owned fallback address before
// stock Xochitl starts. Files-only failures remain warnings so input stays
// available.
func startXochitlWithFilesFallback(
	claim filesFallbackClaim,
	stop func() error,
	hide func() error,
	start func() error,
	waitReady func() error,
	activate func(filesFallbackClaim) error,
	stabilize func() error,
	cleanup func() error,
) (warning error, fatal error) {
	if err := stop(); err != nil {
		return nil, err
	}
	if err := hide(); err != nil {
		return nil, err
	}
	if claim.Owned && claim.UseFallback {
		if err := activate(claim); err != nil {
			warning = errors.Join(err, cleanup())
		} else if err := stabilize(); err != nil {
			warning = errors.Join(err, cleanup())
		}
	}
	if err := start(); err != nil {
		return warning, err
	}
	if err := waitReady(); err != nil {
		return warning, err
	}
	return warning, nil
}

func claimFilesFallbackAddress() (filesFallbackClaim, error) {
	return claimFilesFallbackAddressWith(
		filesFallbackOwnerPath,
		listInterfaceAddresses,
		readInterfaceCarrier,
	)
}

func claimFilesFallbackAddressWith(
	ownerPath string,
	list interfaceAddressLister,
	readCarrier interfaceCarrierReader,
) (filesFallbackClaim, error) {
	primaryAddresses, err := list(filesPrimaryInterface)
	if err != nil {
		return filesFallbackClaim{}, codedError{code: "files_fallback_primary_inspection_failed"}
	}
	fallbackAddresses := primaryAddresses
	if filesFallbackInterface != filesPrimaryInterface {
		fallbackAddresses, err = list(filesFallbackInterface)
		if err != nil {
			return filesFallbackClaim{}, codedError{code: "files_fallback_interface_failed"}
		}
	}
	fallbackExists := containsExactFilesFallbackAddress(fallbackAddresses)
	owned, err := hasFilesFallbackOwner(ownerPath)
	if err != nil {
		return filesFallbackClaim{}, err
	}

	primaryReady := false
	if containsFilesFallbackHost(primaryAddresses) {
		primaryReady, err = readCarrier(filesPrimaryInterface)
		if err != nil {
			return filesFallbackClaim{}, codedError{code: "files_fallback_primary_inspection_failed"}
		}
	}
	if primaryReady {
		return filesFallbackClaim{Owned: owned}, nil
	}
	if owned {
		return filesFallbackClaim{
			Owned:        true,
			UseFallback:  true,
			NeedsAddress: !fallbackExists,
		}, nil
	}
	if fallbackExists {
		return filesFallbackClaim{UseFallback: true}, nil
	}
	if err := createFilesFallbackOwner(ownerPath); err != nil {
		return filesFallbackClaim{}, err
	}
	return filesFallbackClaim{
		Owned:        true,
		UseFallback:  true,
		NeedsAddress: true,
	}, nil
}

func activateFilesFallbackAddress(claim filesFallbackClaim) error {
	return activateFilesFallbackAddressWith(claim, runNetworkCommand)
}

func activateFilesFallbackAddressWith(
	claim filesFallbackClaim,
	run networkCommandRunner,
) error {
	if !claim.Owned || !claim.UseFallback {
		return nil
	}
	if !claim.NeedsAddress {
		if err := run(
			"ip",
			"address", "delete", filesFallbackCIDR,
			"dev", filesFallbackInterface,
		); err != nil {
			return codedError{code: "files_fallback_address_refresh_failed"}
		}
	}
	if err := run(
		"ip",
		"address", "add", filesFallbackCIDR,
		"dev", filesFallbackInterface,
	); err != nil {
		return codedError{code: "files_fallback_address_add_failed"}
	}
	return nil
}

func stabilizeFilesFallbackAddress() error {
	return stabilizeFilesFallbackAddressWith(
		listInterfaceAddresses,
		func() { time.Sleep(filesFallbackReadbackDelay) },
		filesFallbackReadbackAttempts,
	)
}

func stabilizeFilesFallbackAddressWith(
	list interfaceAddressLister,
	pause func(),
	attempts int,
) error {
	for attempt := 0; attempt < attempts; attempt++ {
		addresses, err := list(filesFallbackInterface)
		if err == nil && containsExactFilesFallbackAddress(addresses) {
			return nil
		}
		if attempt+1 < attempts {
			pause()
		}
	}
	return codedError{code: "files_fallback_address_not_ready"}
}

func probeFilesState(requested bool) string {
	return probeFilesStateWith(
		requested,
		filesHTTPReady,
		time.Now,
		time.Sleep,
		filesReadinessTimeout,
	)
}

func probeFilesStateWith(
	requested bool,
	probe func() bool,
	now func() time.Time,
	pause func(time.Duration),
	timeout time.Duration,
) string {
	if !requested {
		return ""
	}
	deadline := now().Add(timeout)
	for {
		if probe() {
			return filesStateReady
		}
		remaining := deadline.Sub(now())
		if remaining <= 0 {
			return filesStateUnavailable
		}
		pause(min(filesReadinessRetryDelay, remaining))
	}
}

func filesHTTPReady() bool {
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: (&net.Dialer{
			Timeout: 500 * time.Millisecond,
		}).DialContext,
	}
	client := &http.Client{Transport: transport, Timeout: time.Second}
	response, err := client.Get("http://" + filesFallbackHost + "/documents/")
	if err != nil {
		return false
	}
	_ = response.Body.Close()
	return response.StatusCode >= http.StatusOK && response.StatusCode < http.StatusMultipleChoices
}

func filesListenerReady() bool {
	contents, err := os.ReadFile(filesTCPTablePath)
	return err == nil && containsListeningTCPPort(contents, filesReadinessPortHex)
}

func containsListeningTCPPort(contents []byte, portHex string) bool {
	for _, line := range strings.Split(string(contents), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		separator := strings.LastIndexByte(fields[1], ':')
		if separator < 0 || separator+1 >= len(fields[1]) {
			continue
		}
		if strings.EqualFold(fields[1][separator+1:], portHex) && fields[3] == "0A" {
			return true
		}
	}
	return false
}

func cleanupFilesFallbackAddress() error {
	return cleanupFilesFallbackAddressWith(
		filesFallbackOwnerPath,
		listInterfaceAddresses,
		runNetworkCommand,
	)
}

// prepareFilesFallbackStockRestore removes the owned session address while
// retaining the owner marker. The caller finalizes that marker only after
// stock Xochitl and physical input are verified.
func prepareFilesFallbackStockRestore() error {
	owned, err := hasFilesFallbackOwner(filesFallbackOwnerPath)
	if err != nil || !owned {
		return err
	}
	return removeOwnedFilesFallbackAddressWith(
		filesFallbackOwnerPath,
		listInterfaceAddresses,
		runNetworkCommand,
	)
}

func finalizeFilesFallbackStockRestore() error {
	owned, err := hasFilesFallbackOwner(filesFallbackOwnerPath)
	if err != nil || !owned {
		return err
	}
	return removeFilesFallbackOwner(filesFallbackOwnerPath)
}

func cleanupFilesFallbackSession() error {
	if err := prepareFilesFallbackStockRestore(); err != nil {
		return err
	}
	return finalizeFilesFallbackStockRestore()
}

func cleanupFilesFallbackAddressWith(
	ownerPath string,
	list interfaceAddressLister,
	run networkCommandRunner,
) error {
	if err := removeOwnedFilesFallbackAddressWith(ownerPath, list, run); err != nil {
		return err
	}
	return removeFilesFallbackOwner(ownerPath)
}

func removeOwnedFilesFallbackAddressWith(
	ownerPath string,
	list interfaceAddressLister,
	run networkCommandRunner,
) error {
	owned, err := hasFilesFallbackOwner(ownerPath)
	if err != nil || !owned {
		return err
	}
	addresses, err := list(filesFallbackInterface)
	if err != nil {
		return codedError{code: "files_fallback_address_remove_failed"}
	}
	if containsExactFilesFallbackAddress(addresses) {
		if err := run(
			"ip",
			"address", "delete", filesFallbackCIDR,
			"dev", filesFallbackInterface,
		); err != nil {
			return codedError{code: "files_fallback_address_remove_failed"}
		}
	}
	return nil
}

func removeFilesFallbackOwner(ownerPath string) error {
	if err := os.Remove(ownerPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return codedError{code: "files_fallback_owner_remove_failed"}
	}
	return nil
}

func hasFilesFallbackOwner(ownerPath string) (bool, error) {
	contents, err := os.ReadFile(ownerPath)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, codedError{code: "files_fallback_owner_read_failed"}
	}
	if string(contents) != filesFallbackOwnerValue {
		return false, codedError{code: "files_fallback_owner_invalid"}
	}
	return true, nil
}

func createFilesFallbackOwner(ownerPath string) error {
	if filepath.Clean(ownerPath) != ownerPath || !filepath.IsAbs(ownerPath) {
		return codedError{code: "files_fallback_owner_invalid"}
	}
	file, err := os.OpenFile(ownerPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		owned, readErr := hasFilesFallbackOwner(ownerPath)
		if readErr == nil && owned {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
	if err != nil {
		return codedError{code: "files_fallback_owner_create_failed"}
	}
	removeOnFailure := true
	defer func() {
		_ = file.Close()
		if removeOnFailure {
			_ = os.Remove(ownerPath)
		}
	}()
	if _, err := file.WriteString(filesFallbackOwnerValue); err != nil {
		return codedError{code: "files_fallback_owner_create_failed"}
	}
	if err := file.Sync(); err != nil {
		return codedError{code: "files_fallback_owner_create_failed"}
	}
	if err := file.Close(); err != nil {
		return codedError{code: "files_fallback_owner_create_failed"}
	}
	removeOnFailure = false
	return nil
}

func listInterfaceAddresses(interfaceName string) ([]net.Addr, error) {
	device, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return nil, err
	}
	return device.Addrs()
}

func readInterfaceCarrier(interfaceName string) (bool, error) {
	if interfaceName != filesPrimaryInterface {
		return false, errors.New("unsupported interface")
	}
	contents, err := os.ReadFile("/sys/class/net/usb0/carrier")
	if err != nil {
		return false, err
	}
	switch strings.TrimSpace(string(contents)) {
	case "1":
		return true, nil
	case "0":
		return false, nil
	default:
		return false, errors.New("invalid carrier state")
	}
}

func containsFilesFallbackHost(addresses []net.Addr) bool {
	wantIP := net.ParseIP(filesFallbackHost)
	for _, address := range addresses {
		addressIP, _, err := net.ParseCIDR(address.String())
		if err == nil && addressIP.Equal(wantIP) {
			return true
		}
	}
	return false
}

func containsExactFilesFallbackAddress(addresses []net.Addr) bool {
	wantIP, wantNetwork, _ := net.ParseCIDR(filesFallbackCIDR)
	for _, address := range addresses {
		addressIP, addressNetwork, err := net.ParseCIDR(address.String())
		if err == nil &&
			addressIP.Equal(wantIP) &&
			bytes.Equal(addressNetwork.Mask, wantNetwork.Mask) {
			return true
		}
	}
	return false
}

func runNetworkCommand(name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).Run()
}
