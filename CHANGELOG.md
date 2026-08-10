# Changelog

Notable user-visible changes are recorded here. No public binary version has
been released yet.

## Unreleased

### Added

- Native desktop apps for Windows and macOS. Both connect over authenticated
  SSH and can install or repair the same pinned ARM64 Linux prerequisites on
  the reMarkable tablet through their own host-native setup flows.
- Manual USB-C and Wi-Fi connection actions. Wi-Fi accepts the tablet's IPv4
  address only after the owner chooses that route.
- Clickable Live status for deliberate route switching. Windows displays
  **Live over USB**; macOS displays **Live over USB-C**; both display **Live
  over Wi-Fi**.
- Session-only touch, keyboard, pen, and eraser input.
- Clipboard and Save As screenshots.
- A Files pane for PDF and DRM-free EPUB import, PDF and native RMDOC export,
  and deferred Explorer or Finder drag-out.
- A complete Windows installer and app-led setup path, plus a self-contained
  portable Windows executable with the same embedded setup payload.
- An unsigned native Apple-silicon development build whose **Start Setup** flow
  can authorize the Mac and install or repair the full tablet prerequisite set.

### Changed

- Launch, cable attachment, and network changes are passive. Mirror contacts
  the tablet only after an explicit setup, connection, or repair action. Wi-Fi
  enablement is part of app-led setup; protected profile data remains
  host-specific.
- A connection attempt checks only the selected route. Mirror no longer falls
  back, promotes USB, or reconnects a retired session automatically.
- Files starts only after the owner opens its pane and remains behind an
  authenticated SSH tunnel to the tablet's loopback service.
- Frame, input, Files, and wake work is fenced to the selected connection
  generation and retired on failure, route change, or app shutdown.
- The compact desktop window keeps Files in a reversible side pane.

### Reliability and security

- Release builds omit Mirror-owned PDB/CodeView output and are scanned for
  rooted checkout and user-profile paths.
- Wi-Fi repair requires repeated authenticated evidence; one interrupted
  identity or capability check does not force repair.
- The tablet wake service listens only on loopback and direct USB, not on the
  Wi-Fi address. Files bearer traffic is never exposed directly on the LAN.
- Virtual input remains session-only. Mirror does not install a persistent
  input service, udev rule, or Xochitl input boot hook.
- Tablet helper and Files-extension builds are pinned and reproducible.

### Current release boundary

- The Windows development package uses a local self-signed identity, not a
  public publisher certificate.
- The macOS development build is unsigned and not notarized.
- Clean-account, freshly reset tablet acceptance for both host setup paths and
  a complete tested uninstall remain required before the first supported
  public binary release.
- Repository history and existing Actions artifacts must pass the privacy gate
  before repository visibility changes.
