# reMarkable Mirror

Mirror and control a reMarkable Paper Pro Move from Windows over USB or Wi-Fi.

reMarkable Mirror shows the tablet's real interface in a compact native Windows
app. Click and type naturally, use the mouse as a pen, take screenshots, and
move supported documents without reaching for a second tool.

> [!IMPORTANT]
> This is independent community software. It is not affiliated with, endorsed
> by, or supported by reMarkable AS.

## What works

- Live `954x1696` Paper Pro Move display over USB and Wi-Fi
- Automatic mouse touch and hardware-keyboard input
- Separate mouse-as-pen mode
- Clipboard screenshots and **Save As** PNG screenshots
- PDF/EPUB drop target and tablet file browser
- Stock Files service over an authenticated SSH tunnel on USB or Wi-Fi
- USB-first routing with automatic Wi-Fi fallback
- Automatic short-sleep recovery without publishing false **Live** controls
- Compact fixed-shape Windows UI with a smooth reversible Files drawer

The current source targets reMarkable Paper Pro Move. Other models and firmware
versions are not yet supported claims. Features listed here describe the source
tree; each future binary release will state its own exercised behavior and known
limits.

Still being proved: Pen over Wi-Fi, every import/export format over the Wi-Fi
Files route, automatic USB/Wi-Fi handoffs in both directions, full-suspend
wireless wake, and automatic prerequisite repair after an A/B root-slot update.

## Availability

This initial project is source-only. There is not yet an official public binary
release. Until the first release appears on this repository's GitHub Releases
page, build a development package from source and use your own package identity
as described in [Development](docs/DEVELOPMENT.md).

## Requirements

- Windows 11 version 22H2 or newer, x64
- PowerShell 7.5 or newer for tablet setup
- Windows OpenSSH client
- reMarkable Paper Pro Move in Developer Mode
- The tablet's first post-boot unlock completed
- A USB-C connection for first setup
- Wi-Fi on the same trusted personal network for wireless use

Developer Mode factory-resets affected reMarkable devices. Back up anything you
need before enabling it. The reset also removes saved Wi-Fi networks, so reconnect
the tablet from its own UI before expecting wireless Mirror access.

## Install from a future release

1. Follow [Device setup](docs/DEVICE_SETUP.md) once.
2. Download and extract an official release ZIP from this repository's GitHub
   Releases page.
3. Connect and unlock the tablet over USB-C.
4. Run `Install.cmd`.
5. Complete the Windows administrator prompt and let the installer finish.

These steps describe the workflow that will begin with the first public binary.
They are not a claim that a public binary is available today.

The installer installs the signed Windows app and provisions the matching tablet
components. If a firmware update changes the active A/B root slot, reconnect and
unlock over USB-C, then run `Install.cmd` again.

Official release packages use the iFixRobots package identity. Contributors can
build with their own publisher and package identity; see
[Development](docs/DEVELOPMENT.md).

## How it works

The Windows app owns one connection generation at a time. It authenticates the
tablet's SSH identity, captures the framebuffer through Xovi, and starts
session-only virtual input after the connection is ready. Files stays separate:
the packaged GPL-3.0-only loopback extension makes Xochitl's stock Files service
available on tablet loopback, and Windows reaches it only through authenticated
SSH forwarding. Port 80 is never opened directly on Wi-Fi.

The transport wake service's bearer-authenticated HTTP endpoint binds only to
tablet loopback and the direct USB interface. It does not listen on the tablet's
Wi-Fi address. Mirror uses the verified USB route before SSH is available;
loopback remains reachable only locally or through authenticated SSH forwarding.

Xochitl closes Files while the tablet is passcode-locked. Mirror display and
input can remain Live; Files becomes available automatically after unlock.

Read [Architecture](docs/ARCHITECTURE.md) for the component and lifecycle map.

## Privacy and security

Mirror is local-first. The app connects directly to the tablet over USB or your
local network. It does not upload documents, screenshots, credentials, or usage
data to an iFixRobots service. Device profiles and credentials remain local to
the current Windows user.

Wireless control requires Developer Mode root SSH over WLAN. Setup enables that
tablet feature and uses a dedicated passphrase-free key so non-interactive
`BatchMode` connections can work. Protect the Windows account and its `.ssh`
directory accordingly; do not reuse that key for another device or service.

Use Wi-Fi only on a trusted network. See [Privacy](docs/PRIVACY.md) and
[Security policy](SECURITY.md).

## Build and contribute

Start with [Development](docs/DEVELOPMENT.md) and [Contributing](CONTRIBUTING.md).
The repository includes the WinUI host, ARM64 Go companions, the Xovi Files
extension source, install/build scripts, and focused policy checks.

## Documentation

- [Device setup](docs/DEVICE_SETUP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development](docs/DEVELOPMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Privacy](docs/PRIVACY.md)
- [Release process](docs/RELEASING.md)
- [Support](SUPPORT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

reMarkable Mirror is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE).

`reMarkable` is a trademark of reMarkable AS. Use of the name describes device
compatibility only.
