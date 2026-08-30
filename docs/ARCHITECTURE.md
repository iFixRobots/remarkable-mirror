# Architecture

Mirror has native Windows and macOS desktop hosts. Both connect over
authenticated SSH to small ARM64 Linux components running on the reMarkable
tablet.

```text
Windows WinUI host                 macOS SwiftUI/AppKit host
          |                                  |
          +------- owner-selected route -----+
                             |
                    pinned OpenSSH identity
                             |
Tablet                       |
  +-- rmmirror-probe --------+-- frame stream and session input
  +-- Xovi ------------------+-- framebuffer and Files extensions
  +-- Files loopback --------+-- SSH-forwarded stock Files service
  +-- transport-wake --------+-- direct-USB/loopback status and wake
```

## Owner-started first-time setup

Both desktop hosts own first-time setup inside the native app. Their controls
and presentation are platform-native, but the state machine is the same:

```text
Start Setup
    |
verify direct USB-C
    |
prove existing authorization + inspect tablet prerequisites
    |
    +-- already complete --> refresh local profile --> manual chooser
    |
authorize dedicated key with one-time root password
    |
stage + run shared nine-asset tablet transaction
    |
enable and verify Wi-Fi SSH against pinned identity
    |
manual USB-C / Wi-Fi chooser
```

Construction and local readiness checks are network-inert. Each transition
that can contact or change the tablet is admitted by the owner's **Start
Setup**, **Authorize & Install**, **Continue Setup**, or repair action. Setup
completion does not create a connection generation.

Developer Mode, its factory reset, account sign-in, Wi-Fi password entry, the
first unlock, and USB accessory approval remain outside the app's authority.

The host adapters are deliberately small. Windows uses
`TabletSetupCoordinator`, `OpenSshSetupClient`, and the PowerShell prerequisite
adapter. macOS uses `TabletPairingFinalizer` and
`TabletPrerequisiteInstaller`. Both stage the exact payload declared by
`rmmirror-prerequisites.env` and invoke
`install-mirror-prerequisites.sh`; tablet mutation logic is not duplicated in
the native hosts.

## Owner-selected connection lifecycle

Launching a desktop app loads local state only. Cable and network changes do not
probe, wake, or connect to the tablet.

An owner action creates one bounded connection attempt:

- **Connect USB-C** checks only the direct cable;
- **Connect Wi-Fi** checks only the entered Wi-Fi route; and
- a successful attempt publishes one route generation.

That generation owns its frame, input, wake, SSH, and Files work. The host never
falls back to another route, promotes USB, or reconnects a retired session.
Cable, network, frame, or input failure retires the generation and returns to
manual choices.

On both hosts, clicking the Live USB status opens the existing Wi-Fi address
form without first retiring USB. Windows labels it **Live over USB**; macOS
labels it **Live over USB-C**. Canceling leaves USB Live; submitting a valid
address replaces the active generation with one Wi-Fi attempt. Clicking **Live
over Wi-Fi** starts the same bounded USB-C action used from the disconnected
screen. The status control does not implement its own probing path.

**Live** is stronger than authenticated SSH: a fresh frame and a running input
session must belong to the same current generation. Files readiness is
independent.

## Identity and route trust

First pairing happens over the direct Developer Mode USB network. The host pins
the tablet's Ed25519 SSH identity and creates a dedicated host key. Wi-Fi later
uses that same pinned tablet identity.

Pairing admits the exact `chiappa` hardware model without turning the observed
firmware into an SSH authorization policy. Passive recognition records the
firmware and active root, but readiness is decided by the installed probe,
transport, schema, endpoint, and Xovi capability contract. Firmware and root
remain part of route/profile identity so a changed observation is refreshed
rather than silently treated as the same boot.

The root password crosses only the password-backed authorization boundary and
is never saved. Windows carries it to system OpenSSH through a current-user
memory channel. macOS uses its secure native authorization sheet. Both append
only their dedicated public key and then require key-only proof.

After authorization, the shared tablet transaction verifies every staged
SHA-256, the hardware contract, the package's paired software install targets,
and existing Xovi ownership before mutation. It installs or repairs the
Mirror-owned probe, Xovi extensions, Files loopback, and transport service,
then returns one exact capability result.

Windows stores the paired network context and validates it before publishing
Wi-Fi. macOS binds a submitted Wi-Fi attempt to the current Wi-Fi context. On
both hosts, a user-entered IPv4 address selects one attempt; it is not persisted
and does not become the tablet identity.

Wi-Fi enablement and verification happen after the shared transaction as part
of the same owner-started setup operation. The native coordinator runs
`rm-ssh-over-wlan on`, verifies the Wi-Fi listener, and requires the same pinned
tablet identity. Each host stores its own protected network context, wake-token
reference, and local readiness profile. Neither host copies the other's local
state. Direct USB-C does not depend on Wi-Fi state.

## Frame capture

Xovi loads `framebuffer-spy` and `xovi-message-broker` for an owner-requested
connection. `rmmirror-probe` reads the Paper Pro Move framebuffer, crops each
960-pixel source row to the visible `954 x 1696` viewport, and streams versioned
RMM1 frames over SSH.

