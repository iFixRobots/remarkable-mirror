# Architecture

Mirror keeps the Windows product surface native and the tablet-side footprint
small. SSH is the authenticated control boundary for both USB and Wi-Fi.

```text
Windows WinUI app
  |
  +-- owner-selected probe: USB-C or entered Wi-Fi IPv4
  +-- frame SSH session -------------------------+
  +-- input SSH session -----------------------+ |
  +-- Files local forward -------------------+ | |
  +-- USB-only wake client ----------------+ | | |
                                         | | | |
Tablet                                   | | | |
  +-- transport-wake service <----------+ | | |
  +-- rmmirror-probe ----------------------+ | |
  +-- session-only virtual input -----------+ |
  +-- Xovi framebuffer-spy/message broker ----+
  +-- Xovi Files loopback -> 127.0.0.1:80
```

## Windows host

The WinUI 3 application owns the window, route selection, connection state,
frame presentation, input routing, screenshots, and file-transfer UI.

One route generation owns all of its child processes. Launch and cable or
network changes do not create a generation. **Connect USB-C** starts a bounded
attempt against only the direct-cable route and may use the cable-only wake
endpoint during that owner window. **Connect Wi-Fi** reveals an IPv4 field;
submitting a valid address starts one owner-bounded attempt against only that
Wi-Fi route. A first authenticated tablet-prerequisite mismatch permits one
confirmation probe after 500 milliseconds; other Wi-Fi outcomes end the
attempt. The entered address is not treated as identity: the paired network
context, pinned SSH identity, and tablet capabilities still gate publication.

The chosen route is pinned to its generation. There is no automatic USB-first
selection, fallback, promotion, or reconnection. A cable, network, frame, or
input-session failure retires the generation and returns to the manual choices.
**Live** requires both a fresh frame and a running input session from that same
generation. App-owned USB sockets bind to the verified `10.11.99.11/27` source
and exact direct-cable interface for the cable-only wake endpoint. SSH admission
reuses the established pinned-identity probe. Wi-Fi first passes the paired
Windows network check, then uses that same SSH admission path. Diagnostics keep
only fixed reason enums and route kinds, never the entered address, raw SSH
output, or credential data.

Files is also owner-started on Windows. Publishing a Mirror route does not open
the Files tunnel. Opening the Files pane starts its generation-bound readiness
probe; closing Files stops further attempts, and retiring that generation
prevents it from moving to another route.

Mirror sends an SSH keepalive every three seconds and tolerates two unanswered
probes before the third ends a persistent session. That failure retires the
selected generation; only another owner action can start a new connection.

Package setup uses a gated PowerShell launcher assigned to a Windows Job Object
before it may start the target process. Its JSON payload now travels through
standard input instead of being embedded in `-EncodedCommand`. This keeps the
launcher command fixed-size when the remote setup script grows and avoids the
Windows command-length limit. A payload-transfer failure terminates and verifies
the owned process tree.

## macOS host status

The native Mac host lives in `mirror/macos` and implements the product path
through Milestone 6 in source. It has one production Xcode target and bundle
identity, with no XCTest target, Preview/mock runtime or QA app variant. Local
Mac validation uses product-only builds and direct inspection of the product
surface; physical behavior is claimed only when that exact path ran. On
2026-08-08, current-worktree product runs reached **Live** over owner-started
USB-C with the real frame and owned frame, input and Files processes. Files
loaded seven root items, navigated into a folder and back, recovered after an
owner-authorized unlock within the same owner window, and exported valid PDF
and native RMDOC files. Clipboard copy and Save As produced valid `954 x 1696`
PNGs. Touch and Pen taps, a Pen stroke, committed keyboard text and a continuous
swipe changed the tablet. The native Files chooser sent a disposable one-page
PDF, and its round-trip export rendered the same page. A clean **Command-Q**
retired every owned process with no orphan or AppKit exception. Delete, raw
Finder drag-in, Finder drag-out, eraser/right-click, Wi-Fi and the exact
fully-deep-sleep power event remain unproved.

It uses SwiftUI for the product surface and an AppKit-owned `NSWindow` for the
fixed window contract. The app has one permanent expanded-width layout tree;
the compact window clips that tree rather than constructing Files on demand.

