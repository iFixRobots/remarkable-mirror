# macOS Getting Started

The native Mac app now implements the product path through Milestone 6 in
source. It can pair this Mac with explicit approval, make owner-initiated USB
and Wi-Fi connection attempts through owned system OpenSSH processes, display
RMM1 frames, send session-only input, create screenshots, use the stock Files
service, and keep an active connection awake. It builds as a single production
target under stable Xcode 26.6. Shared Go tests, vet and host-policy checks also
pass. On 2026-08-08, current-worktree product runs reached **Live** over
owner-started USB-C with the real frame and owned frame, input and Files
processes. Files loaded seven root items, navigated into a folder and back,
recovered after unlock within the same owner window, and exported valid PDF and
native RMDOC files. Screenshot copy and Save As produced valid `954 x 1696`
PNGs. Touch and Pen taps, a Pen stroke, committed keyboard text and a continuous
swipe changed the tablet. The native Files chooser sent a disposable one-page
PDF, and its round-trip export rendered the same page. A clean **Command-Q**
retired all owned children without an orphan or AppKit exception. Delete, raw
Finder drag-in, Finder drag-out, eraser/right-click, Wi-Fi and the exact
fully-deep-sleep power event remain open.

## Current boundary

Candidate `0.2.0 (2)` includes:

- one non-resizable tablet-proportioned window, fixed at `456 x 877` compact and
  `776 x 877` Files-open;
- a programmatic Files reveal that moves only between those two widths and whose
  animation the owner described as good and smooth; opening Files also shifts
  the window only when needed to keep the expanded pane on the current display;
- plain connection-status metadata, adjacent one-click `Touch + Type` and `Pen`
  segments, and a plain Files folder icon;
- a versioned, current-user device profile under Application Support;
- dedicated mode-`0600` OpenSSH identity and known-host files;
- owned `/usr/bin/ssh` processes with strict Ed25519 host checking;
- bounded secure-connection and capability checks;
- generation-scoped process retirement and stale-event rejection;
- a bounded RMM1 stream and direct Metal presentation;
- current-frame PNG copy and Save As;
- Touch + Type, Pen, right-button eraser, hardware-key routing, and focus-loss
  reset through a session-owned input process;
- Windows-parity input continuity: a single guarded power event for an exact
  `deep_sleep` handshake, immediate Wi-Fi activity, 10-second Wi-Fi and
  45-second USB activity cadence, user-input deadline reset, and three-second
  protocol pings;
- loopback-only Files forwarding, folder browsing, PDF/EPUB import through a
  native multi-file chooser or drag and drop, PDF/RMDOC export, and deferred
  Finder document promises; mixed imports report skipped unsupported-item
  counts without local names, and an interrupted send remains explicitly
  unconfirmed until the owner refreshes instead of inviting a duplicate retry;
- an owner-opened Files pane whose 60-second same-session readiness window can
  recover after tablet unlock without a reconnect or pane reopen, and stops on
  pane close or deadline, with an explicit **Try Files Again** renewal;
- an explicit **Add This Mac…** finalizer for the persistent tablet key and
  tablet-side USB keep-awake service, followed by separate
  **Connection > Set Up Wi‑Fi…** verification;
- manually resumable pending-Wi-Fi setup, protected Wi-Fi context and wake secrets;
- explicit setup, authorization, verification, USB connection, and Wi-Fi
  connection actions; one **Connect USB‑C** click owns a bounded same-cable
  wake, recovery, authentication, and connection session;
- active-session keep-awake without automatic fallback, promotion, or
  reconnection; and
- generation-safe cancellation, retirement and service-scoped local reset.

The default-size product-surface pass is complete in source across compact and
Files-open states. Connection status remains metadata; Touch + Type and Pen
remain adjacent one-click modes; action labels and icons stay stable while
transient results use toasts; USB-C and Wi-Fi remain unbroken tokens; internal
Files failures map to user-facing copy. This is implementation and
local-validation evidence, not final owner acceptance. Direct USB-C connection,
frame delivery, screenshot copy/save, tap/type/Pen input, a continuous swipe,
Files navigation, PDF export and native RMDOC export have physical proof. The
narrower remaining gaps are listed below.

An authenticated SSH transport still appears as **Secure connection ready**,
not **Live**. Live requires a current frame and a current input session from the
same generation. Files readiness remains independent. Wi-Fi pairing,
owner-initiated connection, and active-session wake support are implemented in
source. Physical evidence now includes persistent SSH authorization and a
completed owner-started USB-C session; deep-sleep wake and Wi-Fi remain
unproven.

Local setup still stops before changing the tablet. **Add This Mac…** is the
separate, explicit persistent-change boundary. It appends this app's dedicated
public key to the tablet and installs or upgrades the USB keep-awake service,
including its wake lock and sleep guard, after the exact direct-USB gates pass
again. It does not inspect Wi-Fi in that action. Its
one-time root password is never saved. It does not change documents or the
Wi-Fi password. **Connection > Set Up Wi‑Fi…** separately verifies the current
Wi-Fi connection.

