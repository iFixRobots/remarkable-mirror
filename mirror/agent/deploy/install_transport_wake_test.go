package deploy

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestLegacyActiveServiceRollbackUsesCompatibleStatusContract(t *testing.T) {
	installer, err := os.ReadFile("install-transport-wake.sh")
	if err != nil {
		t.Fatalf("read installer: %v", err)
	}
	shell, err := resolvePOSIXTestShell()
	if err != nil {
		t.Fatal(err)
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

			command := exec.Command(shell)
			command.Stdin = strings.NewReader(harness)
			command.Env = append(
				os.Environ(),
				"RMMIRROR_TEST_ROOT="+posixShellPath(testRoot),
				"RMMIRROR_TEST_STATUS="+posixShellPath(statusPath),
				"RMMIRROR_TEST_LEGACY_STATUS="+test.status,
			)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("legacy rollback harness: %v\n%s", err, output)
			}
		})
	}
}

func TestResolvePOSIXTestShell(t *testing.T) {
	t.Run("non-Windows uses system shell", func(t *testing.T) {
		shell, err := resolvePOSIXTestShellFor(
			"linux",
			func(string) (string, error) {
				t.Fatal("non-Windows resolution should not search PATH")
				return "", nil
			},
			func(string) string { return "" },
			func(string) bool { return false },
		)
		if err != nil {
			t.Fatalf("resolve shell: %v", err)
		}
		if shell != "/bin/sh" {
			t.Fatalf("shell = %q, want /bin/sh", shell)
		}
	})

	t.Run("Windows uses shell from PATH", func(t *testing.T) {
		want := filepath.Join("test-git", "bin", "sh.exe")
		shell, err := resolvePOSIXTestShellFor(
			"windows",
			func(name string) (string, error) {
				if name == "sh.exe" {
					return want, nil
				}
				return "", exec.ErrNotFound
			},
			func(string) string { return "" },
			func(string) bool { return false },
		)
		if err != nil {
			t.Fatalf("resolve shell: %v", err)
		}
		if shell != want {
			t.Fatalf("shell = %q, want %q", shell, want)
		}
	})

	t.Run("Windows derives shell from Git command", func(t *testing.T) {
		gitRoot := "test-git"
		gitPath := filepath.Join(gitRoot, "cmd", "git.exe")
		want := filepath.Join(gitRoot, "bin", "sh.exe")
		shell, err := resolvePOSIXTestShellFor(
			"windows",
			func(name string) (string, error) {
				if name == "git.exe" {
					return gitPath, nil
				}
				return "", exec.ErrNotFound
			},
			func(string) string { return "" },
			func(path string) bool { return path == want },
		)
		if err != nil {
			t.Fatalf("resolve shell: %v", err)
		}
		if shell != want {
			t.Fatalf("shell = %q, want %q", shell, want)
		}
	})

	t.Run("Windows finds a standard Git installation", func(t *testing.T) {
		programFiles := "test-program-files"
		want := filepath.Join(programFiles, "Git", "bin", "sh.exe")
		shell, err := resolvePOSIXTestShellFor(
			"windows",
			func(string) (string, error) { return "", exec.ErrNotFound },
			func(name string) string {
				if name == "ProgramFiles" {
					return programFiles
				}
				return ""
			},
			func(path string) bool { return path == want },
		)
		if err != nil {
			t.Fatalf("resolve shell: %v", err)
		}
		if shell != want {
			t.Fatalf("shell = %q, want %q", shell, want)
		}
	})
}

func TestPOSIXShellPath(t *testing.T) {
	windowsPath := `C:\Users\Example\AppData Local\Temp\mirror`
	if got, want := posixShellPathFor("windows", windowsPath), `C:/Users/Example/AppData Local/Temp/mirror`; got != want {
		t.Fatalf("Windows shell path = %q, want %q", got, want)
	}
	unixPath := "/tmp/mirror"
	if got := posixShellPathFor("linux", unixPath); got != unixPath {
		t.Fatalf("Unix shell path = %q, want %q", got, unixPath)
	}
}

func resolvePOSIXTestShell() (string, error) {
	return resolvePOSIXTestShellFor(runtime.GOOS, exec.LookPath, os.Getenv, isFile)
}

func resolvePOSIXTestShellFor(
	goos string,
	lookPath func(string) (string, error),
	getenv func(string) string,
	isFile func(string) bool,
) (string, error) {
	if goos != "windows" {
		return "/bin/sh", nil
	}

	if shell, err := lookPath("sh.exe"); err == nil {
		return shell, nil
	}

	if git, err := lookPath("git.exe"); err == nil {
		candidate := filepath.Join(filepath.Dir(filepath.Dir(git)), "bin", "sh.exe")
		if isFile(candidate) {
			return candidate, nil
		}
	}

	for _, location := range []struct {
		environment string
		path        []string
	}{
		{environment: "ProgramFiles", path: []string{"Git", "bin", "sh.exe"}},
		{environment: "ProgramFiles(x86)", path: []string{"Git", "bin", "sh.exe"}},
		{environment: "LOCALAPPDATA", path: []string{"Programs", "Git", "bin", "sh.exe"}},
	} {
		root := getenv(location.environment)
		if root == "" {
			continue
		}
		candidate := filepath.Join(append([]string{root}, location.path...)...)
		if isFile(candidate) {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("find POSIX shell: Git for Windows sh.exe is not available")
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func posixShellPath(path string) string {
	return posixShellPathFor(runtime.GOOS, path)
}

func posixShellPathFor(goos, path string) string {
	if goos == "windows" {
		return strings.ReplaceAll(path, `\`, "/")
	}
	return path
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
