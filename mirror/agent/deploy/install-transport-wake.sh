#!/bin/sh

set -eu

mode=${1:-install}
if test "$mode" != install && test "$mode" != remove; then
    printf '%s\n' 'usage: install-transport-wake.sh [install|remove]' >&2
    exit 2
fi

asset_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary_source="$asset_root/rmmirror-transport-wake"
unit_source="$asset_root/rmmirror-transport-wake.service"
sleep_guard_source="$asset_root/rmmirror-usb-sleep-guard.conf"
binary_anchor=/usr/libexec/rmmirror-transport-wake
unit_anchor=/usr/lib/systemd/system/rmmirror-transport-wake.service
persistent_wants_directory=/usr/lib/systemd/system/multi-user.target.wants
persistent_enable_anchor=$persistent_wants_directory/rmmirror-transport-wake.service
persistent_enable_target=../rmmirror-transport-wake.service
sleep_guard_directory=/usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d
sleep_guard_anchor=$sleep_guard_directory/50-rmmirror-usb-carrier.conf
status_path=/run/rmmirror-transport-wake.json
power_online_path=/sys/class/power_supply/max77818-charger/online
wake_lock_path=/sys/power/wake_lock
wake_unlock_path=/sys/power/wake_unlock
installer_wake_lock_name="rmmirror-usb-install-$$"
installer_wake_lock_timeout_ns=300000000000
installer_wake_lock_active=0
expected_transport_version=0.6.0
token_directory=/data/rmmirror
token_path=$token_directory/wake-token
token_temporary=
token_entropy=
root_remounted=0
install_transaction_ready=0
install_transaction_committed=0
install_rollback_root=/run
install_rollback_directory=
install_rollback_binary=
install_rollback_unit=
install_rollback_sleep_guard=
prior_binary_present=0
prior_unit_present=0
prior_sleep_guard_present=0
prior_persistent_enable_present=0
prior_service_enabled=0
prior_service_enabled_runtime=0
prior_service_active=0
install_mutation_started=0
legacy_sleep_units='sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target'
legacy_sleep_mask_ownership=/run/rmmirror-transport-wake-sleep-masks

restore_root_mount() {
    if test "$root_remounted" -eq 1; then
        if ! mount -o remount,ro /; then
            root_options=$(awk '$2 == "/" { print $4; exit }' /proc/mounts)
            case ",$root_options," in
                *,ro,*) root_remounted=0; return 0 ;;
                *) return 1 ;;
            esac
        fi
        root_options=$(awk '$2 == "/" { print $4; exit }' /proc/mounts)
        case ",$root_options," in
            *,ro,*) ;;
            *) return 1 ;;
        esac
        root_remounted=0
    fi
}