## Pairing flow

1. Connect the reMarkable directly by a data-capable USB-C cable.
2. For this first setup, wake the tablet and enter its passcode.
3. Open Mirror. Launch and USB appearance load local state only; neither starts
   tablet communication.
4. Choose **Set Up** to run one bounded direct-USB preparation attempt. If it
   cannot finish, correct the reported condition, then choose
   **Retry Setup**.
5. After local preparation completes, choose **Add This Mac…** only when you
   intend to make the persistent tablet changes described below.
6. Review the confirmation, then enter the tablet's current one-time root
   password. Mirror does not save it. This USB-only action does not request
   any Wi-Fi or Location Services permission. The submission is bounded. If its
   result cannot be confirmed, Mirror stops at **Check Authorization**; choosing
   that action makes one key-only check. Mirror never reopens the password
   prompt by itself.
7. After authorization, choose **Connect USB‑C** to use the authorized direct
   connection immediately. That one click owns a bounded session that wakes the
   tablet through the same cable, waits for its services, authenticates, and
   connects. It never checks, selects, or falls back to Wi-Fi. If the tablet
   asks for its passcode, unlock it; the USB-C session continues.
8. Choose **Connection > Set Up Wi‑Fi…** when both devices are on the Wi-Fi
   network you want to use. Mirror makes one Wi-Fi setup check, then enables and verifies
   Developer Mode SSH over Wi-Fi without requesting the tablet password again.
   **Connect Wi‑Fi** becomes available only after that succeeds.

Before contacting the tablet, Mirror requires a data-capable USB-C cable that
connects the reMarkable directly to this Mac. It then confirms that the same
cable-attached device remains present throughout the check. Disconnecting the
cable or replacing the device stops the attempt. Cable detection alone does not
authenticate the tablet; the pinned Ed25519 SSH host key supplies that identity
proof after first-use approval.

If those checks succeed, Mirror creates a dedicated local key and pinned host
file and saves a pending profile. No tablet file or setting has changed at that
point.

**Add This Mac…** repeats the exact direct-cable admission checks, appends only
the dedicated public key to the tablet's root authorized keys, and installs or
upgrades and validates the tablet-side USB keep-awake service, including its
wake lock and sleep guard. An uncertain result is presented as
**Check Authorization**; that explicit action performs one bounded
key-only check on a freshly revalidated direct USB context. Mirror does not save
or request the password again unless that check conclusively rejects the key
and the owner starts another authorization attempt.

After authorization succeeds, **Connect USB‑C** can use the authorized direct
connection immediately. **Connection > Set Up Wi‑Fi…** verifies the current Wi-Fi
connection,
enables and verifies Developer Mode SSH over Wi-Fi, and never appends the key or
requests the root password again. Keep USB connected and keep the Mac and tablet
on the intended Wi-Fi network for that attempt. Mirror binds Wi-Fi approval to
that current connection without reading the network name or requesting Location
Services.

Connection diagnostics are available from
**Help > Copy Connection Diagnostics**.

Resetting setup in the Mac app deletes Mirror-owned local profile, SSH and
Keychain material. It does not remove the tablet-side public key or disable
Developer Mode SSH over Wi-Fi.

An earlier app build performed background recovery work. That behavior is not
the current Mac contract. A product-only build alone is not physical pairing,
frame, input, Files, owner-started connection, or wake-completion proof; only
the exact paths recorded in the dated physical checkpoint carry that evidence.

Earlier failed checks were traced to application setup, tablet-service and host
pipe defects rather than either tested cable. Those observations are superseded
by the 2026-08-08 one-click Live session above. If macOS genuinely withholds USB
data, Mirror reports **USB data is blocked**; keep the Mac unlocked, reconnect
USB-C, and handle a macOS accessory prompt only if one appears. Mirror cannot
trigger or guarantee that prompt and does not change the Mac's accessory policy.

## Implemented connection behavior

With an authorized profile, the source waits without tablet communication until
the owner chooses **Connect USB‑C** or **Connect Wi‑Fi**. The chosen action then:

1. admits only the exact direct cable or approved Wi-Fi connection;
2. authenticates with the pinned host identity;
3. prepares Xovi without bypassing the reset-before-start rule;
4. opens the session-owned input process and the leased RMM1 frame stream;
5. publishes **Live** only after display and controls from the current session
   are ready;
6. starts a loopback-only Files forward and publishes Files separately when the
   stock service responds; and
7. owns and retires that session's frame, input, Files, wake, and SSH work
   together.

