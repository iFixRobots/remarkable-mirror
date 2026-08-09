# Uninstall status

Mirror does **not** yet have a tested one-click uninstall that returns both the
host and tablet to stock state.

This is a release blocker, not a hidden procedure. Do not improvise root-level
removal commands from this page.

## What can be removed locally

Windows can remove the installed app through **Settings > Apps > Installed
apps**. The macOS development build can remove its app bundle, and
**Set Up Again…** can
remove Mirror-owned local Mac pairing state.

Those actions do not undo tablet changes. Removing the desktop app also does
not necessarily remove:

- the Windows SSH key and pinned host file;
- the protected wake token and device profile;
- a development package certificate trusted by Windows;
- the Mac public key already authorized on the tablet; or
- Developer Mode SSH-over-WLAN on the tablet.

Do not delete a private key until you understand whether it is still the only
way to administer the paired tablet.

## Tablet removal is incomplete

The transport-wake installer can remove its own service, binary, sleep guard,
and boot link. That component removal intentionally preserves
`/data/rmmirror/wake-token` so reinstalling does not silently break a paired
host.

There is no packaged, end-to-end verified removal for all of the following:

- the dedicated entry in `/home/root/.ssh/authorized_keys`;
- `rmmirror-probe`;
- the pinned Xovi runtime and Mirror extensions;
- the extensions Mirror moved to Xovi's inactive directory;
- the Wi-Fi SSH setting;
- the wake token;
- host profiles and credentials; and
- the Windows trust certificate and package state.

Because those pieces interact with Xochitl, systemd, active root slots, and
Developer Mode access, an incomplete manual removal can leave the tablet
unbootable, inaccessible, or only partly restored.

## If you need to stop using Mirror now

1. Quit Mirror so its frame and input sessions retire.
2. Remove the desktop app using the host's normal app-removal UI.
3. Keep the tablet and host credentials private.
4. Do not publish diagnostics, keys, tokens, or root passwords.
5. If stock restoration is required, wait for a release that explicitly ships
   and verifies a complete removal workflow, or use reMarkable's official
   recovery/support path.

Factory-reset behavior and Developer Mode exit behavior are owned by reMarkable,
not by this project. Follow current official instructions for those operations.

The full installed footprint is documented in
[What Mirror changes](TABLET_CHANGES.md).