installer_wake_lock_is_active() {
    awk -v lock_name="$installer_wake_lock_name" '
        {
            for (field = 1; field <= NF; field += 1) {
                if ($field == lock_name) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$wake_lock_path"
}

acquire_installer_wake_lock() {
    test "$installer_wake_lock_active" -eq 0
    printf '%s %s\n' "$installer_wake_lock_name" "$installer_wake_lock_timeout_ns" > "$wake_lock_path"
    installer_wake_lock_is_active
    installer_wake_lock_active=1
}

release_installer_wake_lock() {
    if test "$installer_wake_lock_active" -eq 0; then
        return 0
    fi
    printf '%s\n' "$installer_wake_lock_name" > "$wake_unlock_path"
    if installer_wake_lock_is_active; then
        return 1
    fi
    installer_wake_lock_active=0
}

current_status_is_healthy() {
    test -r "$status_path" &&
        grep -q '"schema":"rmmirror.transport-wake/v1"' "$status_path" &&
        grep -q '"usb_connection_policy":"carrier-qualified-power-hold/v1"' "$status_path" &&
        grep -q '"power_known":true' "$status_path" &&
        grep -q '"connection_known":true' "$status_path" &&
        grep -q '"wake_endpoint_healthy":true' "$status_path" &&
        ! grep -q '"error":' "$status_path" &&
        {
            {
                grep -q '"usb_connected":true' "$status_path" &&
                    grep -q '"usb_data_qualified":true' "$status_path" &&
                    grep -q '"state":"holding"' "$status_path" &&
                    grep -q '"wake_lock_active":true' "$status_path" &&
                    grep -q '"system_sleep_blocked":true' "$status_path"
            } || {
                grep -q '"usb_connected":false' "$status_path" &&
                    grep -q '"usb_data_qualified":false' "$status_path" &&
                    grep -q '"state":"idle"' "$status_path" &&
                    grep -q '"wake_lock_active":false' "$status_path" &&
                    grep -q '"system_sleep_blocked":false' "$status_path"
            }
        }
}

current_status_is_operational() {
    current_status_is_healthy &&
        grep -q '"usb_connected":true' "$status_path" &&
        grep -q '"usb_data_qualified":true' "$status_path" &&
        grep -q '"state":"holding"' "$status_path" &&
        grep -q '"wake_lock_active":true' "$status_path" &&
        grep -q '"system_sleep_blocked":true' "$status_path"
}

legacy_status_is_healthy() {
    test -r "$status_path" &&
        grep -q '"schema":"rmmirror.transport-wake/v1"' "$status_path" &&
        ! grep -q '"usb_connection_policy":' "$status_path" &&
        grep -q '"carrier_known":true' "$status_path" &&
        grep -q '"wake_endpoint_healthy":true' "$status_path" &&
        ! grep -q '"error":' "$status_path" &&
        {
            {
                grep -q '"usb_carrier":true' "$status_path" &&
                    grep -q '"state":"holding"' "$status_path" &&
                    grep -q '"wake_lock_active":true' "$status_path" &&
                    grep -q '"system_sleep_blocked":true' "$status_path"
            } || {
                grep -q '"usb_carrier":false' "$status_path" &&
                    grep -q '"state":"idle"' "$status_path" &&
                    grep -q '"wake_lock_active":false' "$status_path" &&
                    grep -q '"system_sleep_blocked":false' "$status_path"
            }
        }
}

wait_for_healthy_status() {
    expected_contract=$1
    case "$expected_contract" in
        current|rollback-compatible) ;;
        *) return 2 ;;
    esac
    attempt=0
    while test "$attempt" -lt 200; do
        if current_status_is_healthy; then
            return 0
        fi
        if test "$expected_contract" = rollback-compatible && legacy_status_is_healthy; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return 1
}

wait_for_operational_status() {
    attempt=0
    while test "$attempt" -lt 200; do
        if current_status_is_operational; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return 1
}

stop_transport_service() {
    systemctl stop rmmirror-transport-wake.service >/dev/null 2>&1 || true
    active_state=$(systemctl is-active rmmirror-transport-wake.service 2>/dev/null || true)
    case "$active_state" in
        inactive|failed) return 0 ;;
        *) return 1 ;;
    esac
}

stop_pending_system_sleep() {
    systemctl stop suspend-then-hibernate.target >/dev/null 2>&1 || true
    systemctl stop systemd-suspend-then-hibernate.service >/dev/null 2>&1 || true
    for unit in suspend-then-hibernate.target systemd-suspend-then-hibernate.service; do
        active_state=$(systemctl is-active "$unit" 2>/dev/null || true)
        case "$active_state" in
            inactive|failed) ;;
            *) return 1 ;;
        esac
    done
}

make_root_writable() {
    root_options=$(awk '$2 == "/" { print $4; exit }' /proc/mounts)
    case ",$root_options," in
        *,rw,*) return 0 ;;
    esac
    if ! mount -o remount,rw /; then
        root_options=$(awk '$2 == "/" { print $4; exit }' /proc/mounts)
        case ",$root_options," in
            *,rw,*) root_remounted=1; return 0 ;;
            *) return 1 ;;
        esac
    fi
    root_options=$(awk '$2 == "/" { print $4; exit }' /proc/mounts)
    case ",$root_options," in
        *,rw,*) ;;
        *) return 1 ;;
    esac
    root_remounted=1
}

publish_anchor() {
    source_path=$1
    target_path=$2
    target_mode=$3
    rm -f "$target_path.new"
    cp "$source_path" "$target_path.new"
    chown 0:0 "$target_path.new"
    chmod "$target_mode" "$target_path.new"
    mv -f "$target_path.new" "$target_path"
}