Opening Files is its own owner action. It creates a 60-second readiness window for
the exact pane request and current connection generation. If the stock service
is unavailable because the tablet is locked, unlock the tablet and leave Files
open; the same request can recover without another connection or pane click.
Closing Files or reaching the deadline stops the attempts. After expiry, choose
the circular-arrow action labeled **Try Files Again** to start a fresh 60-second
owner window without closing the pane. Once Files is available, that same action
becomes **Refresh** and reloads the listing.

When Files is available, click the send target or focus it and press Return or
Space to choose one or more PDFs or DRM-free EPUBs. The same target also accepts
files dragged from Finder, although that exact drag-in interaction remains
unproved in the current candidate. New documents are sent to the folder shown
in Files.

Launch, cable attachment, and network changes never start a connection. If the
chosen connection disappears or the session fails, Mirror returns to the
disconnected surface and waits for another owner action. It does not fall back
to Wi-Fi, move to USB, or reconnect automatically.

One **Connect USB-C** click starts a bounded session on that cable. Mirror asks
the direct-cable wake service to recover the tablet, waits for its services, and
then authenticates and connects without asking for another click. It never
checks or selects Wi-Fi. If the tablet requires its passcode, unlock it; that is
the only owner intervention the USB-C session may require. If the bounded
session cannot finish, Mirror returns to an action instead of continuing in the
background.

Mirror waits 250 ms before showing connection progress. If the bounded attempt
finishes sooner, it goes straight to its result instead of flashing a progress
card.

When an input session starts, it inspects the strict handshake before
publication. Only an exact `deep_sleep` state permits one guarded `KEY_POWER`
event in that session. Wi-Fi sends one immediate `KEY_F12` before controls
publish. Active sessions then send `KEY_F12` every 10 seconds on Wi-Fi or 45
seconds on USB; acknowledged user input resets the activity deadline.
Three-second `ping` messages continue between activity events.

The tablet's USB data-attachment service prevents suspend during an active USB session.
The input helper's wake lock and host activity cadence preserve the selected
active session. Those mechanisms do not choose another connection or reopen a
retired session.

This sequence is implemented in source. The dated physical checkpoint proves
only the exact connection, frame, input-session, Files-readiness and shutdown
paths it records; other activation and capability paths remain source-only.

## Local storage and secrets

The profile and OpenSSH material live under:

```text
~/Library/Application Support/com.ifixrobots.ReMarkableMirror/
```

The root and SSH directories use mode `0700`; profile, key, public-key and
known-host files use mode `0600`. The profile contains no private key, bearer
token, password, raw network identifier, or absolute credential path.

Only explicit Wi-Fi setup stores the paired Wi-Fi context secret and wake token
in the Data Protection Keychain. Direct USB-C admission, status, wake and
connection never require that bearer. Persistence, service scoping and
access-group behavior must still be proved in an authorized signed package.

## Target and build host

- Deployment target: Apple silicon on macOS 14 or newer. The macOS 14 runtime
  has not yet been exercised.
- Candidate Release toolchain: Xcode 26.6 at `/Applications/Xcode.app`, Swift
  6.3.3, and the macOS 26.5 SDK.
- Current source evidence: the source builds as a single production target
  under stable Xcode 26.6. Shared Go tests, vet and host-policy checks also pass.
  The last audited Release build predates the current recovery and presentation
  changes.

## Build

From the repository root:

```zsh
scripts/Build-RemarkableMirrorMac.sh
```

The Release app is written to:

```text
artifacts/macos/DerivedData/Build/Products/Release/reMarkable Mirror.app
```

## Package and install

Create the private unsigned arm64 review ZIP:

```zsh
scripts/Package-RemarkableMirrorMac.sh
```

The package script derives the version and architecture from the built app. For
this candidate the expected filename is:

```text
artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip
```

The last audited local review ZIP is:

```text
artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip
```

Its SHA-256 is
`0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
That checksum and archive audit apply only to this older package. It predates
the current recovery and presentation changes, does not prove parity with the
current source, and does not establish physical-tablet behavior. A signed
current-source package, notarization, hosting and owner acceptance remain open.

For a first local install:

```zsh
scripts/Install-RemarkableMirrorMac.sh
open "$HOME/Applications/reMarkable Mirror.app"
```

The installer refuses to replace an existing app. Quit and move an earlier
candidate aside explicitly before installing another one. Current physical
runs used a durably authorized Mac profile; the separate Wi-Fi setup step
remains pending.

When installing the older unsigned review ZIP, macOS may require **Open** from
the Finder context menu. A local launch is not current-source parity, Developer
ID, notarization, release, or Gold proof.

The Xcode project contains one production app target. Debug and Release use the
same production bundle identifier, with no auxiliary Mac targets or
developer-only UI.

See [Port status](PORT_STATUS.md) for the evidence ledger and
[Troubleshooting](TROUBLESHOOTING.md) for setup and launch failures.