The non-resizable window contract is fixed at `456 x 877` compact and
`776 x 877` Files-open; Files programmatically adds exactly 320 points.
Connection status is plain metadata, the `Touch + Type` and `Pen` modes remain
adjacent one-click segments, and the Files toolbar action is a plain folder
icon. Action icons and labels remain stable while transient outcomes appear in
toasts, and Files maps internal failures to user-facing messages.

A window-scoped display link advances one timestamp-based progress value. That
same value changes the native window's trailing edge and the continuous stage
clip. Opening takes 250 ms, closing takes 167 ms, and both use
`p² × (3 − 2p)`. A new click retargets from the current rendered progress. The
window remains non-resizable, preserves its top-left point and height, and has
only compact and Files-open resting widths. If that left edge would put the
expanded pane outside the current display, the animator shifts the window only
far enough to keep the full frame inside the visible display margin.

Milestone 2 adds actor-owned profile, pairing, process, and connection services. The
profile is strict, versioned and non-secret. Its Application Support root and
SSH directory use `0700`; profile and OpenSSH files use `0600`. Reads reject
symlinks, widened permissions, wrong ownership, extra hard links, oversized
data, unknown JSON keys and inconsistent pinned identity. Replacement is an
fsynced same-directory rename.

Setup first proves that the same reMarkable remains attached directly through
one data-capable USB-C cable for the full check. Cable detection alone does not
authenticate the tablet; the pinned SSH identity is the trust boundary.
Host-key acquisition uses `/usr/bin/ssh`, not an unbound `ssh-keyscan`:
authentication is disabled, Ed25519 is the only host-key algorithm, and the
staging known-host path is private and quoted for OpenSSH's configuration
parser. The direct cable binding must still match after acquisition. Local
preparation then creates a dedicated Ed25519 key and saves a pending profile
without changing the tablet.

The Mac connection controller is owner-driven. Launch loads only local profile
state; neither launch nor cable or network changes start tablet communication.
**Set Up**, **Add This Mac…**, **Check Authorization**, and
**Connection > Set Up Wi‑Fi…** are explicit bounded operations. **Connect USB‑C**
starts one bounded direct-cable session. That session may repeat status, wake,
service-readiness, authentication, and connection checks against the same
cable-attached tablet until it succeeds, needs the tablet passcode, or reaches
its bound. It never inspects, selects, or falls back to Wi‑Fi. **Connect Wi‑Fi**
is a separate owner action. When an operation ends without connecting, the app
returns to an actionable idle state instead of continuing in the background.

The explicit **Add This Mac…** action is the persistent authorization boundary.
After repeating the exact direct-USB gates, it uses a one-time root password to
append only the dedicated public key, then installs or upgrades and validates
the tablet-side USB keep-awake service, including its kernel wake lock and
system sleep guard. It does not identify the Mac's Wi-Fi network or enable
tablet Wi-Fi SSH in that action. The password is never saved, and neither
documents nor the Wi-Fi password are changed. An uncertain result returns to
**Check Authorization**, which performs one bounded
key-only check and never reopens the password prompt by itself. Only a current,
exact-context key rejection makes another owner-started password attempt
eligible. **Connection > Set Up Wi‑Fi…** is a separate bounded action that
verifies the current Wi-Fi connection and completes the pending Wi-Fi
transition without appending the key again or requesting Location Services. The
authorized pending profile can be used for an explicit USB-only connection
before that transition; Wi-Fi connection remains unavailable until Wi-Fi setup
succeeds. Connection diagnostics are available under
**Help > Copy Connection Diagnostics**.
While Wi‑Fi verification is pending, the authorized profile can use
**Connect USB‑C**, but **Connect Wi-Fi** remains unavailable. The coordinator
publishes connection progress only if an
accepted attempt remains active for 250 ms; quicker outcomes proceed directly
to their result instead of flashing a progress card.

Every child belongs to a UUID generation. Retirement tombstones the generation
before taking its child snapshot, so a stale task cannot launch afterward.
Shutdown fences all future launches. TERM and bounded KILL target only exact
stored PIDs; no process enumeration or name-based kill is used. A failed
connection retirement retains ownership for retry. Activation publication runs in a
separate cancellable admission task, and the coordinator rejects canceled or
stale snapshots.

On macOS, the first normal termination request is canceled while the
coordinator asynchronously retires the active generation. Only a clean result
permits a second delegate pass to terminate immediately. The exact 2026-08-08
physical run stopped active frame, input and Files children, left no orphaned
forward, and logged no AppKit exception.

