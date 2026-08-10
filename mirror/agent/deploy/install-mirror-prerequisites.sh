#!/bin/sh

set -eu

failure_phase=starting
lock_directory=/run/rmmirror-prerequisites-install.lock
claim_path=/run/rmmirror-prerequisites-install.claim.$$
lock_acquired=false
stage=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
installer_path="$stage/install-mirror-prerequisites.sh"

lock_record_is_live() {
  lock_record=$1
  case "$lock_record" in
    *' '*) ;;
    *) return 1 ;;
  esac
  lock_pid=${lock_record%% *}
  lock_script=${lock_record#* }
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$lock_script" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$lock_script" in
    *[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null &&
    test -r "/proc/$lock_pid/cmdline" &&
    tr '\000' '\n' < "/proc/$lock_pid/cmdline" | grep -Fqx "$lock_script"
}

release_lock() {
  recorded_owner_pid=
  if test -f "$lock_directory/owner" && test ! -L "$lock_directory/owner"; then
    recorded_owner=$(cat "$lock_directory/owner" 2>/dev/null || true)
    recorded_owner_pid=${recorded_owner%% *}
  fi
  if test "$lock_acquired" = true &&
      test "$recorded_owner_pid" = "$$"; then
    rm -f "$lock_directory/owner" || true
    rmdir "$lock_directory" || true
  fi
  rm -f "$claim_path" || true
}

report_failure() {
  status=$?
  trap - EXIT HUP INT TERM
  release_lock
  if test "$status" -ne 0; then
    printf '%s\n' "RMMIRROR_PREREQUISITES_INSTALL_FAILED=$failure_phase" >&2
  fi
  exit "$status"
}
trap report_failure EXIT
trap 'exit 130' HUP INT TERM

failure_phase=acquiring_lock
umask 077
rm -f "$claim_path"
printf '%s %s\n' "$$" "$installer_path" > "$claim_path"
if ! mkdir "$lock_directory" 2>/dev/null; then
  if test -L "$lock_directory" || ! test -d "$lock_directory"; then
    printf '%s\n' 'rmmirror-prerequisite: install_lock_unsafe' >&2
    exit 46
  fi
  lock_record=
  if test -f "$lock_directory/owner" && test ! -L "$lock_directory/owner"; then
    lock_record=$(cat "$lock_directory/owner" 2>/dev/null || true)
  fi
  if ! lock_record_is_live "$lock_record"; then
      other_live_claim=false
      for pending_claim in /run/rmmirror-prerequisites-install.claim.*; do
        test "$pending_claim" != "$claim_path" || continue
        test -f "$pending_claim" || continue
        test ! -L "$pending_claim" || continue
        pending_record=$(cat "$pending_claim" 2>/dev/null || true)
        if lock_record_is_live "$pending_record"; then
          other_live_claim=true
          break
        fi
        rm -f "$pending_claim"
      done
      if test "$other_live_claim" = true; then
        printf '%s\n' 'rmmirror-prerequisite: install_already_running' >&2
        exit 46
      fi
  else
    printf '%s\n' 'rmmirror-prerequisite: install_already_running' >&2
    exit 46
  fi
  rm -f "$lock_directory/owner"
  rmdir "$lock_directory"
  mkdir "$lock_directory"
fi
mv "$claim_path" "$lock_directory/owner"
lock_acquired=true

is_sha256() {
  test "${#1}" -eq 64 &&
    LC_ALL=C printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

require_hash() {
  asset_name=$1
  expected_hash=$2
  test -f "$stage/$asset_name"
  test ! -L "$stage/$asset_name"
  is_sha256 "$expected_hash"
  actual_hash=$(sha256sum "$stage/$asset_name" | cut -d' ' -f1)
  test "$actual_hash" = "$expected_hash"
}

failure_phase=validating_contract
require_hash rmmirror-prerequisites.env "${RMMIRROR_CONTRACT_SHA256:-}"
test "$(wc -l < "$stage/rmmirror-prerequisites.env")" -eq 11
if LC_ALL=C grep -Ev '^[A-Z0-9_]+=[A-Za-z0-9.,/+_-]+$' \
    "$stage/rmmirror-prerequisites.env" | grep -q .; then
  exit 1
fi
. "$stage/rmmirror-prerequisites.env"
test "${RMMIRROR_PREREQUISITES_SCHEMA:-}" = 'rmmirror.prerequisites/v1'
test "${RMMIRROR_TABLET_MODEL:-}" = 'chiappa'
test "${RMMIRROR_TABLET_IMG_VERSION:-}" = '3.28.0.164'
test "${RMMIRROR_TABLET_OS_BUILD:-}" = '5.8.199'
test "${RMMIRROR_XOVI_RELEASE:-}" = 'v19-23052026'
test "${RMMIRROR_XOVI_ARCHIVE_SHA256:-}" = '32d64d1262ddc984e3235c7d0340a398fe6d5b3efa6a979865f5977b32630d27'
test "${RMMIRROR_PROBE_VERSION:-}" = '0.4.9'
test "${RMMIRROR_TRANSPORT_VERSION:-}" = '0.6.0'
test "${RMMIRROR_TRANSPORT_SCHEMA:-}" = 'rmmirror.transport-wake/v1'
test "${RMMIRROR_USB_CONNECTION_POLICY:-}" = 'carrier-qualified-power-hold/v1'
test "${RMMIRROR_REQUIRED_EXTENSIONS:-}" = \
  'framebuffer-spy.so,xovi-message-broker.so,rmmirror-files-loopback.so'

failure_phase=validating_stage
test -d "$stage"
test ! -L "$stage"
require_hash rmmirror-transport-wake "${RMMIRROR_TRANSPORT_WAKE_SHA256:-}"
require_hash rmmirror-transport-wake.service "${RMMIRROR_TRANSPORT_SERVICE_SHA256:-}"
require_hash install-transport-wake.sh "${RMMIRROR_TRANSPORT_INSTALLER_SHA256:-}"
require_hash rmmirror-usb-sleep-guard.conf "${RMMIRROR_SLEEP_GUARD_SHA256:-}"
require_hash rmmirror-probe "${RMMIRROR_PROBE_SHA256:-}"
require_hash xovi-aarch64.tar.gz "${RMMIRROR_XOVI_ARCHIVE_SHA256}"
require_hash rmmirror-files-loopback.so "${RMMIRROR_FILES_LOOPBACK_SHA256:-}"

stage_cleanup_now=$(date +%s)
case "$stage_cleanup_now" in
  ''|*[!0-9]*) stage_cleanup_now=0 ;;
esac
if test "${#stage_cleanup_now}" -le 12 && test "$stage_cleanup_now" -ge 3600; then
  stage_cleanup_cutoff=$((stage_cleanup_now - 3600))
  for abandoned_stage in \
    /home/root/.rmmirror-prerequisite-stage-* \
    /home/root/.rmmirror-transport-stage-*
  do
    if test "$abandoned_stage" = "$stage" ||
        ! test -d "$abandoned_stage" || test -L "$abandoned_stage"; then
      continue
    fi
    abandoned_name=${abandoned_stage##*/}
    abandoned_token=${abandoned_name##*-stage-}
    if test "${#abandoned_token}" -ne 32 ||
        ! LC_ALL=C printf '%s\n' "$abandoned_token" | grep -Eq '^[0-9a-f]{32}$'; then
      continue
    fi
    stage_lease="$abandoned_stage/.rmmirror-stage-created"
    if ! test -f "$stage_lease" || test -L "$stage_lease"; then
      continue
    fi
    stage_created=$(cat "$stage_lease" 2>/dev/null || true)
    case "$stage_created" in
      ''|*[!0-9]*) continue ;;
    esac
    if test "${#stage_created}" -le 12 &&
        test "$stage_created" -le "$stage_cleanup_cutoff"; then
      rm -rf "$abandoned_stage"
    fi
  done
fi

failure_phase=validating_tablet
tablet_model=$(tr -d '\000' < /sys/firmware/devicetree/base/model)
tablet_img_version=$(sed -n 's/^IMG_VERSION=//p' /etc/os-release | head -n 1 | tr -d '"')
tablet_os_build=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
test "$tablet_model" = 'reMarkable Chiappa'
test "$tablet_img_version" = "$RMMIRROR_TABLET_IMG_VERSION"
test "$tablet_os_build" = "$RMMIRROR_TABLET_OS_BUILD"
test -c /dev/uinput
test -c /dev/input/event2
test "$(cat /sys/class/input/event2/device/name)" = 'Elan marker input'

install_target_incompatible() {
  printf '%s\n' 'rmmirror-prerequisite: install_target_incompatible' >&2
  exit 47
}
for directory in /home/root/.local /home/root/.local/bin; do
  if test -L "$directory" ||
      { test -e "$directory" && ! test -d "$directory"; }; then
    install_target_incompatible
  fi
done
if test -L /home/root/.local/bin/rmmirror-probe ||
    { test -e /home/root/.local/bin/rmmirror-probe &&
      ! test -f /home/root/.local/bin/rmmirror-probe; }; then
  install_target_incompatible
fi

failure_phase=installing_xovi
xovi_incompatible() {
  printf '%s\n' 'rmmirror-prerequisite: xovi_incompatible' >&2
  exit 45
}

require_installed_xovi_file() {
  installed_path=$1
  test -f "$installed_path" || xovi_incompatible
  test ! -L "$installed_path" || xovi_incompatible
}

require_installed_xovi_executable() {
  require_installed_xovi_file "$1"
  test -x "$1" || xovi_incompatible
}

mkdir "$stage/xovi-unpack"
tar -xzf "$stage/xovi-aarch64.tar.gz" -C "$stage/xovi-unpack"
pinned_xovi="$stage/xovi-unpack/xovi"
test -d "$pinned_xovi"
test ! -L "$pinned_xovi"
test -x "$pinned_xovi/start"
test ! -L "$pinned_xovi/start"
test -x "$pinned_xovi/stock"
test ! -L "$pinned_xovi/stock"
test -f "$pinned_xovi/xovi.so"
test ! -L "$pinned_xovi/xovi.so"
test -f "$pinned_xovi/inactive-extensions/framebuffer-spy.so"
test ! -L "$pinned_xovi/inactive-extensions/framebuffer-spy.so"
test -f "$pinned_xovi/inactive-extensions/xovi-message-broker.so"
test ! -L "$pinned_xovi/inactive-extensions/xovi-message-broker.so"

if test -L /home/root/xovi; then
  xovi_incompatible
elif test ! -e /home/root/xovi; then
  printf '%s\n' "$RMMIRROR_XOVI_RELEASE" > "$pinned_xovi/.rmmirror-version"
  mv "$pinned_xovi" /home/root/xovi
else
  test -d /home/root/xovi || xovi_incompatible
  if ! test -f /home/root/xovi/.rmmirror-version ||
      test -L /home/root/xovi/.rmmirror-version ||
      ! test "$(cat /home/root/xovi/.rmmirror-version)" = "$RMMIRROR_XOVI_RELEASE"; then
    printf '%s\n' 'rmmirror-prerequisite: xovi_version_mismatch' >&2
    exit 44
  fi
  for asset in \
    xovi.so \
    start \
    stock \
    inactive-extensions/framebuffer-spy.so \
    inactive-extensions/xovi-message-broker.so
  do
    require_installed_xovi_file "/home/root/xovi/$asset"
    if ! cmp -s "$pinned_xovi/$asset" "/home/root/xovi/$asset"; then
      printf '%s\n' "rmmirror-prerequisite: xovi_asset_mismatch:$asset" >&2
      exit 45
    fi
  done
fi

failure_phase=publishing_extensions
for directory in \
  /home/root/xovi/extensions.d \
  /home/root/xovi/inactive-extensions \
  /home/root/xovi/services \
  /home/root/xovi/services/xochitl.service
do
  if test -L "$directory" ||
      { test -e "$directory" && ! test -d "$directory"; }; then
    xovi_incompatible
  fi
done
for existing_target in \
  /home/root/xovi/extensions.d/framebuffer-spy.so \
  /home/root/xovi/extensions.d/xovi-message-broker.so \
  /home/root/xovi/extensions.d/rmmirror-files-loopback.so \
  /home/root/xovi/extensions.d/qt-resource-rebuilder.so \
  /home/root/xovi/extensions.d/webserver-remote.so \
  /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so \
  /home/root/xovi/inactive-extensions/qt-resource-rebuilder.so \
  /home/root/xovi/inactive-extensions/webserver-remote.so \
  /home/root/xovi/services/xochitl.service/qt-resource-rebuilder.conf \
  /home/root/xovi/services/xochitl.service/99-rmmirror-activation-guard.conf \
  /home/root/xovi/services/xochitl.service/zz-rmmirror-activation-guard.conf
do
  if test -e "$existing_target" || test -L "$existing_target"; then
    require_installed_xovi_file "$existing_target"
  fi
done
for retired_extension in qt-resource-rebuilder.so webserver-remote.so; do
  active_path="/home/root/xovi/extensions.d/$retired_extension"
  inactive_path="/home/root/xovi/inactive-extensions/$retired_extension"
  if test -f "$active_path" && test -f "$inactive_path"; then
    cmp -s "$active_path" "$inactive_path" || xovi_incompatible
  fi
done
for extension_path in /home/root/xovi/extensions.d/*.so; do
  if ! test -e "$extension_path" && ! test -L "$extension_path"; then
    continue
  fi
  extension_name=${extension_path##*/}
  case "$extension_name" in
    framebuffer-spy.so|xovi-message-broker.so|rmmirror-files-loopback.so|qt-resource-rebuilder.so|webserver-remote.so)
      ;;
    *)
      xovi_incompatible
      ;;
  esac
