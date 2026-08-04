# Tablet deployment assets

These assets install the small tablet-side runtime used by reMarkable Mirror.
They do not install persistent virtual input.

## Session-only input

After Windows establishes SSH, it starts:

```sh
/home/root/.local/bin/rmmirror-probe input --heartbeat-timeout 15s
```

That SSH process creates temporary input devices, performs the Xochitl handoff,
relays the physical marker, and restores stock physical input at EOF. A detached
watchdog performs the same restoration if the helper exits unexpectedly. See
[`../INPUT_PROTOCOL.md`](../INPUT_PROTOCOL.md) for the protocol and lifecycle.

The deployment must not create an input service, Xochitl drop-in, udev rule,
socket, or boot dependency. These legacy assets are intentionally absent and
must not be recreated:

- `rmmirror-input.service`
- `10-rmmirror-input.conf`
- `99-rmmirror-pen.rules`
- `set-input-mode.sh`
- `verify-input-ready.sh`

In particular, Xochitl must never depend on Mirror input during boot or first
unlock.

## USB transport and wake service

The transport policy uses three product assets:

- `rmmirror-transport-wake.service`
- `install-transport-wake.sh`
- `rmmirror-usb-sleep-guard.conf`

The noncritical root-slot service renews a timed kernel wake lock while the USB
network carrier is present. It does not mask sleep targets. The guard is an
`ExecCondition` drop-in only for
`systemd-suspend-then-hibernate.service`; it holds that executor while USB
carrier is exactly `1`.

Xochitl waits synchronously for the systemd transaction and has a 60-second
watchdog. While the sleep executor is held, the guard renews that watchdog every
20 seconds. Each renewal is bounded to five seconds and pins the same
active/running `MainPID` and `InvocationID` before and after notification. USB
detach or an unreadable carrier fails open to stock sleep. Cancellation skips
the executor, while a watchdog or identity failure blocks the uncertain action.
The service has no `/home`, Mirror-input, or personal-content dependency.

## Wake endpoint boundary

The same service exposes a bearer-authenticated HTTP API on TCP 51337:

- `GET /v1/status` returns schema `rmmirror.wake/v1` with
  `unlock_required`, `sleeping`, `starting`, or `ready`;
- `POST /v1/wake` may send one atomic `KEY_POWER` click only when a current,
  authoritative source proves Xochitl is in `DeepSleep`; and
- the root-owned mode-`0600` token lives at `/data/rmmirror/wake-token` and is
  never written to logs.

The endpoint opens an all-or-nothing listener pair on `127.0.0.1:51337` and
`10.11.99.1:51337`. If either bind fails, the other listener is closed and
endpoint health remains false. It must never bind `0.0.0.0` or the tablet's
Wi-Fi address. The Windows pre-SSH client pins its connection to the direct USB
adapter. The loopback listener is used for local installation checks and can be
reached remotely only through an authenticated SSH forward. The endpoint uses
plain HTTP because neither allowed listener is exposed directly to the LAN.

This endpoint exists before `/home` and Dropbear. `unlock_required` proves only
that encrypted `/home` is unavailable and the tablet needs its passcode; it does
not identify the cause or bypass the passcode. A normal screen lock with SSH
available remains a valid Mirror state. If the status source cannot
authoritatively prove `DeepSleep`, no power event is sent.

## Installation and recovery

The installer expects the ARM64 `rmmirror-transport-wake` binary beside the
service and install script. Direct tablet use is:

```sh
./install-transport-wake.sh install
./install-transport-wake.sh remove
```

Installation affects only the currently active A/B root slot. After an OTA or
slot switch, connect by USB, complete the first post-boot unlock, and rerun
`Install.cmd`. Automatic installation on a newly active root slot is not
implemented.

Install, rollback, and removal are transactional. The script snapshots the
prior files and enablement, acquires a distinct timed kernel wake lock, and
stops pending `suspend-then-hibernate` work before mutation. It verifies the
published asset hashes, loaded drop-in, service health, endpoint health, and
read-only active root before success. A failed install restores the prior files
and service state. Removal preserves `/data/rmmirror/wake-token` so reinstalling
does not silently invalidate the paired Windows host.

The host-side entry point is
`scripts/Install-RemarkableMirrorPrerequisites.ps1`. It stages and verifies the
release components, installs the service, retrieves the wake token over the
direct USB SSH connection, and stores that token for the current Windows user
without printing it. For Wi-Fi Mirror it also runs `rm-ssh-over-wlan on`, checks
the root `dropbear-wlan.socket`, and confirms that Wi-Fi reaches the same tablet
identity first saved over USB. This enables root SSH on the tablet's Wi-Fi
interface. The dedicated SSH key is passphrase-free because every product
connection uses `BatchMode=yes`; protect it as a root credential and use Wi-Fi
Mirror only on a private network you control.

## Packaged tablet components

The prerequisite set contains:

- `rmmirror-probe` for capture, capability checks, and session input;
- `rmmirror-transport-wake` and the USB sleep guard;
- the `rmmirror-files-loopback` Xovi extension;
- the pinned Xovi runtime; and
- selected upstream `framebuffer-spy` and `xovi-message-broker` extensions.

The exact versions and SHA-256 values belong in each package's `release.json`.
They are generated from the current build inputs rather than copied from another
package. Xovi is installed under `/home/root/xovi` but has no
boot hook; Mirror starts it only while preparing a connection.

The connection order is: cancel pending sleep work, wait for previous physical
input restoration, prepare Xovi display capture, perform one session input
handoff, revalidate the display after the deliberate Xochitl restart, and then
stream. Every Mirror-owned Xochitl start or restart first resets only
`xochitl.service`'s failed and rate-limit state. If that reset fails, the action
is blocked. Startup and graceful cleanup are bounded, and repeated failures end
at an explicit `Retry` instead of another hidden handoff.

## Current support boundary

The current source supports USB and Wi-Fi display, `Touch + Type`, Pen,
short-sleep recovery, Files through SSH, Files recovery after unlock, and normal
sleep after USB detach. Pen over Wi-Fi is owner-tested in installed Gold
`1.2608.416.5801`. Full-suspend wireless wake, automatic A/B slot repair, and
recovery from every live connection failure remain separate work.
