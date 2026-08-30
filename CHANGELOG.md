# Changelog

## 0.2.3

- Windows setup now completes entirely over USB-C, matching macOS: Wi-Fi SSH
  is enabled over the cable, the nmcli-based discovery is gone, untested
  tablet software is recorded in diagnostics instead of blocking, and a ready
  profile can have no stored Wi-Fi route. The first manual Wi-Fi connect
  records the Windows network pairing.
- Fixed Windows first-time password pairing: the one-time password hand-off
  to OpenSSH deadlocked and every attempt was misreported as a rejected
  password. A stalled authorization now names itself instead of blaming the
  password.
- Added the guided setup walkthrough, document backup, and
  **Restore Backup…** to Windows.
- Windows connection probes now close with an orderly FIN instead of an RST,
  and setup attempts are spaced 1.5 s apart, so retries cannot wedge the
  tablet's SSH service.
- Setup failures on Windows name their failing stage: a Wi-Fi SSH listener
  or wake-endpoint problem no longer tells you to check the cable.
- Windows setup now records what it observed into the connection diagnostics:
  the authorization outcome, the tablet's reported model, software, and
  component versions, which setup path ran and why, installer results, and
  the profile state.
- Unplugging a live Windows mirror now says "Connection ended" with the route
  to re-choose, instead of an alarming "Couldn't open mirror" over a frozen
  stale frame. The last frame is cleared whenever the session is not live.
- A reset or replaced tablet is no longer a dead end on Windows: the
  identity-mismatch card offers **Set Up as New Tablet…**, which archives the
  previous pairing files (never deletes them) and starts first-time setup.
- The setup walkthrough stays reachable after setup on Windows via
  **Set Up Again…** on the idle chooser, so a backup can be made before a
  planned reset — matching macOS.
- Backup and restore now reach a Mirror-provisioned tablet: its stock USB web
  interface is loopback-only by Mirror's own design, so the service falls
  back to the same SSH tunnel the Files browser uses when the direct cable
  address does not answer.
- Windows secondary actions are outlined buttons instead of bare text, and
  Restore Backup… moved off the connection chooser into its own row that
  appears only when a local backup exists.
- The Windows Go tablet-binary build provisions its pinned toolchain via
  GOTOOLCHAIN and builds with that exact toolchain instead of failing on
  machines with a different Go.

## 0.2.2

- Added a guided setup walkthrough on macOS with a real backup step: every
  document is saved as `.rmdoc` to `~/Documents/reMarkable Backup` before the
  Developer Mode reset, and **Connection > Restore Backup…** puts documents
  back afterward.
- Setup now completes entirely over USB-C. No Wi-Fi network is needed;
  Wi-Fi SSH is enabled over the cable for later use.
- Untested tablet software versions are no longer blocked. The tested list
  moved to the README and platform docs, and untested versions are logged.
- Validated tablet software `3.27.1.0` end to end and fixed setup on tablet
  software without `nmcli`.
- macOS packaging signs with Developer ID when `MACOS_SIGNING_IDENTITY` is
  set, keychain storage works in unsigned builds, and setup failures name
  their cause in plain language.

## 0.2.1

- Added the native Windows and macOS apps.
- Added direct USB-C and local Wi-Fi mirroring for the reMarkable Paper Pro
  Move.
- Added session-only mouse, keyboard, pen, and eraser input.
- Added screenshots, PDF and EPUB import, PDF and RMDOC export, and the Files
  browser.
- Added app-led tablet setup and repair. Mirror handles the SSH key and tablet
  files without asking you to run commands.
- Added the portable Windows executable and Apple-silicon Mac DMG.
- Fixed Windows repair after a tablet firmware update.
- Fixed the Mac build so it respects the pinned Go toolchain selected by the
  caller.

Mirror connects only after you choose setup, USB-C, Wi-Fi, or repair. It does
not auto-connect or switch routes on its own.