done

chmod 0644 /home/root/xovi/xovi.so
chmod 0755 /home/root/xovi/start /home/root/xovi/stock
require_installed_xovi_executable /home/root/xovi/start
require_installed_xovi_executable /home/root/xovi/stock
require_installed_xovi_file /home/root/xovi/inactive-extensions/framebuffer-spy.so
require_installed_xovi_file /home/root/xovi/inactive-extensions/xovi-message-broker.so
for directory in \
  /home/root/xovi/extensions.d \
  /home/root/xovi/inactive-extensions \
  /home/root/xovi/services \
  /home/root/xovi/services/xochitl.service
do
  if ! test -e "$directory"; then
    mkdir "$directory"
  fi
done

for retired_extension in qt-resource-rebuilder.so webserver-remote.so; do
  active_path="/home/root/xovi/extensions.d/$retired_extension"
  inactive_path="/home/root/xovi/inactive-extensions/$retired_extension"
  if test -e "$active_path" || test -L "$active_path"; then
    require_installed_xovi_file "$active_path"
    if test -e "$inactive_path" || test -L "$inactive_path"; then
      require_installed_xovi_file "$inactive_path"
      cmp -s "$active_path" "$inactive_path" || xovi_incompatible
      rm -f "$active_path"
    else
      mv -f "$active_path" "$inactive_path"
    fi
  fi
