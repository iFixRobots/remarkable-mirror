# reMarkable Mirror

**Use your reMarkable Paper Pro Move from your desktop over USB-C or Wi-Fi.**

<p align="center">
  <img src="docs/images/remarkable-mirror-live-wifi.png" width="558" alt="reMarkable Mirror connected to a Paper Pro Move over Wi-Fi">
</p>

reMarkable Mirror has native desktop apps for Windows and macOS. Both connect
over authenticated SSH to small ARM64 Linux components running on the
reMarkable tablet. The Windows app has a complete installer and setup path; the
macOS app is currently an unsigned development build.

Mirror shows the tablet's real interface in a compact native window. You can
click, type, draw with the mouse, take screenshots, and move documents without
sending them through an iFixRobots cloud service.

> [!IMPORTANT]
> This is independent community software. It is not affiliated with, endorsed
> by, or supported by reMarkable AS.

> [!WARNING]
> A tablet that is not already configured for Mirror requires reMarkable
> Developer Mode. Enabling it
> factory-resets the tablet, erases saved Wi-Fi networks, and weakens the
> normal secure-boot boundary. Back up and verify your content first.

## What it does

- Mirrors the `954 x 1696` Paper Pro Move display
- Sends touch, keyboard, pen, and eraser input only while a session is active
- Copies screenshots or saves them as PNG files
- Imports PDFs and DRM-free EPUBs
- Browses and exports documents through the tablet's stock Files service
- Connects manually over direct USB-C or local Wi-Fi
- Switches routes when you click the Live connection status
- Keeps Files behind authenticated SSH instead of exposing it on the LAN

## First-time setup

The apps guide setup. You do not need to copy keys, run tablet commands, or
paste a PowerShell pairing script.

A clean app install opens on **Setup** and waits for **Start Setup**. If this
computer and tablet were already configured, connect them directly over USB-C,
keep the tablet awake and unlocked, and click **Start Setup**. Mirror verifies
the existing setup and goes straight to **Connect USB-C** and **Connect Wi-Fi**
without asking for a password or reinstalling the tablet components.

Only use the reset path below for a new or unconfigured tablet, or when Mirror
explicitly says authorization or installation is required.

