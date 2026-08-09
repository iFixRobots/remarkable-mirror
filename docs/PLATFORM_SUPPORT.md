# Platform support

reMarkable Mirror has native desktop apps for Windows and macOS. Both connect
over authenticated SSH to small ARM64 Linux components running on the
reMarkable tablet. The Windows app has a complete installer and setup path; the
macOS app is currently an unsigned development build.

| Platform | What exists | First-time tablet setup | Current boundary |
| --- | --- | --- | --- |
| Windows 11 x64 | Native WinUI desktop app | **Complete installer and setup path** | USB-C, Wi-Fi, input, screenshots, and Files |
| macOS 14+ on Apple silicon | Native SwiftUI/AppKit desktop app | **Unsigned development build** | USB-C, Wi-Fi, input, screenshots, and Files; current Mac setup does not install every tablet prerequisite |
| ARM64 Linux on the tablet | Small helpers and Xovi extensions | Not a desktop platform | Components run on the reMarkable and support both desktop apps |

## Tablet compatibility

The current target is:

- reMarkable Paper Pro Move;
- code name `chiappa`;
- beta software `3.28.0.164`; and
- OS build `5.8.199`.

That is the configuration used during development; it is not a general promise
of compatibility with every Paper Pro Move firmware. Before running
`Install.cmd`, compare the tablet's model and software version with the release
notes. Stop if the exact combination is not listed.

Other reMarkable models have different framebuffers, input devices, and system
layouts. They are not supported by the current installer.

## Windows

The installed app requires Windows 11 x64 build `22621` or newer. Building the
entire package from source practically requires Windows 11 `23H2` or newer,
because the Files extension build uses Docker Desktop with Linux containers.

Windows is currently the only host that can provision the complete tablet
runtime from a new Developer Mode reset. Follow [Getting started](GETTING_STARTED.md).

## macOS

The native Mac app targets Apple silicon and macOS 14 or newer. Current builds
use Xcode 26, Swift 6, and Go 1.26.5. The app and its unsigned package compile
on the configured arm64 GitHub runner.

The Mac app is a real native host that connects to the real tablet. Its setup
flow can create a Mac-specific SSH identity and install the transport-wake
component, but it does not yet install the probe, Xovi runtime, and Files
extension set. Run the complete Windows setup once to install those
prerequisites, then follow the
[macOS development-build guide](https://github.com/iFixRobots/remarkable-mirror/blob/main/docs/macos/GETTING_STARTED.md).

USB-C, manual-IP Wi-Fi, and Live route switching have physical-device evidence.
The separate persistent **Connection > Set Up Wi-Fi…** path remains a distinct
evidence boundary.

## Linux

The repository builds two dependency-free static Linux ARM64 programs:

- `rmmirror-probe`; and
- `rmmirror-transport-wake`.

It also builds the `rmmirror-files-loopback` Xovi extension with a pinned
cross-toolchain. These are tablet components, not an end-user Linux desktop app.

## What build success proves

A successful build proves that source compiles for its stated target. It does
not prove pairing, wake, mirroring, input, Files, clean installation, firmware
compatibility, or uninstall behavior on physical hardware. Those claims require
separate exercised evidence.

See the repository's
[Development guide](https://github.com/iFixRobots/remarkable-mirror/blob/main/docs/DEVELOPMENT.md)
for build commands and
[Tablet changes](TABLET_CHANGES.md) for the installed footprint.