done
rm -f \
  /home/root/xovi/services/xochitl.service/qt-resource-rebuilder.conf \
  /home/root/xovi/services/xochitl.service/99-rmmirror-activation-guard.conf \
  /home/root/xovi/services/xochitl.service/zz-rmmirror-activation-guard.conf

rm -f /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new
cp "$stage/rmmirror-files-loopback.so" \
  /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new
chmod 0755 /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new
if test -e /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so ||
    test -L /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so; then
  require_installed_xovi_file \
    /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so
fi
mv -f \
  /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new \
  /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so

publish_extension() {
  extension_name=$1
  source_path="/home/root/xovi/inactive-extensions/$extension_name"
  target_path="/home/root/xovi/extensions.d/$extension_name"
  require_installed_xovi_file "$source_path"
  if test -f "$target_path" && test ! -L "$target_path" &&
      cmp -s "$source_path" "$target_path"; then
    chmod 0755 "$target_path"
    return 0
  fi
  if test -e "$target_path" || test -L "$target_path"; then
    require_installed_xovi_file "$target_path"
  fi
  rm -f "$target_path.new"
  cp "$source_path" "$target_path.new"
  chmod 0755 "$target_path.new"
  mv -f "$target_path.new" "$target_path"
}
publish_extension framebuffer-spy.so
publish_extension xovi-message-broker.so
publish_extension rmmirror-files-loopback.so
for extension_name in \
  framebuffer-spy.so \
  xovi-message-broker.so \
  rmmirror-files-loopback.so
