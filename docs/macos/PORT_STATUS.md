# macOS app status

reMarkable Mirror has a real native SwiftUI/AppKit app for Apple-silicon Macs.
It connects to the real tablet over authenticated SSH and shares the same
ARM64 Linux tablet components as the Windows app.

The current Mac download is an Apple-silicon DMG.

## Implemented

| Area | Current macOS behavior |
| --- | --- |
| Window and stage | Fixed compact native window with reversible Files reveal |
| Connection | **Connect USB-C** and **Connect Wi-Fi** with an entered IPv4 address; clickable Live route switching; no fallback, promotion, or automatic reconnection |
| Display | Versioned frame stream rendered through one Metal surface |
| Input | Session-only touch, pen, eraser, and keyboard forwarding |
| Screenshots | Copy to clipboard and Save As PNG |
| Files | Authenticated SSH forward to the tablet-loopback Files service |
| Import/export | PDF and DRM-free EPUB import; PDF and native RMDOC export |
| Credentials | Dedicated OpenSSH identity, pinned tablet host key, protected Wi-Fi context and wake secrets |
| Tablet setup | App-led **Start Setup**, password-backed **Authorize & Install**, explicit resume/repair, and the full shared prerequisite install |
| Diagnostics | Bounded connection-state report without document data or credentials |
| Cleanup | Generation-owned frame, input, Files, and wake work retired on disconnect or quit |

## Manual connection lifecycle

Launching the app, attaching a cable, or changing networks does not contact the
tablet.

- **Connect USB-C** starts one bounded direct-cable session and never selects
  Wi-Fi.
- **Connect Wi-Fi** first opens a local IPv4 prompt, then starts one Wi-Fi-only
  attempt bound to the current Wi-Fi context.
- Clicking the Live route status invokes the opposite existing action.
- Cable, network, frame, or input failure retires the current generation and
  returns to an actionable disconnected state.
- Files starts only after the owner opens Files.

One route generation owns every child process and publication. `Live` requires
a current frame and input session from that same generation.

## Setup boundary

**Start Setup** verifies direct USB, proves an existing Mac key, and checks the
installed tablet components. A current setup goes directly to the manual
connection chooser. Otherwise, **Authorize & Install** is the password-backed
owner boundary that authorizes the public key, installs the complete pinned
probe, Xovi/extension, Files loopback, and transport-wake payload, then prepares
Wi-Fi SSH. **Continue Setup** and **Repair Tablet Setup** resume or repair that
same flow; none runs automatically.

Developer Mode, its reset, the first post-boot unlock, USB approval, and the
owner's root-password authorization remain explicit prerequisites. Mac-specific
profile and Keychain state is not part of the shared tablet payload or copied
from Windows. Follow [macOS Getting started](GETTING_STARTED.md).

## Exercised behavior

Physical USB-C and manual-IP Wi-Fi runs have exercised Live route
switching, the real frame, input, screenshots, Files navigation, PDF
import/export, native RMDOC export, and clean owned-process shutdown. That
evidence belongs to the exact builds that were run.

Do not infer from it that these separate paths are complete:

- the complete app-led authorization, prerequisite installation/repair, and
  Wi-Fi-preparation flow on a fresh Developer Mode tablet;
- launch and Keychain persistence from a downloaded package;
- Finder drag-in and drag-out materialization;
- every pen/eraser/right-click variant;
- the exact fully suspended power event;
- runtime behavior on the minimum macOS 14 target; or
- complete uninstall and stock restoration.

## Build status

The Xcode project defines one `com.ifixrobots.ReMarkableMirror` product,
version `0.2.1 (3)`, for macOS 14 or newer. The configured GitHub Actions
workflow builds an arm64 DMG and ZIP with the exact
prerequisite payload, stable Xcode, and the repository's pinned Go toolchain.

See [Packaging](PACKAGING.md) for the two build commands.

## Documentation authority

Current connection, setup, and release behavior is defined by:

- [macOS Getting started](GETTING_STARTED.md);
- [Platform support](../PLATFORM_SUPPORT.md);
- [Architecture](../ARCHITECTURE.md); and
- [Releasing](../RELEASING.md).
