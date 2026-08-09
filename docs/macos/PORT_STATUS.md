# macOS port status

This file tracks the native macOS port against the current Windows product. It
is a parity ledger, not a release claim.

## Source and host

- Source base: `bc13e5cacee748493818fe2d1ac471a1deafcf2b` (`Fix Wi-Fi repair classification`)
- Working branch: `feat/native-macos`
- Host: Apple silicon (`arm64`), macOS `27.0` (`26A5388g`)
- Selected command-line toolchain at discovery: Xcode `27.0` beta, Swift `6.4`
- Stable toolchain chosen for the candidate build: Xcode `26.6` (`17F113`), Swift `6.3.3`, macOS `26.5` SDK
- Initial target: native Apple silicon, macOS 14 or newer
- Current source boundary: Milestones 1–6 implemented in source. The app builds
  as a single production target under stable Xcode 26.6. On 2026-08-08,
  current-worktree USB-C runs reached Live with the real frame and owned frame,
  input and Files processes. They exercised Files recovery/navigation,
  PDF/RMDOC export, PDF import and round-trip export, screenshot copy/save,
  tap/type/Pen input including a pen stroke, a continuous swipe, and clean
  owned-process shutdown. Wi-Fi and the remaining product boundaries below
  remain open
- Current app identity: one production target using
  `com.ifixrobots.ReMarkableMirror`, version `0.2.0 (2)`, for Debug and Release
- Last audited unsigned arm64 package:
  `artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`
- Current engineering journal: [Direct USB-C Live checkpoint](journal/2026-08-08-direct-usb-live.md)

The stable Xcode installation is used deliberately for the candidate even
though this Mac currently selects the beta toolchain globally.

## Windows-to-Mac parity map

| Product responsibility | Windows source | Native Mac ownership | Status |
| --- | --- | --- | --- |
| App and fixed-size window | WinUI `MainWindow` and `MainPage` | SwiftUI app surface with one AppKit `NSWindow` coordinator | Implemented in Milestone 1 candidate |
| Dark product header and controls | XAML controls and WinUI styles | SwiftUI, SF Symbols, native buttons, menus, tooltips and focus | Known fixed-format issues corrected; final default-size text and action-semantic sweep remains |
| Tablet stage and recovery cards | XAML stage, viewbox and state mapping | SwiftUI opaque paper surfaces with exact viewport geometry and product recovery states | Implemented in Milestone 1 candidate |
| Reversible Files reveal | WinUI compositor clip plus programmatic window-width transition | One permanent SwiftUI Files view and a window-owned `CADisplayLink`; one progress value drives window width and stage reveal | Owner described the Files animation as good and smooth |
| Connection generation | .NET lifecycle services and owned child processes | Swift actors, cancellable publication admission, generation tombstones and exact owned `Process` children | Physically exercised over USB-C, including clean active-session quit with no orphan |
| Frame stream | .NET RMM1 parser and `WriteableBitmap` | Bounded Swift parser, canonical BGRA surface and direct Metal presentation | Physical USB-C frame exercised |
| Input session | .NET pointer/key routing and SSH JSON session | AppKit event/focus bridge plus an actor-owned ordered protocol session | Handshake, heartbeat, Touch tap, committed text, Pen tap, Pen stroke and continuous swipe physically exercised; eraser/right-click remains open |
| Screenshots | WinRT clipboard and file picker | Current Metal-surface snapshot, PNG encoding, `NSPasteboard` and `NSSavePanel` | Clipboard copy and Save As produced valid `954 x 1696` PNGs |
| Files transport | .NET SSH forward and HTTP client | Loopback-only owned `/usr/bin/ssh` forward plus `URLSession` | Listing, folder navigation, unlock recovery, native-chooser PDF import and round-trip export, PDF export and native RMDOC export physically exercised; delete, raw Finder drag-in and Finder drag-out remain open |
| Finder drag-out | Delayed WinRT storage provider | Process-owned `NSFilePromiseProvider` fulfillment with atomic final publication | Implemented in source; canceled drag followed by Escape and clean quit physically exercised on an older corrected build; current Finder drag-out file materialization and termination drain remain unproved |
| Profile and credentials | Windows profile files and credential protection | Strict versioned Application Support profile, mode-`0600` OpenSSH files and Wi-Fi-only Keychain secrets | USB authorization exercised; signed-package Keychain behavior unproven |
| Pairing finalizer | Windows onboarding and dedicated-key authorization | Separate bounded `Add This Mac…`, `Check Authorization`, and `Connection > Set Up Wi-Fi…` operations behind exact direct-cable gates | Persistent USB authorization and helper repair exercised; Wi-Fi setup unproved |
| Connection selection and lifecycle | USB-first monitor with paired Wi-Fi fallback | Connection card stacks owner-started `Connect USB-C` above `Connect via Wi-Fi`; the Wi-Fi action locally asks for an IPv4 address, then starts one bounded Wi-Fi-only attempt to it, while USB-C owns a bounded same-cable wake-through-connect session | Intentional Mac divergence; USB-C and manual-IP Wi-Fi connection physically exercised |
| Wake and active-session continuity | USB data-attachment guard, input wake lock, guarded deep-sleep power event and connection-aware activity | Same tablet services plus one guarded `KEY_POWER`, immediate Wi-Fi `KEY_F12`, and 10-second Wi-Fi/45-second USB activity inside an owner-started connection | Active USB session exercised; an explicit USB-C connection returned a previously unreachable locked tablet to its passcode, but the exact fully-deep-sleep power event remains unproved |
| Local reset | Current-user profile and credential cleanup | Service-scoped Keychain cleanup followed by app-owned profile and SSH reset | Implemented in source; tablet-side authorization intentionally remains |
| Diagnostics | Bounded sanitized Windows log | Bounded fixed-code in-memory ledger and copyable sanitized report | Implemented in Milestone 2 |