do
  source_path="/home/root/xovi/inactive-extensions/$extension_name"
  target_path="/home/root/xovi/extensions.d/$extension_name"
  test -f "$target_path"
  test ! -L "$target_path"
  test -x "$target_path"
  cmp -s "$source_path" "$target_path"
done
for extension_path in /home/root/xovi/extensions.d/*.so; do
  if ! test -e "$extension_path" && ! test -L "$extension_path"; then
    continue
  fi
  extension_name=${extension_path##*/}
  case "$extension_name" in
    framebuffer-spy.so|xovi-message-broker.so|rmmirror-files-loopback.so)
      ;;
    *)
      xovi_incompatible
      ;;
  esac
done
cmp -s "$stage/rmmirror-files-loopback.so" \
  /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so

failure_phase=installing_probe
for directory in /home/root/.local /home/root/.local/bin; do
  if test -e "$directory"; then
    test -d "$directory"
    test ! -L "$directory"
  else
    mkdir "$directory"
  fi
done
rm -f /home/root/.local/bin/rmmirror-probe.new
cp "$stage/rmmirror-probe" /home/root/.local/bin/rmmirror-probe.new
chmod 0700 /home/root/.local/bin/rmmirror-probe.new
if test -e /home/root/.local/bin/rmmirror-probe ||
    test -L /home/root/.local/bin/rmmirror-probe; then
  test -f /home/root/.local/bin/rmmirror-probe
  test ! -L /home/root/.local/bin/rmmirror-probe