persistent_enablement_is_exact() {
    test -L "$persistent_enable_anchor" &&
        test "$(readlink "$persistent_enable_anchor")" = "$persistent_enable_target"
}

validate_persistent_enablement_path() {
    if test -L "$persistent_enable_anchor"; then
        if ! persistent_enablement_is_exact; then
            printf '%s\n' "rmmirror-transport-wake: refusing unexpected enablement link $persistent_enable_anchor" >&2
            return 1
        fi
        return
    fi
    if test -e "$persistent_enable_anchor"; then
        printf '%s\n' "rmmirror-transport-wake: refusing unexpected enablement path $persistent_enable_anchor" >&2
        return 1
    fi
}

publish_persistent_enablement() {
    mkdir -p "$persistent_wants_directory"
    if test -L "$persistent_enable_anchor"; then
        persistent_enablement_is_exact
        return
    fi
    if test -e "$persistent_enable_anchor"; then
        printf '%s\n' "rmmirror-transport-wake: refusing unexpected enablement path $persistent_enable_anchor" >&2
        return 1
    fi
    rm -f "$persistent_enable_anchor.new"
    ln -s "$persistent_enable_target" "$persistent_enable_anchor.new"
    test -L "$persistent_enable_anchor.new"
    test "$(readlink "$persistent_enable_anchor.new")" = "$persistent_enable_target"
    mv -f "$persistent_enable_anchor.new" "$persistent_enable_anchor"
    persistent_enablement_is_exact
}

remove_persistent_enablement() {
    rm -f "$persistent_enable_anchor.new"
    validate_persistent_enablement_path
    if test -L "$persistent_enable_anchor"; then
        rm -f "$persistent_enable_anchor"
    fi
}

snapshot_anchor() {
    current_path=$1
    snapshot_path=$2
    if test -L "$current_path"; then
        printf '%s\n' "rmmirror-transport-wake: refusing to snapshot symlink $current_path" >&2
        return 1
    fi
    if test -e "$current_path"; then
        test -f "$current_path"
        cp -p "$current_path" "$snapshot_path"
        test -f "$snapshot_path"
        test ! -L "$snapshot_path"
        return 0
    fi
    return 2
}

restore_anchor() {
    snapshot_path=$1
    target_path=$2
    was_present=$3
    rm -f "$target_path.new"
    if test "$was_present" -eq 1; then
        test -f "$snapshot_path"
        test ! -L "$snapshot_path"
        cp -p "$snapshot_path" "$target_path.new"
        mv -f "$target_path.new" "$target_path"
    else
        rm -f "$target_path"
    fi
}

begin_install_transaction() {
    install_rollback_directory=$install_rollback_root/rmmirror-transport-wake-install.$$
    install_rollback_binary=$install_rollback_directory/rmmirror-transport-wake
    install_rollback_unit=$install_rollback_directory/rmmirror-transport-wake.service
    install_rollback_sleep_guard=$install_rollback_directory/rmmirror-usb-sleep-guard.conf
    test ! -e "$install_rollback_directory"
    test ! -L "$install_rollback_directory"
    (umask 077 && mkdir "$install_rollback_directory")

    snapshot_status=0
    snapshot_anchor "$binary_anchor" "$install_rollback_binary" || snapshot_status=$?
    case "$snapshot_status" in
        0) prior_binary_present=1 ;;
        2) ;;
        *) return 1 ;;
    esac

    snapshot_status=0
    snapshot_anchor "$unit_anchor" "$install_rollback_unit" || snapshot_status=$?
    case "$snapshot_status" in
        0) prior_unit_present=1 ;;
        2) ;;
        *) return 1 ;;
    esac

    snapshot_status=0
    snapshot_anchor "$sleep_guard_anchor" "$install_rollback_sleep_guard" || snapshot_status=$?
    case "$snapshot_status" in
        0) prior_sleep_guard_present=1 ;;
        2) ;;
        *) return 1 ;;
    esac

    validate_persistent_enablement_path
    if test -L "$persistent_enable_anchor"; then
        prior_persistent_enable_present=1
    fi

    prior_enable_state=$(systemctl is-enabled rmmirror-transport-wake.service 2>/dev/null || true)
    case "$prior_enable_state" in
        enabled) prior_service_enabled=1 ;;
        enabled-runtime)
            prior_service_enabled=1
            prior_service_enabled_runtime=1
            ;;
        disabled|indirect|not-found|static) ;;
        '')
            if test "$prior_unit_present" -ne 0; then
                printf '%s\n' 'rmmirror-transport-wake: prior enable state is unavailable' >&2
                return 1
            fi
            ;;
        *)
            printf '%s\n' "rmmirror-transport-wake: unexpected prior enable state: $prior_enable_state" >&2
            return 1
            ;;
    esac

    prior_active_state=$(systemctl is-active rmmirror-transport-wake.service 2>/dev/null || true)
    case "$prior_active_state" in
        active) prior_service_active=1 ;;
        inactive|failed|unknown) ;;
        '')
            if test "$prior_unit_present" -ne 0; then
                printf '%s\n' 'rmmirror-transport-wake: prior active state is unavailable' >&2
                return 1
            fi
            ;;
        *)
            printf '%s\n' "rmmirror-transport-wake: unexpected prior active state: $prior_active_state" >&2
            return 1
            ;;
    esac
    install_transaction_ready=1
}