1. Install Mirror before changing the tablet.
2. Back up the tablet and confirm your content in an official reMarkable app.
3. Follow reMarkable's official
   [Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
   The tablet resets.
4. Sign in again, reconnect Wi-Fi, wait for restoration, complete the first
   physical unlock, and enable **Settings > General > Storage > USB web
   interface**.
5. Connect the awake, unlocked tablet directly to the computer with a
   data-capable USB-C cable.
6. Open Mirror and click **Start Setup**. Mirror checks the connected tablet
   first. If this computer is already authorized and the tablet is ready, it
   goes straight to the connection choices.
7. Otherwise, enter the one-time Developer Mode password when asked. Mirror
   authorizes this computer, installs and verifies its tablet components, and
   prepares Wi-Fi SSH.
8. Choose **Connect USB-C** or **Connect Wi-Fi**. Wi-Fi asks for the tablet's
   current IPv4 address.

Developer Mode, the reset, account sign-in, Wi-Fi password, first unlock, and
USB approval remain tablet actions. Mirror cannot and does not bypass them.

Setup is explicit. Opening Mirror, attaching a cable, or changing networks does
not contact the tablet. Setup, connection, route switching, and repair begin
only after you click the matching action. Mirror never falls back, switches, or
reconnects by itself.

Use the [Windows guide](docs/GETTING_STARTED.md) or the
[macOS development-build guide](docs/macos/GETTING_STARTED.md) for the short
platform-specific path.

## Platform status

| Surface | Current status |
| --- | --- |
| Windows 11 x64 | Native WinUI app with a complete installer, app-led tablet setup and repair, USB-C, Wi-Fi, input, screenshots, and Files. |
| macOS on Apple silicon | Native SwiftUI/AppKit app with app-led tablet setup and repair, USB-C, Wi-Fi, input, screenshots, and Files. Current packages are unsigned development builds. |
| Tablet components | Small ARM64 Linux programs and Xovi extensions that run on the reMarkable itself. They are not a third desktop app. |

The native setup screens are not pixel-for-pixel identical, but they follow the
same owner-approved stages and invoke the same pinned tablet transaction.

The only supported tablet target is the reMarkable Paper Pro Move (`chiappa`)
on a software version named by the release. Do not run setup on another model
or firmware unless that exact combination is listed. See
[Platform support](docs/PLATFORM_SUPPORT.md).

## Downloads

There is not yet a supported public binary release. Until one appears on the
repository's **Releases** page, treat Actions artifacts and locally built
packages as development previews.

For Windows, extract the complete installer and run `Install.cmd`; it installs
the native app and opens it for first-time setup. The current development
package uses a release-specific certificate added to **Local Machine > Trusted
People**. That is not a public code-signing identity.

The macOS app is unsigned and not notarized. Move the provided app into
Applications and use Finder's **Open** action if macOS asks you to confirm it.

Verify the release source, hashes, and signing notes before accepting either
package.

## What setup changes

Mirror adds one dedicated host public key and installs a pinned capture/input
helper, Xovi and three extensions, a loopback/direct-USB wake service, and a USB
suspend guard on the active tablet root slot. It also enables Developer Mode
SSH over Wi-Fi. Virtual input remains session-only; there is no persistent
input boot hook.

Read [What Mirror changes](docs/TABLET_CHANGES.md) for the exact footprint. A
complete, tested one-click return-to-stock workflow does not exist yet; see
[Uninstall status](docs/UNINSTALL.md).

## Privacy and security

Mirror connects directly to the tablet. There is no iFixRobots account,
analytics service, document index, screenshot upload, or cloud relay.

Developer Mode root SSH is powerful. Treat Mirror's dedicated private key like
a root credential. Use Wi-Fi Mirror only on a network you control; use USB-C on
shared, guest, or public networks. Files and the wake service are not published
directly on the tablet's Wi-Fi address.

See [Privacy](docs/PRIVACY.md) and [Security policy](SECURITY.md).

## Known limits

- The new app-led first-time setup paths still need fresh-tablet physical
  acceptance before the first public binary release.
- The macOS development distribution is unsigned and not notarized.
- There is no Linux desktop app.
- A firmware update can switch to a root slot without Mirror's components.
- Full Linux suspend may require one physical power-button press before you
  unlock the tablet and explicitly reconnect.
- Native RMDOC export is supported; native RMDOC import is not.
- A complete tested uninstall/stock-restoration path is still open.

## Build and contribute

Start with [Development](docs/DEVELOPMENT.md) and
[Contributing](CONTRIBUTING.md). The repository contains the Windows and macOS
hosts, dependency-free Go companions for tablet Linux ARM64, Xovi extensions,
packaging, and public documentation.

Build commands and evidence boundaries are in
[Development](docs/DEVELOPMENT.md). Compilation is not physical-tablet proof;
device behavior is claimed only for paths that were actually exercised.

## Documentation

- [Windows setup](docs/GETTING_STARTED.md)
- [Windows package start here](docs/PACKAGE_ONBOARDING.md)
- [macOS development-build setup](docs/macos/GETTING_STARTED.md)
- [Platform support](docs/PLATFORM_SUPPORT.md)
- [What Mirror changes](docs/TABLET_CHANGES.md)
- [Tablet setup internals](docs/DEVICE_SETUP.md)
- [Uninstall status](docs/UNINSTALL.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Privacy](docs/PRIVACY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development](docs/DEVELOPMENT.md)
- [Release process](docs/RELEASING.md)
- [Support](SUPPORT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

reMarkable Mirror is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE).

`reMarkable` is a trademark of reMarkable AS. The name is used only to describe
device compatibility.
