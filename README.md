# reMarkable Mirror

**Your reMarkable, right on your Windows desktop.**

<p align="center">
  <img src="docs/images/remarkable-mirror-live-wifi.png" width="558" alt="reMarkable Mirror connected to a Paper Pro Move over Wi-Fi">
</p>

I built reMarkable Mirror because I wanted the tablet on my desk to feel like
part of my computer. I wanted to click it, type into it, use my mouse as a pen,
take a screenshot, and move a document without reaching for a second utility.

That is what this app does. It shows the tablet's real interface inside a compact
native Windows app and connects directly over USB-C or your local Wi-Fi. There is
no cloud relay and no iFixRobots account.

> [!IMPORTANT]
> This is independent community software. It is not affiliated with, endorsed
> by, or supported by reMarkable AS.

> [!NOTE]
> A native SwiftUI/AppKit macOS port is now in active development under
> `mirror/macos`. The `0.2.0 (2)` source now covers secure pairing, RMM1 frame
> display and screenshots, Touch + Type and Pen, the complete Files transport,
> owner-initiated USB-C and Wi-Fi connections, direct-cable wake and recovery,
> and active-session continuity. The fixed,
> non-resizable window is `456 x 877` compact and `776 x 877` with Files open.
> On Mac, launch and cable appearance do not contact the tablet. Setup,
> authorization, and Wi-Fi verification begin only after an explicit owner
> action. One **Connect USB-C** click owns a bounded session that wakes the
> tablet through that cable, waits for its services, authenticates, and connects.
> It never selects or falls back to Wi-Fi. If the tablet requires its passcode,
> the owner unlocks it and the same USB-C session continues. A Live session stays
> on the connection the owner selected without automatic fallback, promotion,
> or reconnection. Active-session keep-awake remains enabled.
> The Files animation is accepted as smooth. The default-size product-surface
> pass is complete in source across compact and Files-open states: connection
> status remains metadata, Touch + Type and Pen remain adjacent one-click
> modes, action labels and icons stay stable while transient results use toasts,
> USB-C and Wi-Fi remain unbroken tokens, and internal Files failures map to
> user-facing copy. This is implementation plus a product-only local build and
> inspection boundary, not final owner acceptance. The Mac source has one
> production target and bundle identity; it contains no XCTest target, Preview
> menu, command-line mock states, or QA app variant. The last audited unsigned
> arm64 Release package is
> `artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`
> (SHA-256 `0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`).
> That checksum and archive audit apply only to the older package; it predates
> the current recovery and presentation changes and does not prove parity with
> the current product source. On 2026-08-08, current-worktree product runs
> completed owner-started **Connect USB-C** sessions to **Live** on the physical
> tablet and rendered its real frame. Files loaded seven root items, navigated
> into a folder and back, recovered after an owner-authorized unlock within the
> same owner window, and exported a valid PDF and native RMDOC archive with one
> `.rmdoc` suffix. Clipboard copy and Save As each produced a valid `954 x 1696`
> PNG. Touch and Pen taps changed the tablet, committed keyboard text appeared
> on it, and a continuous Touch + Type swipe advanced a bundled tutorial page.
> A clean **Command-Q** with active frame, input and Files children retired every
> owned process without an orphan or AppKit exception. A separate explicit USB-C
> connection brought a previously unreachable locked tablet back to its passcode;
> that is wake/recovery evidence, not proof of the exact fully-deep-sleep power
> event. No Wi-Fi or Keychain bearer was involved in these USB-C runs. Import or
> upload, delete, Finder drag-out, pen stroke, eraser/right-click, Wi-Fi, a signed
> current-source package, notarization, hosting, and owner acceptance remain open.
> See
> [macOS Getting Started](docs/macos/GETTING_STARTED.md) for the exact boundary.

## Start here

The full setup is in [Getting started](docs/GETTING_STARTED.md). Read it once
from the top before enabling Developer Mode. It covers the reset, backup,
Windows prerequisites, SSH pairing, installation, first connection, and Wi-Fi
check in one path.

> [!WARNING]
> Enabling Developer Mode factory-resets the tablet. Back up first. The reset
> also forgets Wi-Fi, so you must reconnect it from the tablet afterward.

## What it does

- Mirrors the live `954x1696` Paper Pro Move display over USB or Wi-Fi
- Treats mouse clicks and keyboard input as one natural **Touch + Type** mode
- Provides a separate mouse-as-pen mode
- Copies screenshots to the clipboard or saves them as PNG files
- Sends PDFs and DRM-free EPUBs with drag and drop
- Browses and exports documents through the tablet's stock Files service;
  document rows can be dragged straight into Explorer as normal PDFs, with no
  preparation screen before the drag begins
- Offers separate **Connect USB-C** and **Connect Wi-Fi** actions; Wi-Fi asks
  for the tablet's IPv4 address only after you choose it
- Recovers from ordinary lock and short-sleep states, and only shows **Live**
  when the display and controls are both ready
- Prevents ordinary suspend while USB remains attached and keeps the active,
  owner-selected input session awake
- Keeps the window shaped like the tablet, with a smooth reversible Files drawer

<p align="center">
  <img src="docs/images/remarkable-mirror-files.png" width="878" alt="reMarkable Mirror with the Files drawer open while the tablet is passcode locked">
</p>

The screenshot above shows what happens while the tablet is locked: display and
input stay live, while Files waits for the passcode.

## Current compatibility

This is the setup I use and have tested:

