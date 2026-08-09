# What Mirror changes

Read this before running `Install.cmd`. Mirror is not a normal app-only install:
it adds software and credentials to a reMarkable in Developer Mode.

## On the Windows account

First-time setup creates or stores:

- a dedicated passphrase-free Ed25519 private key at
  `%USERPROFILE%\.ssh\remarkable_chiappa_ed25519`;
- a pinned tablet host identity at
  `%USERPROFILE%\.ssh\remarkable_known_hosts`;
- a protected wake token under the current user's `.ssh` directory;
- a current-user device profile under Local AppData;
- the Windows app and its matching runtime dependencies; and
- for development packages, a release-specific certificate in
  **Local Machine > Trusted People**.

The private key authenticates as tablet root. Protect it as a root credential.
Mirror never stores the tablet root password or Wi-Fi password.

## On the tablet

The complete Windows installer:

- appends the dedicated public key to `/home/root/.ssh/authorized_keys`;
- installs `/home/root/.local/bin/rmmirror-probe`;
- installs a pinned Xovi runtime under `/home/root/xovi`;
- activates `framebuffer-spy.so`, `xovi-message-broker.so`, and
  `rmmirror-files-loopback.so`;
- moves active `qt-resource-rebuilder.so` and `webserver-remote.so` into Xovi's
  inactive extensions directory and removes their associated Xochitl service
  configuration;
- installs `rmmirror-transport-wake` and its systemd service;
- installs the USB suspend guard;
- stores a root-owned wake token at `/data/rmmirror/wake-token`; and
- enables reMarkable's Developer Mode SSH-over-WLAN setting with
  `rm-ssh-over-wlan on`.

The installer checks the exact Paper Pro Move input devices and stops if the
expected hardware is absent. It modifies only the active A/B root slot. A
firmware update can activate the other slot without these components.

## What runs at boot

The transport-wake service is present at boot so direct USB status and bounded
wake can work before encrypted home storage and SSH are ready. Its HTTP endpoint
listens only on tablet loopback and the fixed direct-USB address. It does not
listen on the tablet's Wi-Fi address.

Xovi is installed persistently but is not started by a Mirror boot hook. Mirror
starts it while preparing an owner-requested connection.

Touch, pen, keyboard, and their virtual devices are session-only. Mirror does
not install a persistent input service, Xochitl input dependency, udev rule, or
input boot hook. Closing or losing the session must restore stock physical
input.

## Network exposure

- Developer Mode root SSH is enabled over Wi-Fi.
- Files stays bound to tablet loopback and travels through authenticated SSH
  forwarding.
- The wake endpoint stays on loopback and direct USB, not Wi-Fi.
- Wi-Fi Mirror should be used only on a network you control.

## Sleep and firmware behavior

While a data-capable USB connection is qualified, the suspend guard and active
input lease are designed to keep an owner-selected session awake. They are not
an unconditional remote power-on mechanism. If Linux has already fully
suspended, press the tablet power button once, unlock it, and explicitly connect
again.

After a firmware or root-slot switch, do not blindly reinstall. First confirm
that the Mirror release explicitly supports the new software version. If it
does, connect and unlock over USB, then rerun that release's `Install.cmd`.

## Removal boundary

The transport package has a component-level removal mode, but the repository
does not yet provide one tested operation that reverses every host and tablet
change listed above. See [Uninstall status](UNINSTALL.md) before installing if
complete stock restoration is a requirement.