fi
mv -f /home/root/.local/bin/rmmirror-probe.new \
  /home/root/.local/bin/rmmirror-probe
test -f /home/root/.local/bin/rmmirror-probe
test ! -L /home/root/.local/bin/rmmirror-probe
test -x /home/root/.local/bin/rmmirror-probe
test "$(sha256sum /home/root/.local/bin/rmmirror-probe | cut -d' ' -f1)" = \
  "$RMMIRROR_PROBE_SHA256"
test "$(/home/root/.local/bin/rmmirror-probe version)" = \
  "$RMMIRROR_PROBE_VERSION"

failure_phase=retiring_frame_streams
frame_stream_probe_path=/home/root/.local/bin/rmmirror-probe
is_exact_frame_stream_process() {
  frame_stream_proc_dir=$1
  test -r "$frame_stream_proc_dir/cmdline" || return 1
  frame_stream_executable=$(readlink "$frame_stream_proc_dir/exe" 2>/dev/null || true)
  if test "$frame_stream_executable" != "$frame_stream_probe_path" &&
      test "$frame_stream_executable" != "$frame_stream_probe_path (deleted)"; then
    return 1
  fi
  frame_stream_arguments=$(tr '\000' '\n' < "$frame_stream_proc_dir/cmdline" 2>/dev/null) || return 1
  frame_stream_argv0=$(printf '%s\n' "$frame_stream_arguments" | sed -n '1p')
  frame_stream_argv1=$(printf '%s\n' "$frame_stream_arguments" | sed -n '2p')
  test "$frame_stream_argv0" = "$frame_stream_probe_path" &&
    test "$frame_stream_argv1" = stream
}

list_exact_frame_stream_pids() {
  for frame_stream_proc_dir in /proc/[0-9]*; do
    if is_exact_frame_stream_process "$frame_stream_proc_dir"; then
      printf '%s\n' "${frame_stream_proc_dir##*/}"
    fi
  done
}

wait_for_frame_stream_retirement() {
  frame_stream_attempt=0
  while test "$frame_stream_attempt" -lt 20; do
    frame_stream_pids=$(list_exact_frame_stream_pids)
    test -z "$frame_stream_pids" && return 0
    sleep 0.1
    frame_stream_attempt=$((frame_stream_attempt + 1))
  done
  test -z "$(list_exact_frame_stream_pids)"
}

retire_frame_streams() {
  frame_stream_pids=$(list_exact_frame_stream_pids)
  if test -n "$frame_stream_pids"; then
    kill -TERM $frame_stream_pids 2>/dev/null || true
  fi
  wait_for_frame_stream_retirement && return 0
  frame_stream_pids=$(list_exact_frame_stream_pids)
  if test -n "$frame_stream_pids"; then
    kill -KILL $frame_stream_pids 2>/dev/null || true
  fi
  wait_for_frame_stream_retirement && return 0
  printf '%s\n' 'rmmirror-prerequisite: frame_stream_retirement_failed' >&2
  return 1
}
retire_frame_streams