cleanup_install_transaction() {
    if test -n "$install_rollback_binary"; then
        rm -f "$install_rollback_binary"
    fi
    if test -n "$install_rollback_unit"; then
        rm -f "$install_rollback_unit"
    fi
    if test -n "$install_rollback_sleep_guard"; then
        rm -f "$install_rollback_sleep_guard"
    fi
    if test -n "$install_rollback_directory" && test -d "$install_rollback_directory"; then
        rmdir "$install_rollback_directory"
    fi
}

rollback_install_transaction() {
    rollback_failed=0
    sleep_guard_unloaded=0
    service_stopped=0
    system_sleep_stopped=0
    printf '%s\n' 'rmmirror-transport-wake: install failed; restoring previous prerequisite state' >&2

    if test "$install_mutation_started" -eq 0; then
        restore_root_mount || return 1
        release_installer_wake_lock || return 1
        cleanup_install_transaction || return 1
        printf '%s\n' 'rmmirror-transport-wake: previous prerequisite state restored' >&2
        return 0
    fi

    if stop_pending_system_sleep; then
        system_sleep_stopped=1
    else
        rollback_failed=1
    fi
    if stop_transport_service; then
        service_stopped=1
        rm -f "$status_path" || rollback_failed=1
    else
        rollback_failed=1
    fi
    make_root_writable || rollback_failed=1

    if test "$service_stopped" -eq 1 && test "$system_sleep_stopped" -eq 1 &&
        { test "$root_remounted" -eq 1 || grep -qE '^[^ ]+ / [^ ]+ rw(,| )' /proc/mounts; }; then
        mkdir -p "$(dirname "$binary_anchor")" "$(dirname "$unit_anchor")" || rollback_failed=1

        # Never leave the candidate ExecCondition loaded while restoring an
        # older binary that may not implement the command it references. First
        # remove and reload the candidate guard while the compatible candidate
        # binary is still installed. The distinct timed installer wake lock
        # protects this bounded fail-open handoff.
        if restore_anchor "$install_rollback_sleep_guard" "$sleep_guard_anchor" 0; then
            rmdir "$sleep_guard_directory" 2>/dev/null || true
            if systemctl daemon-reload >/dev/null 2>&1; then
                if stop_pending_system_sleep; then
                    system_sleep_stopped=1
                    sleep_guard_unloaded=1
                else
                    rollback_failed=1
                fi
            else
                rollback_failed=1
            fi
        else
            rollback_failed=1
        fi

        if test "$sleep_guard_unloaded" -eq 1; then
            # Remove any enablement created by this attempt while the candidate
            # unit is still loaded. Restore the exact prior anchors and state.
            systemctl disable rmmirror-transport-wake.service >/dev/null 2>&1 || true
            remove_persistent_enablement || rollback_failed=1
            restore_anchor "$install_rollback_binary" "$binary_anchor" "$prior_binary_present" || rollback_failed=1
            restore_anchor "$install_rollback_unit" "$unit_anchor" "$prior_unit_present" || rollback_failed=1
            if test "$prior_sleep_guard_present" -eq 1; then
                mkdir -p "$sleep_guard_directory" || rollback_failed=1
                restore_anchor "$install_rollback_sleep_guard" "$sleep_guard_anchor" 1 || rollback_failed=1
            fi
            if test "$prior_persistent_enable_present" -eq 1; then
                publish_persistent_enablement || rollback_failed=1
            fi
            systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1

            if test "$prior_service_enabled" -eq 1; then
                if test "$prior_service_enabled_runtime" -eq 1; then
                    systemctl enable --runtime rmmirror-transport-wake.service >/dev/null 2>&1 || rollback_failed=1
                    expected_enable_state=enabled-runtime
                else
                    systemctl enable rmmirror-transport-wake.service >/dev/null 2>&1 || rollback_failed=1
                    expected_enable_state=enabled
                fi
                restored_enable_state=$(systemctl is-enabled rmmirror-transport-wake.service 2>/dev/null || true)
                test "$restored_enable_state" = "$expected_enable_state" || rollback_failed=1
            else
                restored_enable_state=$(systemctl is-enabled rmmirror-transport-wake.service 2>/dev/null || true)
                case "$restored_enable_state" in
                    disabled|indirect|not-found|static) ;;
                    *) rollback_failed=1 ;;
                esac
            fi
            sync || rollback_failed=1
        fi
    else
        rollback_failed=1
    fi

    restore_root_mount >/dev/null 2>&1 || rollback_failed=1
    if test "$rollback_failed" -eq 0; then
        if test "$prior_service_active" -eq 1; then
            if test "$install_mutation_started" -eq 1; then
                systemctl reset-failed rmmirror-transport-wake.service >/dev/null 2>&1 || true
                systemctl start rmmirror-transport-wake.service >/dev/null 2>&1 || rollback_failed=1
            fi
            systemctl is-active --quiet rmmirror-transport-wake.service || rollback_failed=1
            wait_for_healthy_status rollback-compatible || rollback_failed=1
        else
            stop_transport_service || rollback_failed=1
        fi
    fi

    # Explicitly release only after either the former active service is healthy
    # for its current carrier state or the former inactive state has been
    # restored. If rollback fails, the distinct timed lock remains as a bounded
    # kill-safe guard.
    if test "$rollback_failed" -eq 0; then
        release_installer_wake_lock || rollback_failed=1
    fi
    if test "$rollback_failed" -ne 0; then
        printf '%s\n' "rmmirror-transport-wake: rollback failed; preserved snapshots at $install_rollback_directory" >&2
        return 1
    fi
    cleanup_install_transaction || return 1
    printf '%s\n' 'rmmirror-transport-wake: previous prerequisite state restored' >&2
}

