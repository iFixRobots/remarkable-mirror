# macOS development build

The native SwiftUI/AppKit macOS app connects to the real reMarkable tablet over
authenticated SSH. It supports the compact mirror, session-only input,
screenshots, Files, and manual USB-C or Wi-Fi connection model.

> [!IMPORTANT]
> The app is real; its current setup flow is incomplete. The Mac bundle installs
> only the transport-wake subset, while mirroring also requires the probe, Xovi
> runtime, and extensions. Run the complete Windows installer once to install
> those tablet prerequisites.

> [!WARNING]
> Do not use this guide to enable Developer Mode on a new tablet. Start with the
> Windows [Getting started guide](../GETTING_STARTED.md), including its backup,
> reset, full tablet installation, and security warnings.

## Current support boundary

You need:

- Apple silicon;
- macOS 14 or newer;
- a reMarkable Paper Pro Move on a version supported by the matching release;
- the Mirror tablet prerequisites installed by the complete Windows setup;
- reMarkable Developer Mode still enabled;
- the tablet past its first physical unlock after boot; and
- a direct data-capable USB-C cable for Mac authorization.

The current arm64 Release app compiles on the configured Xcode 26 runner. USB-C
and manual-IP Wi-Fi connections, Live route switching, frame display, input,
screenshots, Files, and clean session shutdown have physical-device evidence.
Persistent Wi-Fi setup remains a separate evidence boundary.

The current development build is unsigned and not notarized. There is no
supported public Mac release yet.

## Install the development build

If a review ZIP is provided, extract it and move `reMarkable Mirror.app` into
your Applications folder. An unsigned development build may require **Open**
from Finder's context menu.

Contributors can build and install from source:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
scripts/Install-RemarkableMirrorMac.sh
open "$HOME/Applications/reMarkable Mirror.app"
```

The local installer refuses to overwrite an existing app. Quit and move the old
build aside before installing another one. See
[Development](../DEVELOPMENT.md) for the exact Xcode, Swift, and Go toolchain.

## Authorize this Mac

Authorization is manual and USB-only. Opening the app or attaching a cable does
not contact the tablet.

1. Connect the tablet directly with a data-capable USB-C cable.
2. Wake it and complete the first post-boot unlock.
3. Open Mirror and choose **Set Up**.
4. Mirror verifies one direct cable, captures the tablet's Ed25519 host identity
   through system OpenSSH, creates a dedicated Mac key, and saves a pending
   local profile. This first phase does not change the tablet.
5. Choose **Add This Mac…** only when you intend to authorize the Mac.
6. Review the confirmation and enter the current Developer Mode root password.
   Mirror does not save it.
7. The app appends only its dedicated public key and installs or verifies the
   transport-wake subset. It does not reinstall the probe or Xovi runtime.
8. If the result is uncertain, choose **Check Authorization**. That action makes
   one bounded key-only check; Mirror never reopens the password prompt by
   itself.

Disconnecting or replacing the tablet during authorization stops the attempt.
The pinned SSH identity, not cable presence alone, is the tablet trust anchor.

## Connect over USB-C

1. Choose **Connect USB-C**.
2. Mirror checks only the direct cable, asks the wake service to recover the
   tablet when safe, waits for its services, authenticates, and prepares one
   session.
3. If the tablet asks for its passcode, unlock it. The same bounded USB-C
   attempt continues.
4. Wait for **Live** before using Touch + Type or Pen.

One click owns the entire bounded USB-C attempt. It never checks, selects, or
falls back to Wi-Fi. If the attempt ends, Mirror returns to an actionable idle
state and waits for another owner action.

## Connect over Wi-Fi

After USB authorization succeeds:

1. Put the Mac and tablet on the same Wi-Fi network that you control.
2. Make sure the tablet is awake. It may remain locked.
3. Choose **Connect via Wi-Fi**, directly below **Connect USB-C**.
4. Enter the tablet's current IPv4 address and choose **Connect via Wi-Fi**.
5. Wait for **Live over Wi-Fi**.

The first click only opens a local prompt. Submitting starts one bounded
Wi-Fi-only attempt to that address, bound to the Mac's current Wi-Fi context
and authenticated with the pinned tablet identity. Mirror may check a
transiently offline route every three seconds during a 45-second attempt. It
does not auto-discover or save the address, inspect or use USB, wake the tablet,
fall back to another route, use the wake HTTP service, request a password, or
require an unlock.

**Connection > Set Up Wi-Fi…** is a separate optional persistent setup action.
It does not gate the manual IP connection. When used, keep USB attached; Mirror
verifies the current network context and Developer Mode SSH over Wi-Fi without
asking for the root password again.

The app does not read the Wi-Fi name, request Location Services, or store the
Wi-Fi password. Network changes do not start, switch, or reopen a connection.

Use Wi-Fi Mirror only on a network you control. Files stays on tablet loopback
and travels through authenticated SSH forwarding.

## Switch routes

- While USB is Live, click **Live over USB-C** to open the same Wi-Fi address
  prompt. Canceling leaves USB Live; submitting starts the Wi-Fi attempt.
- While Wi-Fi is Live, click **Live over Wi-Fi** to start the same bounded
  USB-C action used from the disconnected screen.

The Live status adds no third connection path, background probe, fallback, or
automatic route selection.

## Files and input

**Live** requires a current frame and input session from the same connection.
Files is separate and starts only when you open its pane.

If Files is unavailable because the tablet is locked, unlock it and leave the
pane open. The owner-requested readiness window can recover without reconnecting.
Closing Files or reaching its deadline stops further attempts; choose
**Try Files Again** for a new window.

Touch, pen, eraser, and keyboard devices exist only for the active session.
Closing the app or losing the selected connection retires that session and
restores stock physical input.

## Local data and reset

The profile and app-owned OpenSSH files live under:

```text
~/Library/Application Support/com.ifixrobots.ReMarkableMirror/
```

Directories use mode `0700`; files use `0600`. The address entered through
**Connect via Wi-Fi** is session-only and is not saved. Optional persistent
Wi-Fi setup stores the network-context secret and wake token in the Data
Protection Keychain. Direct USB-C does not use those secrets.

**Set Up Again…** can remove Mirror-owned local profile, SSH, and Keychain
material from the Mac. It does not remove the public key from the tablet,
disable tablet Wi-Fi SSH, or uninstall the tablet components.
See [Uninstall status](../UNINSTALL.md).

## Diagnostics and limits

Use **Help > Copy Connection Diagnostics** for a sanitized event summary.
Review it before sharing; it can still contain timestamps and software state.

Current limits:

- Mac setup does not yet install every tablet prerequisite;
- no signed or notarized public package;
- persistent Wi-Fi setup remains separately unproved;
- no complete tested uninstall/stock restoration;
- no automatic fallback, route selection, or reconnection; and
- full Linux suspend can still require a physical power-button press and
  explicit reconnect.

See [macOS troubleshooting](TROUBLESHOOTING.md) and
[Platform support](../PLATFORM_SUPPORT.md).
