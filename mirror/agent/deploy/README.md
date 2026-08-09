# Tablet deployment assets

These assets install the small tablet-side runtime used by reMarkable Mirror.
They do not install persistent virtual input.

## Frame-session lease

The Windows frame worker starts:

```sh
/home/root/.local/bin/rmmirror-probe stream --interval 40ms --heartbeat-timeout 15s
```

Windows writes one pulse to that SSH session immediately and another every
three seconds. Probe v0.4.9 monitors the lease independently from frame
capture. If no pulse arrives for 15 seconds, it reports
`stream_heartbeat_timeout` and returns to process exit without joining a frame
writer that may be blocked on a dead connection. Standard-input EOF and parent
cancellation remain clean exits. A zero timeout keeps the unleased command-line
behavior, but the Windows product always supplies 15 seconds.

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

The noncritical root-slot service qualifies a Mirror data attachment when
carrier is `1` or exactly one discovered USB device controller reports
`configured`. Once qualified, MAX77818 charger power keeps the timed kernel wake
lock through transient loss of both data signals; power loss clears the
qualification. Power alone never qualifies a charge-only source, and unknown
state fails open to normal sleep. It does not mask sleep targets.

The power signal is
`/sys/class/power_supply/max77818-charger/online`. reMarkable's published
Chiappa kernel source wires the USB-C controller to that MAX77818 power supply,
whose `online` property reads the hardware charger-input-present state. This
fallback has source and unit-test evidence; it has not yet been proved through
a physical data-signal-loss cycle on the tablet.

Runtime status keeps the existing `rmmirror.transport-wake/v1` schema and the
`0.6.0` binary version for older-host compatibility. It additively publishes
`usb_connection_policy` as the historical compatibility label
`carrier-qualified-power-hold/v1`. Current behavior also includes UDC
qualification; the label must not be read as the complete policy. A future
cross-platform release can rename it only when Mac and Windows consumers move
together.

The guard is an `ExecCondition` drop-in only for
`systemd-suspend-then-hibernate.service`. Each guard invocation uses the same
carrier-or-exactly-one-configured-UDC qualification before charger power may
extend its hold.

Xochitl waits synchronously for the systemd transaction and has a 60-second
watchdog. While the sleep executor is held, the guard renews that watchdog every
20 seconds. Each renewal is bounded to five seconds and pins the same
active/running `MainPID` and `InvocationID` before and after notification. USB
power loss releases the hold. Before qualification, or whenever the connection
state cannot be proved, the policy fails open to stock sleep. Cancellation
skips the executor, while a watchdog or identity failure blocks the uncertain
action. The service has no `/home`, Mirror-input, or personal-content
dependency.

## Wake endpoint boundary

The same service exposes an HTTP API on TCP 51337. Normal access remains
bearer-authenticated:

- `GET /v1/status` returns schema `rmmirror.wake/v1` with
  `unlock_required`, `sleeping`, `starting`, or `ready`;
- `POST /v1/wake` may send one atomic `KEY_POWER` click only when a current,
  authoritative source proves Xochitl is in `DeepSleep`; and
- the root-owned mode-`0600` token lives at `/data/rmmirror/wake-token` and is
  never written to logs.

The endpoint opens an all-or-nothing listener pair on `127.0.0.1:51337` and
`10.11.99.1:51337`. On Linux, the direct-cable socket is additionally bound to
`usb0` with `SO_BINDTODEVICE`; if that binding or either listener fails, the
other listener is closed and endpoint health remains false. It must never bind
`0.0.0.0` or the tablet's Wi-Fi address. The Windows pre-SSH client pins its
connection to the direct USB adapter. The loopback listener is used for local
installation checks and can be reached remotely only through an authenticated
SSH forward. The endpoint uses plain HTTP because neither allowed listener is
exposed directly to the LAN.

The direct USB-C listener authorizes bounded cable status and wake without a
bearer. It accepts only `GET /v1/status` and `POST /v1/wake`, only on the
`usb0`-bound socket, and only when the server-observed local address is exactly
`10.11.99.1:51337` and the peer is a safe host inside the fixed
`10.11.99.0/27` cable range. Loopback always requires the bearer. A present but
invalid authorization value is rejected instead of falling back. This cable
capability can inspect bounded display state and request the same
authoritatively gated single power click; it cannot unlock the tablet, read a
credential or reach any content API.

This endpoint exists before `/home` and Dropbear. `unlock_required` proves only
that encrypted `/home` is unavailable and the tablet needs its passcode; it does
not identify the cause or bypass the passcode. A normal screen lock with SSH
available remains a valid Mirror state. If the status source cannot
authoritatively prove `DeepSleep`, no power event is sent.