ensure_wake_token() {
    test -d /data
    mkdir -p "$token_directory"
    test ! -L "$token_directory"
    chown 0:0 "$token_directory"
    chmod 0700 "$token_directory"

    if test -e "$token_path"; then
        test ! -L "$token_path"
        test -f "$token_path"
        test "$(wc -c < "$token_path" | tr -d ' ')" -eq 64
        LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' "$token_path"
    else
        token_temporary=$token_path.new.$$
        token_entropy=$token_temporary.random
        rm -f "$token_temporary" "$token_entropy"
        (
            umask 077
            dd if=/dev/urandom of="$token_entropy" bs=32 count=1 2>/dev/null
            test "$(wc -c < "$token_entropy" | tr -d ' ')" -eq 32
            token_value=$(sha256sum "$token_entropy" | cut -d' ' -f1)
            printf '%s' "$token_value" > "$token_temporary"
        )
        rm -f "$token_entropy"
        token_entropy=
        test "$(wc -c < "$token_temporary" | tr -d ' ')" -eq 64
        LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$token_temporary"
        chown 0:0 "$token_temporary"
        chmod 0600 "$token_temporary"
        mv -f "$token_temporary" "$token_path"
        token_temporary=
    fi
    chown 0:0 "$token_path"
    chmod 0600 "$token_path"
}

