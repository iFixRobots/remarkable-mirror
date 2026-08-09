package deploy

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestLegacyActiveServiceRollbackUsesCompatibleStatusContract(t *testing.T) {
	installer, err := os.ReadFile("install-transport-wake.sh")
	if err != nil {
		t.Fatalf("read installer: %v", err)
	}

	var functions strings.Builder
	for _, name := range []string{
		"release_installer_wake_lock",
		"current_status_is_healthy",
		"legacy_status_is_healthy",
		"wait_for_healthy_status",
		"restore_anchor",
		"cleanup_install_transaction",
		"rollback_install_transaction",
	} {
		functions.WriteString(extractShellFunction(t, string(installer), name))
		functions.WriteByte('\n')
	}

	tests := []struct {
		name   string
		status string
	}{
		{
			name:   "holding",
			status: `{"schema":"rmmirror.transport-wake/v1","state":"holding","usb_carrier":true,"carrier_known":true,"wake_lock_active":true,"system_sleep_blocked":true,"wake_endpoint_healthy":true,"updated_utc":"2026-08-07T12:00:00Z"}`,
		},
		{
			name:   "idle",
			status: `{"schema":"rmmirror.transport-wake/v1","state":"idle","usb_carrier":false,"carrier_known":true,"wake_lock_active":false,"system_sleep_blocked":false,"wake_endpoint_healthy":true,"updated_utc":"2026-08-07T12:00:00Z"}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			testRoot := t.TempDir()
			statusPath := filepath.Join(testRoot, "run", "rmmirror-transport-wake.json")
			if err := os.MkdirAll(filepath.Dir(statusPath), 0o755); err != nil {
				t.Fatalf("create status directory: %v", err)
			}

			harness := functions.String() + `
set -eu

test_root=$RMMIRROR_TEST_ROOT
status_path=$RMMIRROR_TEST_STATUS
binary_anchor=$test_root/usr/libexec/rmmirror-transport-wake
unit_anchor=$test_root/usr/lib/systemd/system/rmmirror-transport-wake.service
sleep_guard_directory=$test_root/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d
sleep_guard_anchor=$sleep_guard_directory/50-rmmirror-usb-carrier.conf
install_rollback_directory=$test_root/run/rollback
install_rollback_binary=$install_rollback_directory/rmmirror-transport-wake
install_rollback_unit=$install_rollback_directory/rmmirror-transport-wake.service
install_rollback_sleep_guard=$install_rollback_directory/rmmirror-usb-sleep-guard.conf
wake_unlock_path=$test_root/sys/power/wake_unlock
installer_wake_lock_name=rmmirror-usb-install-test
prior_binary_present=1
prior_unit_present=1
prior_sleep_guard_present=1
prior_persistent_enable_present=1
prior_service_enabled=0
prior_service_enabled_runtime=0
prior_service_active=1
install_mutation_started=1
installer_wake_lock_active=1
root_remounted=1
start_called=0

legacy_status=$RMMIRROR_TEST_LEGACY_STATUS
current_status='{"schema":"rmmirror.transport-wake/v1","state":"holding","usb_connection_policy":"carrier-qualified-power-hold/v1","usb_carrier":true,"carrier_known":true,"usb_power_online":true,"power_known":true,"usb_connected":true,"connection_known":true,"usb_data_qualified":true,"wake_lock_active":true,"system_sleep_blocked":true,"wake_endpoint_healthy":true,"updated_utc":"2026-08-07T12:00:00Z"}'
mkdir -p "$install_rollback_directory" "$sleep_guard_directory" \
    "$(dirname "$binary_anchor")" "$(dirname "$wake_unlock_path")"
printf '%s\n' legacy-binary > "$install_rollback_binary"
printf '%s\n' legacy-unit > "$install_rollback_unit"
printf '%s\n' legacy-guard > "$install_rollback_sleep_guard"
printf '%s\n' candidate-binary > "$binary_anchor"
printf '%s\n' candidate-unit > "$unit_anchor"
printf '%s\n' candidate-guard > "$sleep_guard_anchor"
printf '%s\n' "$legacy_status" > "$status_path"
sleep() { return 0; }

if wait_for_healthy_status current; then
    printf '%s\n' 'legacy carrier-only status satisfied the current candidate contract' >&2
    exit 1
fi
printf '%s\n' "$current_status" > "$status_path"
wait_for_healthy_status current

stop_pending_system_sleep() { return 0; }
stop_transport_service() { return 0; }
make_root_writable() { root_remounted=1; }
restore_root_mount() { root_remounted=0; }
remove_persistent_enablement() { return 0; }
publish_persistent_enablement() { return 0; }
sync() { return 0; }
installer_wake_lock_is_active() { test ! -e "$wake_unlock_path"; }
systemctl() {
    case "$1" in
        daemon-reload|disable|reset-failed) return 0 ;;
        is-enabled) printf '%s\n' static; return 0 ;;
        is-active) return 0 ;;
        start)
            start_called=1
            printf '%s\n' "$legacy_status" > "$status_path"
            return 0
            ;;
        *)
            printf 'unexpected systemctl command: %s\n' "$*" >&2
            return 1
            ;;
    esac
}

rollback_install_transaction
test "$start_called" -eq 1
test "$installer_wake_lock_active" -eq 0
test "$(cat "$binary_anchor")" = legacy-binary
test "$(cat "$unit_anchor")" = legacy-unit
test "$(cat "$sleep_guard_anchor")" = legacy-guard
test "$(cat "$wake_unlock_path")" = "$installer_wake_lock_name"
test ! -e "$install_rollback_directory"
legacy_status_is_healthy
`

			command := exec.Command("/bin/sh")
			command.Stdin = strings.NewReader(harness)
			command.Env = append(
				os.Environ(),
				"RMMIRROR_TEST_ROOT="+testRoot,
				"RMMIRROR_TEST_STATUS="+statusPath,
				"RMMIRROR_TEST_LEGACY_STATUS="+test.status,
			)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("legacy rollback harness: %v\n%s", err, output)
			}
		})
	}
}

func extractShellFunction(t *testing.T, source, name string) string {
	t.Helper()
	marker := name + "() {"
	start := strings.Index(source, marker)
	if start < 0 {
		t.Fatalf("installer does not define %s", name)
	}

	var function strings.Builder
	for _, line := range strings.Split(source[start:], "\n") {
		function.WriteString(line)
		function.WriteByte('\n')
		if line == "}" {
			return function.String()
		}
	}
	t.Fatalf("installer function %s is unterminated", name)
	return ""
}
