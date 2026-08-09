# macOS app status

reMarkable Mirror has a real native SwiftUI/AppKit app for Apple-silicon Macs.
It connects to the real tablet over authenticated SSH and shares the same
ARM64 Linux tablet components as the Windows app.

Current packages are unsigned development builds. This page records product
status, not a release or support promise.

## Implemented

| Area | Current macOS behavior |
| --- | --- |
| Window and stage | Fixed compact native window with reversible Files reveal |
| Connection | **Connect USB-C** and **Connect via Wi-Fi** with an entered IPv4 address; clickable Live route switching; no fallback, promotion, or automatic reconnection |
| Display | Versioned frame stream rendered through one Metal surface |
| Input | Session-only touch, pen, eraser, and keyboard forwarding |
| Screenshots | Copy to clipboard and Save As PNG |
| Files | Authenticated SSH forward to the tablet-loopback Files service |
| Import/export | PDF and DRM-free EPUB import; PDF and native RMDOC export |
| Credentials | Dedicated OpenSSH identity, pinned tablet host key, protected Wi-Fi context and wake secrets |
| Diagnostics | Bounded connection-state report without document data or credentials |
| Cleanup | Generation-owned frame, input, Files, and wake work retired on disconnect or quit |

## Manual connection lifecycle

Launching the app, attaching a cable, or changing networks does not contact the
tablet.

- **Connect USB-C** starts one bounded direct-cable session and never selects
  Wi-Fi.
- **Connect via Wi-Fi** first opens a local IPv4 prompt, then starts one
  Wi-Fi-only attempt bound to the current Wi-Fi context. Persistent Wi-Fi setup
  is separate and does not gate this path.
- Clicking the Live route status invokes the opposite existing action.
- Cable, network, frame, or input failure retires the current generation and
  returns to an actionable disconnected state.
- Files starts only after the owner opens Files.

One route generation owns every child process and publication. `Live` requires
a current frame and input session from that same generation.

## Setup boundary

The app can create a Mac-specific SSH identity, authorize it over verified
direct USB, and install the transport-wake component. Its current setup flow
does not install the probe, Xovi runtime, and Files extension set.

Run the complete Windows installer once to install those tablet prerequisites,
then follow [macOS Getting started](GETTING_STARTED.md). This is a setup-tooling
gap, not a statement that the Mac app is a simulation or partial desktop app.

## Exercised behavior

Physical USB-C and manual-IP Wi-Fi development runs have exercised Live route
switching, the real frame, input, screenshots, Files navigation, PDF
import/export, native RMDOC export, and clean owned-process shutdown. That
evidence belongs to the exact development builds that were run.

Do not infer from it that these separate paths are complete:

- Developer ID signing and notarization;
- launch and Keychain persistence from a signed distributed package;
- persistent **Connection > Set Up Wi-Fi…** behavior;
- Finder drag-in and drag-out materialization;
- every pen/eraser/right-click variant;
- the exact fully suspended power event;
- runtime behavior on the minimum macOS 14 target; or
- complete uninstall and stock restoration.

## Build status

The Xcode project builds one `com.ifixrobots.ReMarkableMirror` product, version
`0.2.0 (2)`, for macOS 14 or newer. The configured GitHub Actions workflow
builds and audits an unsigned arm64 ZIP with stable Xcode and the repository's
pinned Go toolchain.

See [Packaging](PACKAGING.md) for commands and signing hooks. Compilation proves
the source and package can be constructed; it is not physical-tablet or release
proof.

## Documentation authority

Private implementation checkpoints and owner/device evidence belong in the
internal operator repository, not the public product documentation. The old
development journals are removed from the current tree, but reachable Git
history must still pass the privacy gate before this repository becomes
public. Current connection, setup, and release behavior is defined by:

- [macOS Getting started](GETTING_STARTED.md);
- [Platform support](../PLATFORM_SUPPORT.md);
- [Architecture](../ARCHITECTURE.md); and
- [Releasing](../RELEASING.md).