Authenticated transport is not **Live**. The publication reducer requires a
fresh frame and running input session from the same active generation. Files
readiness is independent.

Milestones 3–5 add the bounded RMM1 stream, one canonical Metal surface,
pasteboard and Save As screenshots, an AppKit pointer/keyboard surface with a
session-owned input actor, a loopback-only Files SSH tunnel, the stock Files HTTP
client, and Finder promises. Milestone 6 adds owner-approved pairing
finalization, an exact Wi-Fi network-context secret, owner-initiated connection
activation, active-session keep-awake, and generation-safe retirement across
the transport capabilities. The product surface presents the coordinator's
real state. No tablet component or protocol has been forked. Direct USB-C
activation, frame delivery, screenshot copy/save, tap/type/Pen input, a
continuous swipe, Files navigation, PDF export and native RMDOC export now have
physical-tablet proof. The narrower open boundaries are recorded below.

Fixed-name, payload-free Points of Interest intervals cover connection
activation, open-to-first-frame delivery, screenshot PNG encoding and Finder promise
fulfillment. They expose real wall-clock intervals to Instruments without
placing filenames, connection details, device identity or document data in the
signposts.

## Frame capture

Xovi loads `framebuffer-spy` and `xovi-message-broker` for the connection. The
ARM64 probe reads the Paper Pro Move framebuffer stream, crops each 960-pixel
source row to the visible `954x1696` viewport, and streams BGRA frames over SSH.
Xovi is activated on demand; Mirror does not add a tablet boot hook for it.

The probe treats session signals and standard-input closure as cancellation.
The Windows host closes retired SSH streams and waits for connection shutdown
on normal app exit. Its Job Object remains the fallback for a crash or forced
termination.

Every frame SSH generation also has its own lease. Windows writes one pulse
immediately and then every three seconds. The probe expires the generation
after 15 seconds without a pulse and exits without waiting for a frame write
that may be blocked on a dead connection. Windows classifies that timeout as a
transient stream interruption for safe copy, then retires the selected
generation and waits for another owner action.

During an upgrade, the prerequisite installer retires only the exact probe
processes running `stream`. Input and its watchdog are outside that match.

On macOS, `RMM1FrameStreamSession` parses sequentially into one canonical
`954x1696` BGRA surface and awaits each accepted update before reading another.
`TabletFramePresentation` applies full and dirty rectangles directly to one
shared Metal texture. Screenshot copy and Save As snapshot that same current
generation surface and encode an exact-size PNG off the main actor.

## Input

Input is session-only. After SSH and display prerequisites are ready, the probe
hands Xochitl to virtual touch, pen, and keyboard devices. Closing the app or
losing the session removes those devices and restores stock physical input.

Every Mirror-owned Xochitl/Xovi start or restart first resets Xochitl's systemd
failure budget. This prevents repeated connection work from exhausting the stock
restart limit and selecting the tablet's emergency target.

The Mac AppKit input surface normalizes against the exact visible viewport,
supports touch, pen, right-button eraser, hardware keys and committed text, and
keeps Command-modified shortcuts local. Focus loss, mode changes, connection
retirement, cancellation and app termination emit a reset and close the owned
interactive SSH session. **Live** cannot publish until that session and a fresh
frame belong to the same generation.

The Mac host preserves the full pointer trajectory while its bounded input
queue has room. Only after acknowledgement backpressure reaches the queue's
high-water mark does it compact contiguous motion into ordered representative
samples while retaining the latest position. Button release captures the AppKit
release coordinate as a final move immediately before `up`; that pair, all
release edges and reset remain protected from later pressure eviction.

AppKit character data is read only from key-down and key-up events. A
modifier-only `flagsChanged` event derives its routing data from the key code,
modifier flags and key location, so a local Command shortcut cannot call an
event accessor that AppKit does not permit for that event type.

The Windows and Mac input sessions share the same continuity contract. If the
strict startup handshake reports exactly `deep_sleep`, the host attempts one
atomic `KEY_POWER` click before publication and never retries that power event
within the session, even after a failed or partial acknowledgement. A Wi-Fi
session then sends one immediate `KEY_F12` activity event before controls are
published. The host repeats `KEY_F12` every 10 seconds on Wi-Fi or 45 seconds on
USB. Acknowledged user input resets that activity deadline. Three-second JSON
`ping` messages continue between activity events to retain the 15-second input
protocol lease.