## Tablet components reused unchanged

- `rmmirror-probe` capture, capability, stream, input and recovery commands
- The session-only virtual touch, pen and keyboard protocol
- Xovi `framebuffer-spy` and `xovi-message-broker`
- The `rmmirror-files-loopback` extension and stock Xochitl Files HTTP service
- `rmmirror-transport-wake`, its loopback/direct-USB endpoint and sleep guard
- Tablet deployment scripts and the reset-before-Xochitl/Xovi-start rule

Milestones 1–6 reuse these tablet components without changing them. Mac local
preparation stops before a tablet change. The separately confirmed
**Add This Mac…** action can append the dedicated public key after the exact direct-USB
gates pass again. **Connection > Set Up Wi‑Fi…** separately enables and verifies Developer
Mode SSH over Wi-Fi.

## Visual invariants

- One native title bar, then a 66-point navy application header and one warm
  rounded stage.
- Product colors remain `#000A23`, `#EDECE7`, `#FAF9F5`, `#F7F6F1`,
  `#202124`, `#5F6066`, `#3858E9` and bezel `#1D1D1F`.
- The non-resizable window is fixed at `456 x 877` compact and `776 x 877`
  Files-open. Files programmatically adds exactly 320 points; those are its only
  resting widths. A current Release product exists; installed endpoint
  measurement remains pending.
- Opening Files preserves the window's top-left origin and height. Only the
  trailing edge moves. The tablet, header leading region and stage never
  translate or rescale.
- The stage owns the outer 24-point corners. Files has only a one-point internal
  divider; it is not a second card or window.
- Tablet chassis geometry remains `978 x 1720`, bezel inset 12, with a square
  `954 x 1696` visible screen scaled uniformly down only.
- The live screen and Files surfaces stay opaque and paper-like in either
  system appearance. Material is limited to native chrome where it remains
  legible.
- Files remains a trailing utility drawer, never a leading navigation sidebar.
- Current source copy wins over the older Files screenshot: `Drop files in.
  Drag documents out.`
- Connection status is plain metadata beside the device identity, not a button
  or capsule. It remains fully readable instead of truncating.
- `Touch + Type` and `Pen` remain adjacent one-click segmented choices. The
  Files toolbar action is a plain folder icon without a circular container.

## Transport and lifecycle invariants

- Launch, USB appearance, and network changes update Mac presentation state
  only. They do not start tablet communication.