The authoritative `DeepSleep` source combines Xochitl's latest transition from
its current systemd invocation with the current systemd-owned sleep hold. The
inspector requires the stock
`systemd-suspend-then-hibernate.service` to be running its `condition` phase,
verifies through `/proc` that its live control PID is the packaged
`rmmirror-transport-wake` executable running `hold-system-sleep`, and then
revalidates the same PID, sleep-unit invocation, and Xochitl invocation before
allowing one power click. A journal transition without that live hold remains
non-authoritative status diagnostics.

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

The unit is static: it has no `[Install]` section. The
installer publishes an exact package-owned
`/usr/lib/systemd/system/multi-user.target.wants/rmmirror-transport-wake.service`
link instead of relying on `systemctl enable` under the tablet's volatile
`/etc`. It reloads systemd and verifies that `multi-user.target` consumed the
dependency.

Install, rollback, and removal are transactional. The script snapshots the
prior files and enablement, acquires a distinct timed kernel wake lock, and
stops pending `suspend-then-hibernate` work before mutation. It verifies the
published asset hashes, loaded drop-in, service health, endpoint health, and
restored pre-install root-mount state before success. A failed install restores the prior files
and service state, including the exact prior package-owned boot link. Candidate
health always requires the current USB connection-policy marker; rollback also
accepts the marker-free carrier-only `0.6.0` health contract when that is the
service it restored. Removal validates that link before its first mutation and
preserves `/data/rmmirror/wake-token` so reinstalling does not silently
invalidate the paired Windows host.

The host-side entry point is
`scripts/Install-RemarkableMirrorPrerequisites.ps1`. It stages and verifies the
release components, installs the service, retrieves the wake token over the
direct USB SSH connection, and stores that token for the current Windows user
without printing it. For Wi-Fi Mirror it also runs `rm-ssh-over-wlan on`, checks
the root `dropbear-wlan.socket`, and confirms that Wi-Fi reaches the same tablet
identity first saved over USB. This enables root SSH on the tablet's Wi-Fi
interface. The dedicated SSH key is passphrase-free because every product
connection uses `BatchMode=yes`; protect it as a root credential. Use Wi-Fi
Mirror on your home Wi-Fi, not on public or guest Wi-Fi. If you do not control
who can join the network, use USB-C instead.

The Windows capture helper starts external tools under a gated Job Object. It
writes the serialized launcher payload over standard input after job assignment
and gate release instead of embedding that payload in `-EncodedCommand`. This
keeps the launcher command fixed-size for long remote setup scripts and avoids
the Windows command-length limit. A payload-transfer failure terminates and
verifies the owned process tree.

When the package upgrades the probe, the installer publishes and verifies the
new binary before retiring an old frame generation. It matches only the exact
`/home/root/.local/bin/rmmirror-probe` executable, including its deleted inode
after replacement, with `stream` as its next argument. It sends TERM, waits up
to two seconds, sends KILL only to surviving matches, and performs another
bounded absence check. Input and its detached watchdog do not match. Setup stops
with `frame_stream_retirement_failed` if absence cannot be verified.

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
sleep after USB detach. On the tested tablet, the Windows product did not wake
full Linux suspend with its direct-network request or standard wake packet. If
Linux has already suspended, press the tablet's physical power button once,
unlock it, then explicitly choose **Connect USB-C** or **Connect Wi-Fi** again.
Mirror does not reopen or move the retired route by itself.

The Mac contract is separate. Launch and cable appearance do not communicate
with the tablet. One explicit **Connect USB-C** click owns a bounded direct-cable
wake, service-recovery, authentication, and connection session. That session
never selects or falls back to Wi-Fi. Entering the tablet passcode is the only
owner intervention authorized USB use may require. The connection card places
**Connect via Wi‑Fi** directly below **Connect USB-C**. Choosing the Wi-Fi action
first opens a local prompt for the tablet’s IPv4 address and says the tablet must
be awake but may stay locked. Submitting starts one Wi-Fi-only attempt to that
address, bound to the current Wi-Fi context and authenticated with the saved
pinned SSH identity. It may recheck a transiently offline route every three
seconds during a 45-second retry window; a bounded check admitted before expiry
may finish afterward. It does not auto-discover or persist an address, inspect
or use USB, wake the tablet, fall back to another transport, use the wake HTTP
endpoint, request a password, or require an unlock. Failure returns to the two
manual connection choices. Files remains separate and may still require one.

Automatic A/B slot repair and recovery from every possible live connection
failure are not supported.