cleanup_legacy_sleep_masks() {
    # Versions before 0.4 recorded only the runtime masks they created. Use
    # that journal to migrate or remove them without touching an owner's mask.
    owned_sleep_units=
    if test -e "$legacy_sleep_mask_ownership" || test -L "$legacy_sleep_mask_ownership"; then
        if test -L "$legacy_sleep_mask_ownership" || ! test -r "$legacy_sleep_mask_ownership"; then
            printf '%s\n' 'rmmirror-transport-wake: invalid legacy sleep-mask ownership journal' >&2
            return 1
        fi
        for unit in $(cat "$legacy_sleep_mask_ownership"); do
            case " $legacy_sleep_units " in
                *" $unit "*) owned_sleep_units="$owned_sleep_units $unit" ;;
                *)
                    printf '%s\n' 'rmmirror-transport-wake: invalid legacy sleep-mask ownership entry' >&2
                    return 1
                    ;;
            esac
        done
        if test -n "$owned_sleep_units"; then
            if ! systemctl unmask --runtime -- $owned_sleep_units >/dev/null 2>&1; then
                printf '%s\n' 'rmmirror-transport-wake: could not remove owned legacy runtime sleep masks' >&2
                return 1
            fi
        fi
        rm -f "$legacy_sleep_mask_ownership"
    fi
}

on_exit() {
    exit_code=$?
    trap - EXIT
    set +e
    rollback_failed=0
    if test "$exit_code" -ne 0 &&
        test "$install_transaction_ready" -eq 1 &&
        test "$install_transaction_committed" -eq 0; then
        rollback_install_transaction || rollback_failed=1
    elif test -n "$install_rollback_directory"; then
        cleanup_install_transaction >/dev/null 2>&1 || true
    fi
    if test -n "$token_temporary"; then
        rm -f "$token_temporary"
    fi
    if test -n "$token_entropy"; then
        rm -f "$token_entropy"
    fi
    restore_root_mount >/dev/null 2>&1 || true
    if test "$installer_wake_lock_active" -eq 1; then
        printf '%s\n' 'rmmirror-transport-wake: timed installer wake lock remains until its automatic timeout' >&2
    fi
    if test "$rollback_failed" -ne 0; then
        exit 70
    fi
    exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if test "$mode" = remove; then
    validate_persistent_enablement_path
    test -r "$wake_lock_path"
    test -w "$wake_lock_path"
    test -w "$wake_unlock_path"
    acquire_installer_wake_lock
    stop_pending_system_sleep
    stop_transport_service
    cleanup_legacy_sleep_masks
    make_root_writable
    systemctl disable rmmirror-transport-wake.service 2>/dev/null || true
    remove_persistent_enablement
    rm -f "$sleep_guard_anchor"
    rmdir "$sleep_guard_directory" 2>/dev/null || true
    systemctl daemon-reload
    stop_pending_system_sleep
    rm -f "$binary_anchor" "$unit_anchor"
    sync
    restore_root_mount
    systemctl daemon-reload
    systemctl reset-failed rmmirror-transport-wake.service 2>/dev/null || true
    rm -f "$status_path"
    release_installer_wake_lock
    # Preserve /data/rmmirror/wake-token so reinstalling does not invalidate a
    # host that was already paired with this tablet.
    printf '%s\n' 'RMMIRROR_TRANSPORT_WAKE=removed'
    exit 0
fi

for source_path in "$binary_source" "$unit_source" "$sleep_guard_source"; do
    test -f "$source_path"
    test ! -L "$source_path"
done
test -r "$power_online_path"
test -r "$wake_lock_path"
test -w "$wake_lock_path"
test -w "$wake_unlock_path"
power_online_value=$(tr -d '[:space:]' < "$power_online_path")
case "$power_online_value" in
    0|1) ;;
    *)
        printf '%s\n' 'rmmirror-transport-wake: USB power state has an unexpected value' >&2
        exit 1
        ;;