- **Set Up**, **Add This Mac…**, **Check Authorization**, and
  **Connection > Set Up Wi‑Fi…** are explicit bounded Mac operations.
  **Connect USB‑C** starts one bounded direct-cable session that wakes, waits for
  services, authenticates, and connects without selecting or falling back to
  Wi-Fi. If the tablet requires its passcode, the owner unlocks it and that
  USB-C session continues. The connection card places **Connect via Wi‑Fi**
  directly below **Connect USB‑C**. Choosing the Wi-Fi action first opens a local
  prompt for the tablet’s IPv4 address and says the tablet must be awake but may
  remain locked. Submitting starts one Wi-Fi-only attempt to that address, bound
  to the current Wi-Fi context and authenticated with the saved pinned SSH
  identity. It may repeat transient-offline checks every three seconds during a
  45-second retry window; a bounded check admitted before expiry may finish
  afterward. It never auto-discovers or persists an address, inspects or uses
  USB, wakes the tablet, falls back to another transport, calls the wake HTTP
  endpoint, requests a password, or requires an unlock. Failure returns to both
  manual connection choices. Files remains separate and may still require one.
- Pending persistent Wi-Fi setup does not block either manual connection choice.
  **Connect USB‑C** and **Connect via Wi‑Fi** remain available in that order; the
  entered Wi-Fi address is used for that attempt only and does not complete the
  separate persistent Wi-Fi setup.
- The connection progress card appears only when an accepted attempt remains
  active for 250 ms. Faster outcomes go directly to their actionable result.
- Sanitized diagnostics are available under
  **Help > Copy Connection Diagnostics**.
- **Connect USB‑C** or submitted **Connect via Wi‑Fi** pins the selected
  connection to one generation. One generation owns probe, frame, input,
  Files-forward and wake work; retirement precedes any later owner-started
  replacement.
- `Live` requires a fresh frame and running input from the same generation.
  Files readiness remains independent.
- System OpenSSH starts with a dedicated identity, `BatchMode`,
  `IdentitiesOnly`, strict pinned Ed25519 host checking, no global known-host
  fallback, a roughly three-second connect timeout, three-second keepalives,
  and retirement after three missed replies. Windows `NUL` becomes `/dev/null`.
- Paths embedded inside OpenSSH `-o` values are quoted and escaped for the
  OpenSSH configuration parser; separate `Process.arguments` remain shell-free.
- First-use host-key capture runs through `/usr/bin/ssh` with authentication
  disabled, `StrictHostKeyChecking=accept-new`, Ed25519-only host keys, and a
  private staging known-host file. Admission requires one directly attached,
  data-capable USB-C cable, and the same cable-attached reMarkable must still be
  present after acquisition.
- **Add This Mac…** repeats the exact direct-cable checks before using a
  one-time, unsaved root password to append only the dedicated public key and
  install or upgrade and validate the tablet-side USB keep-awake service,
  including its wake lock and sleep guard. It makes no Wi-Fi-context request.
  An uncertain result stops at
  **Check Authorization**, which performs one bounded key-only check and never reopens
  the password prompt by itself.
  **Connection > Set Up Wi‑Fi…** separately verifies the current Wi-Fi connection, enables and
  verifies Developer Mode SSH over Wi-Fi, and never repeats the key append or
  requests Location Services.
  Documents and the Wi-Fi password remain unchanged.
- After the direct cable is verified, **Connect USB-C** asks the wake service to
  recover the same tablet and waits for its services before authenticating. An
  unavailable SSH endpoint is not mislabeled as cable absence and does not
  select Wi-Fi.
- An exact input handshake state of `deep_sleep` triggers one atomic
  `KEY_POWER` attempt before publication. The attempt is limited to that
  session, including failed or partial acknowledgement.
- Wi-Fi input sends one immediate `KEY_F12` before controls publish. Active
  input repeats `KEY_F12` every 10 seconds on Wi-Fi or 45 seconds on USB;
  acknowledged user input resets the activity deadline. Three-second protocol
  pings remain active between activity events.