failure_phase=installing_transport
chmod 0700 "$stage/install-transport-wake.sh"
"$stage/install-transport-wake.sh" install >/dev/null

failure_phase=validating_install
test -f /usr/libexec/rmmirror-transport-wake
test ! -L /usr/libexec/rmmirror-transport-wake
test -x /usr/libexec/rmmirror-transport-wake
test "$(sha256sum /usr/libexec/rmmirror-transport-wake | cut -d' ' -f1)" = \
  "$RMMIRROR_TRANSPORT_WAKE_SHA256"
test -f /usr/lib/systemd/system/rmmirror-transport-wake.service
test ! -L /usr/lib/systemd/system/rmmirror-transport-wake.service
test "$(sha256sum /usr/lib/systemd/system/rmmirror-transport-wake.service | cut -d' ' -f1)" = \
  "$RMMIRROR_TRANSPORT_SERVICE_SHA256"
test -f /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf
test ! -L /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf
test "$(sha256sum /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf | cut -d' ' -f1)" = \
  "$RMMIRROR_SLEEP_GUARD_SHA256"
systemctl is-active --quiet rmmirror-transport-wake.service
test -L /usr/lib/systemd/system/multi-user.target.wants/rmmirror-transport-wake.service
test "$(readlink /usr/lib/systemd/system/multi-user.target.wants/rmmirror-transport-wake.service)" = \
  '../rmmirror-transport-wake.service'
test "$(systemctl is-enabled rmmirror-transport-wake.service)" = 'static'
multi_user_wants=$(systemctl show --property=Wants --value -- multi-user.target)
case " $multi_user_wants " in
  *" rmmirror-transport-wake.service "*) ;;
  *) exit 1 ;;
esac
loaded_guard=$(systemctl show --property=DropInPaths --value -- \
  systemd-suspend-then-hibernate.service)
case " $loaded_guard " in
  *" /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf "*) ;;
  *) exit 1 ;;
esac

failure_phase=validating_transport_status
test "$(/usr/libexec/rmmirror-transport-wake --version)" = \
  "$RMMIRROR_TRANSPORT_VERSION"
grep -q "\"schema\":\"$RMMIRROR_TRANSPORT_SCHEMA\"" /run/rmmirror-transport-wake.json
grep -q "\"usb_connection_policy\":\"$RMMIRROR_USB_CONNECTION_POLICY\"" \
  /run/rmmirror-transport-wake.json
grep -q '"power_known":true' /run/rmmirror-transport-wake.json
grep -q '"connection_known":true' /run/rmmirror-transport-wake.json
grep -q '"usb_connected":true' /run/rmmirror-transport-wake.json
grep -q '"usb_data_qualified":true' /run/rmmirror-transport-wake.json
grep -q '"state":"holding"' /run/rmmirror-transport-wake.json
grep -q '"wake_lock_active":true' /run/rmmirror-transport-wake.json
grep -q '"system_sleep_blocked":true' /run/rmmirror-transport-wake.json
grep -q '"wake_endpoint_healthy":true' /run/rmmirror-transport-wake.json
if grep -q '"error":' /run/rmmirror-transport-wake.json; then
  exit 1
fi

failure_phase=validating_listeners
listener_addresses=$(netstat -lnt 2>/dev/null | awk '$4 ~ /:51337$/ { print $4 }')
test "$(printf '%s\n' "$listener_addresses" | grep -c '^127[.]0[.]0[.]1:51337$')" -eq 1
test "$(printf '%s\n' "$listener_addresses" | grep -c '^10[.]11[.]99[.]1:51337$')" -eq 1
test "$(printf '%s\n' "$listener_addresses" | grep -c ':51337$')" -eq 2
case ",$(awk '$2 == "/" { print $4; exit }' /proc/mounts)," in
  *,ro,*) ;;
  *) exit 1 ;;
esac

failure_phase=complete
trap - EXIT HUP INT TERM
release_lock
printf '%s\n' 'RMMIRROR_PREREQUISITES=installed'