## Files

Xochitl normally scopes its Files web service to the USB interface. The
GPL-3.0-only `rmmirror-files-loopback` extension changes that bind decision to
tablet loopback. Windows creates a strict authenticated SSH forward from a local
ephemeral port to `127.0.0.1:80`. It never exposes the bearer-authenticated
service directly on the Wi-Fi network.

Files is an independent capability. Xochitl closes its web service while
`userLocked` is true. Display and input can remain Live. Opening Files creates
an exact owner request for a bounded readiness window. The full window starts
only when an eligible capability from the current generation claims that
request; until then the request can wait for the owner-started connection.
Closing Files or reaching the 60-second deadline stops further attempts, and
request, capability and visibility identities reject stale completion or reopen
work. While the window is active, unlocking the tablet lets the same capability
retry and publish readiness without reconnecting or reopening the pane. After
expiry, the circular-arrow **Try Files Again** action creates a fresh 60-second
owner window; once available, that same control becomes **Refresh**. The
locked-to-unlocked path loaded a 7-item root listing on 2026-08-08.

Imports use the stock browser-style multipart form: an unquoted boundary and a
quoted `name="file"` and `filename="..."` without .NET's `filename*` extension.
Mirror accepts PDFs and DRM-free EPUBs up to the stock service's size limit.
Upload logs record the result category and numeric HTTP status, not the local
document filename. A mixed drop reports only the count of unsupported items,
never their local names. Once an upload request begins, cancellation or route
retirement is an ambiguous result rather than a definite failure; the owner is
told to inspect the tablet and refresh before retrying. A successful upload
refreshes the captured destination only when Files is still showing that same
folder, so later navigation is never replaced by a stale completion.

Files can export documents as PDF or native RMDOC. Dragging a document row out
of Mirror starts synchronously: `DragStarting` registers a delayed Windows
`StorageItems` provider and returns without contacting the tablet or showing a
preparation state. Explorer asks that provider for the file when it needs the
payload. Mirror then creates a human-named PDF in the current user's local app
cache on a worker thread and supplies it with copy-only semantics. This avoids
blocking the native drag transaction on tablet I/O or a brokered `StorageFile`
handoff. A private drag marker prevents Mirror's own import target from
accepting that same outbound file. A drag canceled before the provider is
requested creates no file; partial or canceled work is removed immediately.
Export requests share a cancellation-aware gate. If a canceled provider is
still unwinding, its replacement waits under the new provider's Windows
deadline instead of failing busy; the visible drag has already started.
Accepted files are kept briefly so the destination can finish reading them,
and abandoned cache entries are swept on a later launch. Native RMDOC import is
not implemented.

The Mac implementation reaches the same stock service only through an owned
loopback SSH forward. `RemarkableFilesClient` lists folders, serializes current-
folder selection and PDF/EPUB uploads, and exports PDF or RMDOC through atomic
local publication. `NSFilePromiseProvider` starts a Finder drag immediately and
defers PDF materialization until Finder requests it. Cancellation removes
partial files and stale promise cache entries are swept on launch. A process-
level owner registers each promise callback before fulfillment begins. Normal
quit starts its cancellation and drain concurrently with connection-generation
shutdown, then awaits both before making the termination decision. This lets
generation retirement cancel any earlier Files operation that a promise is
queued behind without permitting the app to exit while either owner still has
work. The final Finder name is published only by atomically renaming a fully
synchronized same-directory temporary file, so normal termination cannot expose
a truncated final PDF.

## Sleep and wake

The transport service qualifies a data attachment when carrier is `1` or
exactly one discovered USB device controller reports `configured`. Once
qualified, charger power preserves the hold through transient loss of both data
signals; power loss clears it. Power alone never qualifies a charge-only cable,
and unknown state fails open to stock sleep. While qualified, the service blocks
only the specific `suspend-then-hibernate` executor and renews a kernel wake lock
plus Xochitl's watchdog. The session-only input helper separately holds a
renewable wake lock for an active USB or Wi-Fi input session.

The service's HTTP endpoint listens only on tablet loopback and the direct
USB-C cable connection. Loopback is bearer-authenticated. The direct-cable
listener authorizes bounded status and wake through possession of the exact
verified cable, with no Keychain bearer. It accepts only the two fixed
operations when both server-observed endpoints match the cable range. A present
but invalid bearer is rejected rather than downgraded. The endpoint does not
bind Wi-Fi.
The Windows pre-SSH wake path pins its socket to the direct USB adapter;
loopback is available only on the tablet or through authenticated SSH
forwarding.

