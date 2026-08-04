package device

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestFilesFallbackActivationHappensBeforeXochitlStarts(t *testing.T) {
	var events []string
	claim, warning, fatal := prepareFilesFallbackSession(
		true,
		func() (filesFallbackClaim, error) {
			events = append(events, "claim")
			return filesFallbackClaim{Owned: true, UseFallback: true, NeedsAddress: true}, nil
		},
		func(owned bool) error {
			events = append(events, "watchdog")
			if !owned {
				t.Fatal("watchdog did not receive ownership")
			}
			return nil
		},
		func() error {
			events = append(events, "cleanup")
			return nil
		},
	)
	if !claim.Owned || warning != nil || fatal != nil {
		t.Fatalf("prepare = claim %#v, warning %v, fatal %v", claim, warning, fatal)
	}
	warning, fatal = startXochitlWithFilesFallback(
		claim,
		func() error {
			events = append(events, "stop")
			return nil
		},
		func() error {
			events = append(events, "hide")
			return nil
		},
		func() error {
			events = append(events, "start")
			return nil
		},
		func() error {
			events = append(events, "input ready")
			return nil
		},
		func(filesFallbackClaim) error {
			events = append(events, "add")
			return nil
		},
		func() error {
			events = append(events, "readback")
			return nil
		},
		func() error {
			events = append(events, "cleanup")
			return nil
		},
	)
	if warning != nil || fatal != nil {
		t.Fatalf("start = warning %v, fatal %v", warning, fatal)
	}
	want := []string{"claim", "watchdog", "stop", "hide", "add", "readback", "start", "input ready"}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestPrepareFilesFallbackFailureDoesNotBreakInputLifecycle(t *testing.T) {
	var events []string
	claim, warning, fatal := prepareFilesFallbackSession(
		true,
		func() (filesFallbackClaim, error) {
			return filesFallbackClaim{Owned: true, UseFallback: true, NeedsAddress: true}, nil
		},
		func(bool) error {
			events = append(events, "watchdog")
			return nil
		},
		func() error {
			events = append(events, "cleanup")
			return nil
		},
	)
	if !claim.Owned || warning != nil || fatal != nil {
		t.Fatalf("prepare = claim %#v, warning %v, fatal %v", claim, warning, fatal)
	}
	warning, fatal = startXochitlWithFilesFallback(
		claim,
		func() error {
			events = append(events, "stop")
			return nil
		},
		func() error {
			events = append(events, "hide")
			return nil
		},
		func() error {
			events = append(events, "start")
			return nil
		},
		func() error {
			events = append(events, "input ready")
			return nil
		},
		func(filesFallbackClaim) error {
			events = append(events, "add")
			return codedError{code: "files_fallback_address_add_failed"}
		},
		func() error {
			events = append(events, "readback")
			return nil
		},
		func() error {
			events = append(events, "cleanup")
			return nil
		},
	)
	if ErrorCode(warning) != "files_fallback_address_add_failed" || fatal != nil {
		t.Fatalf("start = warning %v, fatal %v", warning, fatal)
	}
	want := []string{"watchdog", "stop", "hide", "add", "cleanup", "start", "input ready"}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestStabilizeFilesFallbackAddressWaitsForExactReadback(t *testing.T) {
	reads := 0
	pauses := 0
	err := stabilizeFilesFallbackAddressWith(
		func(interfaceName string) ([]net.Addr, error) {
			if interfaceName != filesFallbackInterface {
				t.Fatalf("interface = %q, want %q", interfaceName, filesFallbackInterface)
			}
			reads++
			if reads < 3 {
				return []net.Addr{ipNetwork(filesFallbackHost, 27)}, nil
			}
			return []net.Addr{ipNetwork(filesFallbackHost, 32)}, nil
		},
		func() { pauses++ },
		4,
	)
	if err != nil {
		t.Fatalf("stabilizeFilesFallbackAddressWith returned %v", err)
	}
	if reads != 3 || pauses != 2 {
		t.Fatalf("reads = %d and pauses = %d, want 3 and 2", reads, pauses)
	}
}

func TestProbeFilesStateIsBoundedAndNonfatal(t *testing.T) {
	attempts := 0
	pauses := 0
	now := time.Unix(0, 0)
	state := probeFilesStateWith(
		true,
		func() bool {
			attempts++
			return attempts == 3
		},
		func() time.Time { return now },
		func(delay time.Duration) {
			pauses++
			now = now.Add(delay)
		},
		150*time.Millisecond,
	)
	if state != filesStateReady || attempts != 3 || pauses != 2 {
		t.Fatalf("state = %q, attempts = %d, pauses = %d", state, attempts, pauses)
	}

	attempts = 0
	pauses = 0
	now = time.Unix(0, 0)
	state = probeFilesStateWith(
		true,
		func() bool {
			attempts++
			return false
		},
		func() time.Time { return now },
		func(delay time.Duration) {
			pauses++
			now = now.Add(delay)
		},
		150*time.Millisecond,
	)
	if state != filesStateUnavailable || attempts != 4 || pauses != 3 {
		t.Fatalf("state = %q, attempts = %d, pauses = %d", state, attempts, pauses)
	}
}

func TestFilesReadinessBudgetDoesNotCollapseOnImmediateRefusal(t *testing.T) {
	now := time.Unix(0, 0)
	started := now
	state := probeFilesStateWith(
		true,
		func() bool { return false },
		func() time.Time { return now },
		func(delay time.Duration) { now = now.Add(delay) },
		filesReadinessTimeout,
	)
	if state != filesStateUnavailable {
		t.Fatalf("state = %q, want %q", state, filesStateUnavailable)
	}
	if elapsed := now.Sub(started); elapsed != filesReadinessTimeout {
		t.Fatalf("readiness budget = %v, want %v", elapsed, filesReadinessTimeout)
	}
}

func TestContainsListeningTCPPortRequiresExactListeningPort(t *testing.T) {
	contents := []byte("" +
		"  sl  local_address rem_address   st tx_queue rx_queue\n" +
		"   0: 01630B0A:0050 00000000:0000 0A 00000000:00000000\n")
	if !containsListeningTCPPort(contents, filesReadinessPortHex) {
		t.Fatal("exact TCP/80 listener was not detected")
	}

	for name, candidate := range map[string][]byte{
		"wrong state": []byte("0: 01630B0A:0050 00000000:0000 01 0:0\n"),
		"wrong port":  []byte("0: 01630B0A:0051 00000000:0000 0A 0:0\n"),
		"malformed":   []byte("not a tcp table\n"),
	} {
		t.Run(name, func(t *testing.T) {
			if containsListeningTCPPort(candidate, filesReadinessPortHex) {
				t.Fatal("non-listener entry was accepted")
			}
		})
	}
}

func TestWatchdogFilesCleanupAlwaysAttemptsPhysicalRestore(t *testing.T) {
	var events []string
	err := restoreInputAfterFilesCleanup(
		func() error {
			events = append(events, "files cleanup")
			return errors.New("files cleanup failed")
		},
		func() error {
			events = append(events, "physical restore")
			return nil
		},
		func() error {
			events = append(events, "finalize")
			return nil
		},
	)
	if err == nil || err.Error() != "files cleanup failed" {
		t.Fatalf("restoreInputAfterFilesCleanup error = %v", err)
	}
	want := []string{"files cleanup", "physical restore"}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestNormalFilesCleanupFailureDelegatesRetryToWatchdog(t *testing.T) {
	if !inputWatchdogRecoveryRequired(nil, errors.New("files cleanup failed")) {
		t.Fatal("Files cleanup failure did not require watchdog recovery")
	}
	if !inputWatchdogRecoveryRequired(errors.New("physical restore failed"), nil) {
		t.Fatal("physical restore failure did not require watchdog recovery")
	}
	if inputWatchdogRecoveryRequired(nil, nil) {
		t.Fatal("successful cleanup unexpectedly required watchdog recovery")
	}
}

func TestClaimFilesFallbackOwnsMarkerBeforeAddingAddress(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	claim, err := claimFilesFallbackAddressWith(
		ownerPath,
		emptyAddressList,
		func(string) (bool, error) { return false, nil },
	)
	if err != nil {
		t.Fatalf("claimFilesFallbackAddressWith returned %v", err)
	}
	if !claim.Owned || !claim.UseFallback || !claim.NeedsAddress {
		t.Fatalf("claim = %#v", claim)
	}
	contents, err := os.ReadFile(ownerPath)
	if err != nil || string(contents) != filesFallbackOwnerValue {
		t.Fatalf("owner marker = %q, %v", contents, err)
	}

	var calls [][]string
	err = activateFilesFallbackAddressWith(
		claim,
		func(name string, args ...string) error {
			if owned, ownerErr := hasFilesFallbackOwner(ownerPath); ownerErr != nil || !owned {
				t.Fatalf("address mutation ran without owner marker: %v", ownerErr)
			}
			calls = append(calls, append([]string{name}, args...))
			return nil
		})
	if err != nil {
		t.Fatalf("activateFilesFallbackAddressWith returned %v", err)
	}
	want := [][]string{{"ip", "address", "add", filesFallbackCIDR, "dev", filesFallbackInterface}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("network calls = %#v, want %#v", calls, want)
	}
}

func TestOwnedExistingFallbackIsReannouncedAfterXochitlIsReady(t *testing.T) {
	claim := filesFallbackClaim{Owned: true, UseFallback: true, NeedsAddress: false}
	var calls [][]string
	err := activateFilesFallbackAddressWith(
		claim,
		func(name string, args ...string) error {
			calls = append(calls, append([]string{name}, args...))
			return nil
		})
	if err != nil {
		t.Fatalf("activateFilesFallbackAddressWith returned %v", err)
	}
	want := [][]string{
		{"ip", "address", "delete", filesFallbackCIDR, "dev", filesFallbackInterface},
		{"ip", "address", "add", filesFallbackCIDR, "dev", filesFallbackInterface},
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("network calls = %#v, want %#v", calls, want)
	}
}

func TestClaimFilesFallbackRequiresPrimaryCarrier(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	list := func(interfaceName string) ([]net.Addr, error) {
		if interfaceName == filesPrimaryInterface {
			return []net.Addr{ipNetwork(filesFallbackHost, 27)}, nil
		}
		return nil, nil
	}
	claim, err := claimFilesFallbackAddressWith(
		ownerPath,
		list,
		func(string) (bool, error) { return false, nil },
	)
	if err != nil {
		t.Fatalf("carrier-zero claim returned %v", err)
	}
	if !claim.Owned || !claim.UseFallback || !claim.NeedsAddress {
		t.Fatalf("carrier-zero claim = %#v", claim)
	}

	if err := cleanupFilesFallbackAddressWith(ownerPath, emptyAddressList, noNetworkCommand); err != nil {
		t.Fatalf("cleanup returned %v", err)
	}
	claim, err = claimFilesFallbackAddressWith(
		ownerPath,
		list,
		func(string) (bool, error) { return true, nil },
	)
	if err != nil {
		t.Fatalf("carrier-one claim returned %v", err)
	}
	if claim != (filesFallbackClaim{}) {
		t.Fatalf("carrier-one claim = %#v, want empty", claim)
	}
}

func TestClaimFilesFallbackPreservesPreexistingFallbackAddress(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	claim, err := claimFilesFallbackAddressWith(
		ownerPath,
		func(interfaceName string) ([]net.Addr, error) {
			if interfaceName == filesFallbackInterface {
				return []net.Addr{ipNetwork(filesFallbackHost, 32)}, nil
			}
			return nil, nil
		},
		func(string) (bool, error) { return false, nil },
	)
	if err != nil {
		t.Fatalf("claim returned %v", err)
	}
	if claim.Owned || !claim.UseFallback || claim.NeedsAddress {
		t.Fatalf("claim = %#v", claim)
	}
	if _, err := os.Stat(ownerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected owner marker: %v", err)
	}
}

func TestCleanupFilesFallbackDeletesOwnedExactAddressBeforeMarker(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	writeOwner(t, ownerPath)
	var calls [][]string
	err := cleanupFilesFallbackAddressWith(
		ownerPath,
		func(interfaceName string) ([]net.Addr, error) {
			return []net.Addr{ipNetwork(filesFallbackHost, 32)}, nil
		},
		func(name string, args ...string) error {
			if owned, ownerErr := hasFilesFallbackOwner(ownerPath); ownerErr != nil || !owned {
				t.Fatalf("marker disappeared before delete: %v", ownerErr)
			}
			calls = append(calls, append([]string{name}, args...))
			return nil
		})
	if err != nil {
		t.Fatalf("cleanup returned %v", err)
	}
	want := [][]string{{"ip", "address", "delete", filesFallbackCIDR, "dev", filesFallbackInterface}}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("network calls = %#v, want %#v", calls, want)
	}
	if _, err := os.Stat(ownerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("owner marker remains after delete: %v", err)
	}
}

func TestCleanupFilesFallbackFailureRetainsMarkerForWatchdog(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	writeOwner(t, ownerPath)
	err := cleanupFilesFallbackAddressWith(
		ownerPath,
		func(string) ([]net.Addr, error) {
			return []net.Addr{ipNetwork(filesFallbackHost, 32)}, nil
		},
		func(string, ...string) error { return errors.New("delete failed") },
	)
	if ErrorCode(err) != "files_fallback_address_remove_failed" {
		t.Fatalf("ErrorCode(%v) = %q", err, ErrorCode(err))
	}
	if owned, ownerErr := hasFilesFallbackOwner(ownerPath); ownerErr != nil || !owned {
		t.Fatalf("owner marker was not retained: %v", ownerErr)
	}
}

func TestClaimFilesFallbackRejectsPrimaryInspectionFailure(t *testing.T) {
	ownerPath := filepath.Join(t.TempDir(), "owner")
	_, err := claimFilesFallbackAddressWith(
		ownerPath,
		func(interfaceName string) ([]net.Addr, error) {
			if interfaceName == filesPrimaryInterface {
				return nil, errors.New("primary lookup failed")
			}
			return nil, nil
		},
		func(string) (bool, error) { return false, nil },
	)
	if ErrorCode(err) != "files_fallback_primary_inspection_failed" {
		t.Fatalf("ErrorCode(%v) = %q", err, ErrorCode(err))
	}
	if _, statErr := os.Stat(ownerPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("primary failure created ownership: %v", statErr)
	}
}

func emptyAddressList(string) ([]net.Addr, error) { return nil, nil }
func noNetworkCommand(string, ...string) error    { return nil }

func ipNetwork(host string, prefix int) net.Addr {
	return &net.IPNet{IP: net.ParseIP(host), Mask: net.CIDRMask(prefix, 32)}
}

func writeOwner(t *testing.T, ownerPath string) {
	t.Helper()
	if err := os.WriteFile(ownerPath, []byte(filesFallbackOwnerValue), 0o600); err != nil {
		t.Fatalf("write owner: %v", err)
	}
}