- The tablet's USB data-attachment guard prevents suspend while attached. The input
  helper wake lock and connection-aware activity preserve the owner-selected
  active session. They do not select another connection or reopen a retired
  session.
- Wi-Fi admission uses a protected paired network-context secret and rechecks
  the current network connection around probing and activation. An identity or
  network-context rejection never weakens the trust boundary.
- Cable and network changes retire an affected Mac generation and return to the
  disconnected surface. They never trigger automatic fallback, promotion, or
  reconnection. A later connection starts only after another owner action.
- Direct USB-C status and wake use the exact cable without a Keychain bearer;
  the protected bearer is reserved for explicit Wi-Fi setup. Wake,
  frame, input and Files work are structured under the owning generation so
  cancellation waits for cleanup rather than publishing a stale result.
- Opening Files creates an exact owner request for a 60-second readiness window.
  The full deadline begins when an eligible capability from the current
  generation claims it; pane close or deadline ends retry work. While Files is
  unavailable, **Try Files Again** explicitly renews the owner window without a
  close/reopen. Request, capability and visibility identities prevent stale work
  from consuming a later request or rearming a closed pane.
- The host tracks and retires only its own child processes.
- A generation is tombstoned before retirement snapshots its children. A stale
  task cannot add another process afterward, and shutdown fences every future
  launch. Retirement failure keeps the generation owned for a later retry.
- Normal AppKit termination is canceled while generation shutdown drains those
  children, then reissued only after a clean result. Modifier-only
  `flagsChanged` events use key code, flags and location instead of reading
  key-event character data.
- The frame command remains `/home/root/.local/bin/rmmirror-probe stream
  --interval 40ms --heartbeat-timeout 15s`; the host sends an immediate lease
  pulse and another every three seconds.
- RMM1 is a 28-byte little-endian header followed by tightly packed BGRA. The
  backing allocation is `960 x 1696` at a 3840-byte stride; the companion
  already crops to `954 x 1696`. Sequence numbers strictly increase and dirty
  rectangles must stay in bounds.
- The repository does not contain the `mirror/protocol/` directory referenced
  by the port brief at this commit. Frame authority is therefore the producer
  in `mirror/agent/internal/device/stream_linux.go` and the parser in
  `mirror/windows/ReMarkableMirror/SshFrameSource.cs`. Input authority is
  `mirror/agent/INPUT_PROTOCOL.md`.
- Files stays behind authenticated SSH forwarding to tablet
  `127.0.0.1:80`. Uploads serialize and retain the browser-style multipart
  shape: unquoted boundary, quoted `name="file"` and `filename="..."`, no
  `filename*`.
- Every Mirror-owned Xochitl or Xovi start/restart must first reset
  `xochitl.service`'s systemd failure budget and must stop if that reset fails.
- Virtual input is session-only and must reset on cancellation, focus loss,
  connection retirement and app close.
- Local reset first deletes service-scoped Wi-Fi and wake secrets, then removes
  only the app-owned profile and SSH material. It does not remove a tablet-side
  authorized key or disable Developer Mode Wi-Fi SSH.

## Mac-specific unknowns

- Delete, raw Finder drag-in, Finder drag-out file materialization,
  eraser/right-click, short-sleep recovery, the exact fully-deep-sleep power
  event and persistent Wi-Fi setup remain unproved. The manual-IP Wi-Fi
  connection path is physically exercised.
- Only explicit Wi-Fi setup stores the Wi-Fi context secret and wake token
  through the Data Protection Keychain adapter. Direct USB-C does not use them.
  The current unsigned app has no proved Team
  Identifier or access-group policy, so service scoping and signed-package
  persistence remain unproven.
- App Sandbox compatibility with launching system OpenSSH and unrestricted
  Finder save/promise destinations is not claimed. The first private build is
  direct-distribution and unsandboxed; hardened runtime can remain enabled.
- Wi-Fi network-context pairing uses the current SystemConfiguration network state and
  never reads the SSID or BSSID or requests Location Services. Its behavior on
  a physical network and in a signed package remains unproven. No personal
  address enters logs or repository state.
- Developer ID signing and notarization are credentialed release steps. Local
  builds may be unsigned or ad-hoc and will be labeled exactly as such.