On Mac, **Connect USB‑C** and **Connect Wi‑Fi** are separate owner actions. One
**Connect USB‑C** click owns a bounded session on the exact direct cable. It may
wake the tablet and wait for the same tablet's services before authenticating
and connecting, but it never checks, selects, or falls back to Wi-Fi. If the
tablet reports that encrypted storage is locked, entering the passcode is the
only owner intervention required; the USB-C session then continues. The chosen
connection is pinned to the resulting generation. Cable or network changes do
not start, replace, or move a connection. A failed or retired generation returns
to the disconnected surface and waits for another owner action. Exact binding
revalidation still gates publication, and a fresh frame plus ready input from
the chosen generation remain required before the connection can publish
**Live**.

Normal continuity inside an owner-started connection comes from preventing
suspend, not from waiting until the kernel is already asleep. While a Live USB
session is attached, the data-attachment service keeps the tablet awake. The input wake
lock and connection-aware `KEY_F12` cadence keep the selected active session
awake.
They do not select another connection or reopen a retired session. A single
guarded `KEY_POWER` event handles an input session whose exact handshake reports
`deep_sleep`; it is not an unconditional network wake packet.

If the wake endpoint reports `starting` after SSH has already authenticated the
same candidate, the authenticated ready observation remains authoritative; the
transitional endpoint state cannot suppress activation.

The installer defines this service as static and publishes its
`multi-user.target` dependency under `/usr/lib/systemd/system`, because this
tablet's `/etc` overlay is volatile across reboot. It verifies both the exact
link and the dependency loaded by systemd. A firmware update can activate a
different root slot, which may need the matching components installed again.

The Mac direct-cable session asks the wake service to recover the tablet before
it attempts SSH and continues checking the same cable while the tablet starts.
It never switches to Wi-Fi. Entering the tablet passcode is the only owner
intervention this authorized USB session may require. Windows now follows the
same owner-started, route-pinned lifecycle. Its Wi-Fi entry differs
intentionally: after **Connect Wi-Fi**, Windows asks for the tablet's IPv4
address before making the single Wi-Fi attempt.

## Release package

The last audited unsigned arm64 `0.2.0 (2)` Release package is at
`artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`.
Its SHA-256 is
`0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
That checksum and archive audit apply only to the older package. It predates the
current recovery and presentation changes and does not prove parity with the
current product source. This is a local review artifact, not a release, and it does not replace
either accepted Windows build. A signed current-source package, notarization, a
hosted artifact, universal compilation and owner acceptance remain open.
Only explicit Wi-Fi setup stores the paired Wi-Fi context secret and wake token
in the Mac Data Protection Keychain. Direct USB-C never requires either secret.
Persistence and access-group behavior in an authorized signed current build
remain unproven.

Release builds disable Mirror-owned PDB/CodeView output while Debug builds keep
their symbols. Before signing, the package builder inspects the app DLL and EXE
and stops if either embeds a rooted application CodeView path or the current
repository or user-profile root. The SDK-provided native apphost may retain its
own framework build provenance; it is not a path produced from this checkout.

The installer package also requires the complete public onboarding, Getting
started, and Troubleshooting guides plus all three app screenshots. A missing
guide or image stops the build; there is no shorter guide fallback.

## Trust boundaries

- SSH host identity is pinned once over direct USB and reused through
  `HostKeyAlias=10.11.99.1`. Both hosts can use it for Wi-Fi; macOS has proved
  no physical pairing for that flow yet.
- Wi-Fi is accepted only with the paired host's protected network-context
  secret and a matching current network connection.
- Wake traffic stays on the verified direct USB-C cable or tablet loopback;
  loopback is reachable remotely only through authenticated SSH forwarding.
  The tokenless recovery exception exists only on the exact direct-cable
  listener and permits bounded status and one authoritatively gated power click.
- Credentials, device profiles, screenshots, and documents stay on the local
  host account unless the user explicitly saves or transfers them.
- Resetting local Mac setup deletes Mirror-owned local profile, key and Keychain
  material. It does not remove the authorized tablet key or disable tablet
  Wi-Fi SSH.