| Part | Tested setup |
| --- | --- |
| Tablet | reMarkable Paper Pro Move, code name `chiappa` |
| Tablet software | Beta `3.28.0.164`, OS build `5.8.199` |
| Installed app | Windows 11 x64, minimum build `22621` |
| Current source build path | Windows 11 x64 `23H2` or newer |
| Connections | Direct USB-C and Wi-Fi on the same network as the PC |

I have not tested other reMarkable models or firmware versions yet. The installer
depends on Paper Pro Move input and system details. If your configuration differs,
stop before running tablet setup and open an issue with the exact model and
software version.

## Availability

Every push to `main` builds two Windows downloads in GitHub Actions:

- **remarkable-mirror-windows-installer** contains one versioned installer ZIP.
  Inside are the Windows package, its matching .NET and Windows App runtimes,
  the tablet components, the complete onboarding, Getting started, and
  Troubleshooting guides, and the three app screenshots they reference. Use
  this for a new setup.
- **remarkable-mirror-portable-windows-x64** extracts to one self-contained
  `ReMarkableMirror.exe`. Use it only after the installer has already prepared
  the tablet and Windows account.

These private Actions downloads are previews, not public releases. The portable
EXE is not Authenticode-signed, so Windows may warn before opening it. Use the
complete installer for first-time setup.

Open **Actions > Build Windows downloads**, choose a successful run, and find
both files under **Artifacts**. [Getting started](docs/GETTING_STARTED.md) walks
through the complete installer path. GitHub wraps each Actions artifact in a
ZIP; for the installer, extract that download and then extract the versioned
installer ZIP inside it.

The repository is intentionally private while I finish the owner review. The
downloads are therefore available only to signed-in GitHub collaborators. There
is no public GitHub Release yet.

Before the first public binary release, I still need to complete this entire
guide once on a clean Windows account and a freshly reset supported tablet.

## Known limits

- Dragging a document out of Files creates a PDF. Native RMDOC export remains in
  the document's right-click menu, and native RMDOC import is not implemented.
- Native RMDOC Save As on Mac produced a single-suffix archive whose ZIP
  integrity was verified. Native RMDOC import remains unimplemented.
- Mirror accepts PDFs and DRM-free EPUBs. DRM-protected and malformed EPUBs may
  fail without enough explanation in the app.
- During an active Mirror session, the tablet's USB data-attachment guard prevents
  suspend while the cable is attached. The selected input session also holds a
  wake lease. If Linux has already completed suspend before a connection starts,
  there is no source-proven host wake guarantee. Press the tablet's power button
  once, enter its passcode, then choose **Connect USB-C** or **Connect Wi-Fi**
  again. Mirror does not reconnect or switch routes by itself.
- A firmware update can switch the tablet to a root slot without Mirror's
  components. Run `Install.cmd` again over unlocked USB when the app shows
  **Repair** and the release supports the new tablet software.

## Privacy and security

Mirror talks directly to your tablet. Documents, screenshots, credentials, and
usage data are not uploaded to an iFixRobots service. Device profiles and
credentials stay on the current Windows account.

Wireless control uses Developer Mode root SSH over WLAN with a dedicated local
key. Use Wi-Fi Mirror at home. On any shared network, use USB-C instead. Do not
use Mirror on public or guest Wi-Fi. The Files service is not published on
Wi-Fi: the app reaches tablet loopback through SSH.

Developer Mode weakens the tablet's normal secure-boot protections. reMarkable
documents that tradeoff directly in its
[Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
Read [Privacy](docs/PRIVACY.md) and the [Security policy](SECURITY.md) before
sharing logs or diagnostics.

## How it works

The Windows app waits at launch and keeps one owner-selected connection at a
time. **Connect USB-C** starts a bounded direct-cable attempt. **Connect Wi-Fi**
first reveals an IPv4 field and makes one attempt only after you submit it. The
app never falls back to, promotes, or reconnects another route automatically.
It reuses the established direct-USB and paired-network checks, verifies the
tablet's pinned SSH identity, reads the display through Xovi, and starts touch,
pen, and keyboard input only for that selected session. Nothing is added to
tablet startup for input. The Files tunnel starts only when you open Files.

Files stays separate. A packaged GPL-3.0-only loopback extension makes
Xochitl's stock Files service available on tablet loopback, and Windows reaches
it only through SSH forwarding. The transport wake endpoint also stays on
tablet loopback and the direct USB-C cable connection. It does not listen on
the tablet's Wi-Fi address.

Read [Architecture](docs/ARCHITECTURE.md) for the component and lifecycle map.

## Build and contribute

Start with [Development](docs/DEVELOPMENT.md) and
[Contributing](CONTRIBUTING.md). The repository includes the WinUI host, ARM64
Go companions, the Xovi Files extension source, the in-progress native Mac
host, packaging and install scripts, and focused policy checks.

Release packaging omits Mirror-owned PDB/CodeView output and stops if the app
DLL or EXE embeds a rooted application build path or the current repository or
user-profile root. It also stops if the complete public guide and screenshot
set is missing; there is no shorter private-guide fallback.

## Documentation

- [Getting started](docs/GETTING_STARTED.md)
- [macOS connection candidate](docs/macos/GETTING_STARTED.md)
- [macOS packaging status](docs/macos/PACKAGING.md)
- [Package onboarding](docs/PACKAGE_ONBOARDING.md)
- [Device setup reference](docs/DEVICE_SETUP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development](docs/DEVELOPMENT.md)
- [Privacy](docs/PRIVACY.md)
- [Release process](docs/RELEASING.md)
- [Support](SUPPORT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

reMarkable Mirror is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE).

`reMarkable` is a trademark of reMarkable AS. The name is used only to describe
device compatibility.