The Windows worker sends an immediate stream lease pulse and repeats it every
three seconds. The tablet helper exits after 15 seconds without a pulse instead
of leaving an orphaned capture session. A frame failure retires the selected
generation.

The Mac parser applies sequential full or dirty updates to one canonical BGRA
surface and presents it through one Metal texture. Screenshot copy and Save As
snapshot that same current-generation surface.

Xovi is installed persistently but is not configured as a Mirror boot service.
The host starts it only while preparing a connection.

## Session-only input

The probe creates temporary touch, pen, and keyboard devices after display
prerequisites are ready. It performs the Xochitl handoff, relays input, and
restores stock physical input when the session ends. A detached tablet watchdog
provides the same restoration if the host disappears unexpectedly.

There is no persistent Mirror input service, Xochitl boot dependency, udev rule,
or input startup hook.

Every Mirror-owned Xochitl or Xovi start/restart first resets only
`xochitl.service`'s systemd failure budget. If that reset fails, the action is
blocked.

The active input session keeps a 15-second protocol lease with three-second
pings. An exact `deep_sleep` startup handshake permits at most one guarded
power-button-equivalent event for that session. Activity events keep an already
selected session awake; they never choose or reopen a route.

## Files

Xochitl's stock Files service normally binds to the USB interface. The
GPL-3.0-only `rmmirror-files-loopback` Xovi extension makes the service available
on tablet loopback. Desktop hosts reach it only through an authenticated SSH
forward. The bearer HTTP service is never exposed directly on Wi-Fi.

Files is owner-started:

1. opening the pane creates a request for the current route generation;
2. an eligible capability claims a bounded readiness window;
3. closing the pane, reaching the deadline, or retiring the route stops the
   work; and
4. **Try Files Again** creates a fresh owner window.

The tablet disables Files while passcode-locked. Display and input can remain
Live. Unlocking can satisfy a still-open Files request without reconnecting the
route.

Imports use the stock multipart endpoint and accept PDFs and DRM-free EPUBs.
Once an upload starts, cancellation is treated as an ambiguous result so the UI
does not invite a duplicate send.

Exports support PDF and native RMDOC. Windows drag-out registers a delayed
`StorageItems` provider so Explorer's drag begins before tablet I/O. Mac uses an
`NSFilePromiseProvider` with the same deferred-materialization principle.
Partial work is removed; completed temporary files are retained only long enough
for the destination to finish reading them and are later swept.

## Sleep and wake

The tablet transport service is installed on the active root slot and published
as a static `multi-user.target` dependency. It qualifies a data attachment from
the direct USB carrier or one configured USB device controller. Once qualified,
charger power can preserve the hold through a transient data-signal loss. Power
alone never qualifies a charge-only cable, and uncertain state fails open to
stock sleep.

The service blocks only the stock suspend-then-hibernate executor while a
qualified connection exists. It renews the kernel wake lock and Xochitl
watchdog. The input helper separately holds a session wake lease.

The status/wake HTTP endpoint listens on:

- tablet loopback, with bearer authentication; and
- the fixed direct-USB address, additionally bound to `usb0`.

It never binds the tablet's Wi-Fi address. The tokenless direct-USB capability
accepts only bounded status and wake operations when both observed endpoints
match the cable range. A wake request can send one power-button-equivalent click
only when current system state authoritatively proves deep sleep.

These mechanisms preserve or recover bounded states; they are not a general
remote power-on system. After full Linux suspend, the user can still need to
press the tablet power button, unlock it, and explicitly connect again.

## Process ownership and shutdown

Each route generation has a unique identity. Retirement tombstones it before
taking its child snapshot, preventing stale work from launching another child.
Normal shutdown closes future admission, cancels the generation, sends TERM to
exact owned PIDs, waits for a bound, and uses KILL only for an exact survivor.
The hosts do not enumerate or kill processes by broad name.

Files callbacks, delayed drags, connection observations, and UI publications
carry generation or request identities. A stale callback cannot publish into a
new session.

## Persistent footprint

Both native setup paths install or repair the same probe, pinned Xovi runtime,
three active extensions, transport-wake service, and suspend guard. The shared
transaction also moves two incompatible Xovi extensions to the inactive
directory. Each owner-authorized host adds its own public key. The app-led
coordinator then enables Wi-Fi SSH and records host-specific protected
readiness state. See [What Mirror changes](TABLET_CHANGES.md).

Only the active A/B root slot is modified. Firmware updates can require a
package whose install-target list admits the newly active software pair. An
already complete installation remains usable when its runtime capabilities
pass. There is no complete tested stock-restoration workflow yet; see
[Uninstall status](UNINSTALL.md).

## Release boundary

Build success proves compilation, not device behavior. Windows, Linux ARM64,
and macOS builds are separate evidence from pairing, wake, input, Files,
firmware compatibility, clean installation, and uninstall proof.

Release packages must keep credentials, captures, diagnostics, and personal
network values out of source and artifacts. Files remains behind SSH, virtual
input remains session-only, and every persistent change must be disclosed.
