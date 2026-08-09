# Changelog

Notable user-visible changes are recorded here.

## Unreleased

### Highlights

- Advanced the native SwiftUI/AppKit macOS candidate to `0.2.0 (2)` through the
  Milestone 6 source boundary. It now includes secure Mac-side profile and SSH
  ownership, owner-approved tablet key authorization and Wi-Fi SSH enablement,
  direct Metal frame presentation, screenshots, Touch + Type, Pen and eraser
  input, tablet Files and Finder drag-out, separate owner-started USB-C and
  Wi-Fi connections, wake and recovery. On Mac, the connection card now places
  **Connect via Wi‑Fi** directly below **Connect USB-C**. That action first opens
  a local prompt for the tablet’s IPv4 address and says the tablet must be awake
  but may remain locked. Submitting starts one Wi-Fi-only attempt to the entered
  address, bound to the current Wi-Fi context and authenticated with the saved
  pinned SSH identity, with three-second offline checks during a 45-second retry
  window. A bounded check already admitted may finish afterward. The attempt
  does not auto-discover or save an address, inspect or use USB, wake the tablet,
  fall back to another transport, use the wake HTTP service, request a password,
  or require an unlock. Failure returns to the two manual connection choices.
  Files remains separate and may still require an unlock. The fixed
  non-resizable window is `456 x 877`
  compact and `776 x 877` with Files open. The Files animation is accepted as
  smooth; this is not owner acceptance. The final default-size pass over every
  user-visible label, line break and action semantic remains on the port
  ledger. Files now refreshes only after opening
  reaches its endpoint, success notices dismiss after three seconds, and the
  pane uses a native circular close action while the toolbar folder stays plain.
  Sleeping direct USB endpoints now stay in the wake-and-unlock retry flow
  instead of being mislabeled as cable absence, and a wake endpoint reporting
  `starting` no longer suppresses an already authenticated ready route.
  Authorization recovery now keeps retrying while showing the current USB state
  instead of an indefinite setup spinner, including a distinct macOS accessory
  approval state when Restricted Mode is blocking USB data. The
  Mac input session now matches the Windows continuity path: it sends one
  `KEY_POWER` only when the strict startup handshake reports `deep_sleep`, sends
  an immediate `KEY_F12` before publishing Wi-Fi controls, repeats `KEY_F12`
  every 10 seconds on Wi-Fi or 45 seconds on USB, resets that activity deadline
  after acknowledged user input, and retains three-second protocol pings. The
  Mac source now has one product target and bundle identity, with no XCTest
  target, Preview/mock runtime, or QA app variant. It builds as a product-only
  Debug target under stable Xcode 26.6. The last audited unsigned arm64 Release
  ZIP has SHA-256
  `0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
  That archive predates the current source and does not establish parity with
  it. On 2026-08-08, one owner-started Connect USB-C action reached Live on the
  physical tablet with a real frame and persistent authenticated frame, input
  and Files sessions. USB-C admission, status and wake now use only the exact
  verified cable; the Keychain bearer is reserved for explicit Wi-Fi setup.
  Physical touch/pen effects, unlocked Files operations, screenshots,
  deep-sleep wake, Wi-Fi, signing, notarization, hosted artifact, release, Gold
  and owner acceptance remain open on macOS.

- Mirror now moves naturally between USB and Wi-Fi while keeping display,
  **Touch + Type**, Pen, screenshots, and Files together in one Windows app.
- You can send PDFs and DRM-free EPUBs to the tablet and save documents back to
  Windows as PDF or native RMDOC. A document row can also be dragged straight
  into Explorer as a normal PDF file. That drag-out flow starts immediately,
  shows no preparation screen, can be canceled and retried right away, and
  keeps Mirror responsive while Windows requests the PDF only when the
  destination needs it.
- The complete installer prepares both Windows and the tablet; an optional
  portable EXE is available for accounts that are already set up.
- Connection cleanup, wake handling, and stale-frame recovery have been
  tightened without installing persistent input hooks on the tablet.
- One interrupted Wi-Fi identity or capability check no longer sends the app
  to **Repair**. Wi-Fi repair now requires a repeated authenticated tablet
  mismatch, while direct USB setup failures still appear immediately.
- While Mirror is active, the tablet's USB data-attachment guard prevents suspend with
  the cable attached. Its input session keeps a wake lease and sends
  route-aware activity across USB-to-Wi-Fi handoff. If Linux has already
  completed suspend before Mirror can reach it, there is still no source-proven
  host wake guarantee: press the tablet's power button once, enter its passcode
  and leave Mirror open for automatic retry.
- The first-run guides, package checks, privacy boundaries, and release-source
  requirements are now part of the build itself.

<details>
<summary>Complete pre-release engineering history</summary>

- Created the standalone GPL-3.0-only product repository.
- Added repeatable builds, contributor guidance, installation instructions,
  security reporting, and complete third-party attribution.
- Restricted the bearer-authenticated wake endpoint to tablet loopback and the
  direct USB interface.
- Documented the root SSH-over-WLAN and dedicated key security boundary.
- Replaced the fragmented first-run notes with an illustrated end-to-end Getting
  started guide and a self-contained package onboarding guide.
- Added GitHub Actions builds for a complete Windows installer and a portable
  Windows executable.
- Reduced the portable executable from 283.52 MiB to about 67 MiB by removing
  unused AI, machine-learning, Widgets, and ReadyToRun payloads and compressing
  the remaining self-contained runtime.
- Made clean-runner installer builds carry Mirror's matching .NET runtime and
  stopped uploading a duplicate expanded installer folder beside the release
  ZIP.
- Recorded owner-tested Pen input over Wi-Fi in installed Gold
  `1.2608.416.5801`.
- Tested automatic USB-to-Wi-Fi fallback and Wi-Fi-to-USB promotion on my tablet
  with Mirror left open. Touch + Type and Files worked after each connection
  settled.
- On the first USB-to-Wi-Fi handoff, Mirror reached Live, later entered a
  38-second host-side Disconnected interval, and then returned to Live
  automatically. The tablet journal showed no suspend, Wi-Fi loss, Xochitl
  sleep, reboot, or transport-wake event during that interval.
- Made retired frame streams stop promptly when a connection changes, the probe
  is cancelled, or the app closes normally.
- Made normal window close await connection shutdown while retaining the
  Windows Job Object as a crash fallback.
- Fixed PDF and DRM-free EPUB drag-in by matching the stock tablet importer's
  multipart header format. Upload diagnostics report the failure category and
  HTTP status without recording the document filename. Confirmed the corrected
  path over Wi-Fi. A separate live USB check on installed local candidate
  `1.2608.512.58` sent and opened one synthetic PDF and one DRM-free EPUB, then
  removed both and restored the exact pretest library. This is technical proof
  for that candidate, not a new Gold or public-release claim.
- Completed one Wi-Fi-only native RMDOC export in installed local candidate
  `1.2608.512.58`. The valid 24,318-byte archive had SHA-256
  `d89d3b474c080962f0f8b7fc192366ba4af14c5464cc94ca37fb694d614ae5a2`;
  its embedded PDF matched the known synthetic source at SHA-256
  `c10a4f19becbd0582a775eddbb146211cf836723789892de89831710599dc778`.
  The tablet library remained 12 items with zero tuple differences and the
  Windows export stage remained empty. This is technical proof only; there was
  no owner artifact review or Gold promotion.
- Updated the Windows app to tolerate two unanswered three-second SSH keepalives
  and treat a keepalive timeout as a reconnectable frame/input failure. The
  signed app from private candidate `1.2608.519.5834` later stayed Live over
  Wi-Fi for 12m02.7s with one stable frame, input, and Files worker and no
  reconnect or control failure. This is one technical host-tolerance pass, not
  owner acceptance or Gold; the tablet remained at its PIN screen, so Files was
  not ready in that session.
- Added a per-frame session lease in probe v0.4.9. Windows sends one immediate
  pulse and another every three seconds, and the remote process exits after 15
  seconds without a pulse even if framebuffer output is blocked. A prerequisite
  upgrade publishes the new probe first, then retires and verifies only exact
  `rmmirror-probe stream` processes without touching input or its watchdog. A
  local signed candidate installed v0.4.9. In a controlled technical check,
  deliberately suspending the Windows frame SSH worker made the remote probe
  expire in about 16.3 seconds. Mirror then opened one clean frame worker and
  returned to Live automatically with input and Files intact. This is targeted
  technical proof only; it does not change the accepted baseline or release
  status.
- Moved the gated launcher payload from the Windows command line to standard
  input. The launcher command now stays fixed-size, so long tablet prerequisite
  scripts no longer hit the Windows command-length limit.
- Updated the unreleased transport installer to publish its boot dependency as
  a static package-owned link under `/usr/lib/systemd/system`, verify that
  `multi-user.target` loaded it, and preserve exact rollback/removal behavior.
  Candidate `1.2608.519.5834` carried this installer, but its tablet-side
  prerequisites were deliberately not installed at that checkpoint. A later
  signed local candidate completed the package-matched probe v0.4.9 and
  transport installation on the active root. Ordinary-reboot and future-slot
  persistence proof remain open.
- Installed the signed Windows app from private candidate `1.2608.519.5834`.
  Windows reported AppX status `Ok` and `IsDevelopmentMode=False`; its initial
  launch was responsive. The MSIX SHA-256 is
  `ba24d7a3367c4c41467cf83b99dffb46ac3599ce3a59d2fb05b44f33d17400d5`, the
  installer ZIP SHA-256 is
  `508d443e4abc5e0968ed489e48f78c86ff50734f19ff4feafd93057df03b6d16`, and the
  valid signing certificate thumbprint is
  `B290F6C13E234A7427155620D30EE19F04592000`. That app-only install deliberately
  left the tablet prerequisites unchanged, and the tablet was offline during
  the first launch. The later technical Wi-Fi pass is recorded above; owner
  acceptance remains open. Gold stays `1.2608.416.5801`; rollback stays
  `1.2608.318.2528`.
- Made Release package builds omit Mirror-owned PDB/CodeView output and stop if
  the app DLL or EXE embeds a rooted application build path or the current
  repository or user-profile root. Debug builds keep their symbols.
- Removed the incomplete onboarding fallback. Every installer package now
  requires and carries the public onboarding, Getting started, and
  Troubleshooting guides plus all three app screenshots.

</details>

No public binary version has been released yet.