esac
carrier_value=unknown
if test -r /sys/class/net/usb0/carrier; then
    carrier_value=$(tr -d '[:space:]' < /sys/class/net/usb0/carrier)
    case "$carrier_value" in
        0|1) ;;
        *) carrier_value=unknown ;;
    esac
fi
udc_state_count=0
udc_configured_count=0
udc_state_unknown=0
for candidate in /sys/class/udc/*/state; do
    test -e "$candidate" || continue
    udc_state_count=$((udc_state_count + 1))
    if ! test -r "$candidate"; then
        udc_state_unknown=1
        continue
    fi
    candidate_state=$(tr -d '[:space:]' < "$candidate")
    case "$candidate_state" in
        configured) udc_configured_count=$((udc_configured_count + 1)) ;;
        notattached|attached|powered|reconnecting|unauthenticated|default|addressed|suspended) ;;
        *) udc_state_unknown=1 ;;
    esac
done
udc_configured=0
if test "$udc_state_count" -gt 0 &&
    test "$udc_state_unknown" -eq 0 &&
    test "$udc_configured_count" -eq 1; then
    udc_configured=1
fi
if test "$carrier_value" != 1 && test "$udc_configured" != 1; then
    printf '%s\n' 'rmmirror-transport-wake: direct USB-C data is not configured' >&2
    exit 1
fi
ensure_wake_token

begin_install_transaction
acquire_installer_wake_lock
stop_pending_system_sleep
make_root_writable
install_mutation_started=1
mkdir -p /usr/libexec /usr/lib/systemd/system "$sleep_guard_directory"
systemctl disable rmmirror-transport-wake.service >/dev/null 2>&1 || true
remove_persistent_enablement
publish_anchor "$binary_source" "$binary_anchor" 0755
publish_anchor "$unit_source" "$unit_anchor" 0644
publish_anchor "$sleep_guard_source" "$sleep_guard_anchor" 0644
publish_persistent_enablement
systemctl daemon-reload
multi_user_wants=$(systemctl show --property=Wants --value -- multi-user.target)
case " $multi_user_wants " in
    *" rmmirror-transport-wake.service "*) ;;
    *)
        printf '%s\n' 'rmmirror-transport-wake: multi-user.target did not load the persistent dependency' >&2
        exit 1
        ;;
esac
loaded_sleep_guard=$(systemctl show --property=DropInPaths --value -- systemd-suspend-then-hibernate.service)
case " $loaded_sleep_guard " in
    *" $sleep_guard_anchor "*) ;;
    *)
        printf '%s\n' 'rmmirror-transport-wake: system sleep executor guard is not loaded' >&2
        exit 1
        ;;
esac
test "$("$binary_anchor" --version)" = "$expected_transport_version"
sleep_condition_exit=0
"$binary_anchor" allow-system-sleep --carrier /sys/class/net/usb0/carrier --udc-state-glob '/sys/class/udc/*/state' >/dev/null 2>&1 || sleep_condition_exit=$?
test "$sleep_condition_exit" -eq 1
sleep_hold_probe_exit=0
"$binary_anchor" hold-system-sleep --carrier "$install_rollback_directory/missing-carrier" --udc-state-glob "$install_rollback_directory/missing-udc/*/state" --power-online "$power_online_path" >/dev/null 2>&1 || sleep_hold_probe_exit=$?
test "$sleep_hold_probe_exit" -eq 0
test "$(systemctl is-enabled rmmirror-transport-wake.service)" = static
persistent_enablement_is_exact
sync

# Atomic publication leaves the running prior process attached to its old,
# now-unlinked executable inode. The original root-mount state cannot be restored
# until that process exits. The distinct timed installer wake lock is already
# active, so stop the old process, restore the original mount state, and then
# start the verified candidate.
stop_pending_system_sleep
stop_transport_service
restore_root_mount

rm -f "$status_path"
systemctl start rmmirror-transport-wake.service
systemctl is-active --quiet rmmirror-transport-wake.service
wait_for_operational_status
cleanup_legacy_sleep_masks
release_installer_wake_lock
install_transaction_committed=1
printf '%s\n' 'RMMIRROR_TRANSPORT_WAKE=installed'