## Proven now

- Repository identity, recorded initial clean base and exact source commit.
- Host architecture, macOS version, selected beta toolchain and installed
  stable Xcode/Swift versions.
- The three Windows reference images were opened at their original dimensions:
  compact `558 x 1033`, Files-open `878 x 1033`, and Preparing `878 x 1033`.
- Source-level Windows geometry, state wording, animation curve/timings and
  tablet/protocol ownership boundaries were inspected.
- The current source builds as a single production target under stable Xcode
  26.6 with Swift 6 complete strict concurrency enabled.
- Mac quality evidence is limited to product-only builds, direct inspection of
  named app states, and physical-device observations recorded below. Source
  implementation alone is not runtime or tablet-path proof.
- `go test ./...` plus `go vet ./...` pass for the shared tablet companion.
- Host-policy checks pass for the current tree.
- The unsigned arm64 Release ZIP at
  `artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`
  has SHA-256
  `0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
  Its archive audit recorded a clean extraction, and its packaged binary
  matches the installed app.
- The owner described the observed Files animation as good and smooth, then
  asked implementation to continue. Known fixed-format issues were corrected,
  but the final default-size user-visible styling sweep remains open and the
  animation feedback is not acceptance of the overall Mac candidate.
- One owner-started Connect USB-C action reached Live on the physical Paper Pro
  Move with its real frame and persistent authenticated frame, input and Files
  processes.
- Files was already open when that connection started with the tablet locked.
  After an owner-authorized unlock through the mirrored tablet UI, the same USB
  generation recovered automatically and loaded a 7-item root listing
  without reconnecting or reopening the pane.
- Files navigated into a folder and back, exported a valid PDF, and exported a
  valid native RMDOC ZIP archive with one `.rmdoc` suffix.
- The native Files chooser sent a disposable one-page PDF to the root library.
  Mirror reported one sent file, the listing advanced from seven to eight
  items, and the new document exported back as a valid one-page PDF whose
  rendered page matched the original.
- Clipboard copy and Save As each produced a valid `954 x 1696` PNG.
- A Touch tap, committed keyboard text, a Pen tap, a Pen stroke and one
  continuous swipe changed the physical tablet. The temporary stroke was
  removed with the tablet's Undo control; the swipe advanced a bundled tutorial
  from page 3 to page 4.
- An owner-started USB-C connection returned a previously unreachable locked
  tablet to its passcode. That is qualified wake/recovery evidence, not proof of
  the exact `deep_sleep` handshake or guarded power event.
- Command-Q with active frame, input and Files children retired every owned
  process, left no orphaned forward and produced no AppKit exception. On the
  corrected build, the same clean shutdown passed after Escape canceled a
  Finder file-promise drag; file materialization itself remains unproved.
- The current product-only Debug build launched from its exact build output.
  That is not proof of an installed package identity.

## Not yet proven

- Runtime compatibility on the macOS 14 deployment target.
- Developer Mode Wi-Fi SSH enablement or interrupted physical setup recovery.
- Files delete, raw Finder drag-in and Finder drag-out file materialization;
  eraser/right-click; short-sleep recovery; the exact fully-deep-sleep power
  event; and owner-started Wi-Fi. Source implementation and a product-only build
  are not proof of those paths.
- Real Keychain persistence and access-group behavior in an authorized signed
  package.
- An actual power event from a physically deep-sleeping tablet.
- A hosted run of the macOS packaging workflow or any hosted Mac artifact.
- Signing, notarization, owner acceptance, release or Gold status.

## Final styling ledger

Run this only after the remaining product behavior is complete. Inspect every
user-visible state at the default text size in both fixed `456 x 877` compact
and `776 x 877` Files-open formats, including setup, recovery, errors, empty
Files states and confirmations. Keep tokens such as `USB‑C` on one line, keep
status or approval copy from looking like a button, preserve adjacent one-click
`Touch + Type` and `Pen` choices, and keep toolbar actions visually distinct
from metadata. Verify labels, line breaks, truncation and action semantics for
states that are not normally visible during the happy path. This final sweep
remains pending and is not owner acceptance.
