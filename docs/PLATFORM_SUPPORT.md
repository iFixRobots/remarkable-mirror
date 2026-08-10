# Platform support

reMarkable Mirror has native desktop apps for Windows and macOS. Both connect
over authenticated SSH to small ARM64 Linux components running on the
reMarkable tablet.

| Platform | What exists | First-time setup | Current boundary |
| --- | --- | --- | --- |
| Windows 11 x64 | Native WinUI desktop app | **Start Setup** inside the installed app | Complete installer; app-led tablet setup and repair; USB-C, Wi-Fi, input, screenshots, and Files |
| macOS 14+ on Apple silicon | Native SwiftUI/AppKit desktop app | **Start Setup** inside the app | App-led tablet setup and repair; current package is unsigned and not notarized |
| ARM64 Linux on the tablet | Small helpers and Xovi extensions | Not a desktop platform | Shared tablet components used by both desktop apps |

The native screens are not pixel-for-pixel identical, but both guide the same
owner-approved stages and install the same pinned tablet prerequisite set.

## Tablet compatibility

The current target is:

- reMarkable Paper Pro Move;
- code name `chiappa`;
- beta software `3.28.0.164`; and
- OS build `5.8.199`.

This is the development target, not a promise of compatibility with every
Paper Pro Move firmware. Compare the tablet model and software version with the
matching release notes before choosing **Start Setup** or repair.

Other reMarkable models have different framebuffers, input devices, and system
layouts. They are not supported by the current setup transaction.

## Windows

The installed app requires Windows 11 x64 build `22621` or newer. The complete
installer installs the native app and its packaged setup payload. First-time
tablet work then starts only when the owner clicks **Start Setup** in Mirror.

The app first proves an existing authorization and checks the installed tablet
components. A current setup goes directly to the manual USB-C/Wi-Fi chooser.
Otherwise, the app authorizes a dedicated SSH key with the one-time Developer
Mode root password, installs and verifies the shared tablet payload, and
prepares Wi-Fi SSH before returning to that chooser.

Building the entire package from source practically requires Windows 11 `23H2`
or newer because the Files extension build uses Docker Desktop with Linux
containers. See [Windows setup](GETTING_STARTED.md).

## macOS

The native Mac app targets Apple silicon and macOS 14 or newer. Current source
targets Xcode 26, Swift 6, and the pinned Go release. The development package is
unsigned and not notarized.

The Mac app uses the same app-led contract as Windows: direct USB verification,
recognition of an already-current setup, dedicated key authorization only when
needed, the shared tablet transaction, Wi-Fi preparation, then a manual
connection choice. The controls remain native to macOS rather than imitating
WinUI.

The app does not automate Developer Mode, its reset, account sign-in, the first
unlock, USB approval, or entering the generated root password. See
[macOS setup](macos/GETTING_STARTED.md).

## Linux

The repository builds two dependency-free static Linux ARM64 programs:

- `rmmirror-probe`; and
- `rmmirror-transport-wake`.

It also builds the `rmmirror-files-loopback` Xovi extension with a pinned
cross-toolchain. These run on the reMarkable; there is no Linux desktop app.

## Evidence boundary

A successful build proves compilation for that exact target. It does not prove
pairing, installation, wake, mirroring, input, Files, firmware compatibility,
or uninstall behavior on a physical tablet.

The new app-led first-time setup paths require their own fresh-tablet physical
acceptance before a public release. Do not infer macOS compilation or physical
acceptance from this document; those results must be recorded only after the
exact command or path is exercised.

See [Development](DEVELOPMENT.md) for build commands,
[Tablet setup internals](DEVICE_SETUP.md) for the shared transaction, and
[What Mirror changes](TABLET_CHANGES.md) for the installed footprint.
