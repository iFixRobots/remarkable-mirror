# reMarkable Mirror

**Use your reMarkable Paper Pro Move from your desktop over USB-C or Wi-Fi.**

<p align="center">
  <img src="docs/images/remarkable-mirror-live-wifi.png" width="558" alt="reMarkable Mirror connected to a Paper Pro Move over Wi-Fi">
</p>

reMarkable Mirror has native desktop apps for Windows and macOS. Both connect
over authenticated SSH to small ARM64 Linux components running on the
reMarkable tablet. The Windows app has a complete installer and setup path; the
macOS app is currently an unsigned development build.

Both apps show the tablet's real interface in a compact native window. You can
click, type, draw with the mouse, take screenshots, and move documents without
sending them through an iFixRobots cloud service.

> [!IMPORTANT]
> This is independent community software. It is not affiliated with, endorsed
> by, or supported by reMarkable AS.

> [!WARNING]
> First-time setup requires reMarkable Developer Mode. Enabling Developer Mode
> factory-resets the tablet, erases saved Wi-Fi networks, and weakens the normal
> secure-boot boundary. Back up and verify your content before continuing.

## What it does

- Mirrors the `954 x 1696` Paper Pro Move display
- Sends touch, keyboard, pen, and eraser input only while a session is active
- Copies screenshots or saves them as PNG files
- Imports PDFs and DRM-free EPUBs
- Browses and exports documents through the tablet's stock Files service
- Connects manually over direct USB-C or local Wi-Fi
- Switches routes from **Live over USB** on Windows, **Live over USB-C** on Mac,
  or **Live over Wi-Fi** on either host
- Keeps Files behind authenticated SSH instead of exposing it on the LAN

Mirror never chooses a connection on its own. Launching either app, attaching a
cable, or changing networks does not contact the tablet. **Connect USB-C**
checks only USB. **Connect Wi-Fi** on Windows and **Connect via Wi-Fi** on Mac
first reveal an IPv4 field, then check only that address. The clickable Live
status reuses those same actions to switch routes. If a session ends, both apps
wait for you to choose again.

## Platform status

| Surface | Current status |
| --- | --- |
| Windows 11 x64 | Native WinUI app with the complete installer and setup path, USB-C, Wi-Fi, input, screenshots, and Files. |
| macOS on Apple silicon | Native SwiftUI/AppKit app. The current build is unsigned and connects to the real tablet over USB-C or Wi-Fi. Its setup flow does not yet install every tablet prerequisite. |
| Tablet components | Small ARM64 Linux programs and Xovi extensions that run on the reMarkable itself. They are not a third desktop app. |

The only tested tablet target is the reMarkable Paper Pro Move (`chiappa`) on
the software version named by the release notes. Do not run tablet setup on a
different model or firmware unless that exact combination is listed as
supported. See [Platform support](docs/PLATFORM_SUPPORT.md).

## Start with a new tablet

Windows is currently required for the first complete installation.

1. Finish initial tablet setup and verify its model and software version.
2. Let reMarkable cloud sync finish, then confirm your content exists in an
   official reMarkable desktop or mobile app.
3. Download and extract the complete Windows installer. The portable EXE is
   for an account and tablet that are already prepared.
4. Follow reMarkable's official
   [Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
   The tablet resets.
5. Sign in again, reconnect Wi-Fi, wait for cloud restoration, complete the
   first physical unlock, and enable the tablet's USB web interface.
6. Pair the dedicated Mirror SSH key over direct USB-C, then run `Install.cmd`
   from the extracted installer folder.
7. Open Mirror and choose **Connect USB-C**. Set up Wi-Fi only after USB works.

The complete copy-and-paste procedure is in
[Getting started](docs/GETTING_STARTED.md). Read it once before enabling
Developer Mode.

## What setup changes

Mirror installs a pinned capture/input helper, Xovi and three extensions, a
loopback/direct-USB wake service, and a USB suspend guard on the active tablet
root slot. It also authorizes a dedicated SSH key and enables Developer Mode
SSH over Wi-Fi. Virtual input remains session-only; there is no persistent
input service or boot hook.

Read [Tablet changes](docs/TABLET_CHANGES.md) before installing. A complete,
tested one-click return-to-stock workflow does not exist yet; the current
[Uninstall status](docs/UNINSTALL.md) explains that limitation.

## Downloads

There is not yet a supported public binary release. Until a release appears on
the repository's **Releases** page, treat Actions artifacts and locally built
packages as development previews.

The complete Windows installer prepares both Windows and the tablet. The
portable `ReMarkableMirror.exe` installs nothing and works only after the same
Windows account and tablet have completed the installer path.

The current Windows development package uses a release-specific certificate
that the installer adds to **Local Machine > Trusted People**. That is not a
public code-signing identity. Verify the release source, hashes, and signing
notes before accepting any package.

## Privacy and security

Mirror connects directly to the tablet. There is no iFixRobots account,
analytics service, document index, screenshot upload, or cloud relay.

Developer Mode root SSH is powerful. The dedicated private key must be treated
like a root credential. Use Wi-Fi Mirror only on a network you control; use
USB-C on shared, guest, or public networks. Files and the wake service are not
published directly on the tablet's Wi-Fi address.

See [Privacy](docs/PRIVACY.md) and [Security policy](SECURITY.md).

## Known limits

- A clean-Windows, freshly reset tablet walkthrough still needs an independent
  end-to-end acceptance run before the first public binary release.
- The macOS development build does not yet install every tablet prerequisite;
  run the complete Windows setup once before using it.
- There is no Linux desktop app.
- A firmware update can switch to a root slot without Mirror's components.
- Full Linux suspend may require one physical power-button press before you
  unlock the tablet and explicitly reconnect.
- Native RMDOC export is supported; native RMDOC import is not.
- A complete tested uninstall/stock-restoration path is still open.

## Build and contribute

Start with [Development](docs/DEVELOPMENT.md) and
[Contributing](CONTRIBUTING.md). The repository contains:

- the Windows WinUI host;
- the native SwiftUI/AppKit macOS host;
- dependency-free Go companions built as static Linux ARM64 binaries;
- the Xovi Files loopback extension;
- installer, packaging, and policy checks; and
- public onboarding, architecture, privacy, and release documentation.

Build commands and evidence boundaries are recorded in
[Development](docs/DEVELOPMENT.md). Compilation is not physical-tablet proof;
device behavior is claimed only for paths that were actually exercised.

## Documentation

- [Getting started on a new tablet](docs/GETTING_STARTED.md)
- [Platform support](docs/PLATFORM_SUPPORT.md)
- [Tablet changes](docs/TABLET_CHANGES.md)
- [Uninstall status](docs/UNINSTALL.md)
- [macOS development build](docs/macos/GETTING_STARTED.md)
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
