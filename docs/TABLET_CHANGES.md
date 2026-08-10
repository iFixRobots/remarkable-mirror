# What Mirror changes

Read this before choosing **Start Setup** or **Repair Tablet Setup**. Mirror is
not a normal app-only install: the owner-started flow adds software and one
host credential to a reMarkable in Developer Mode.

Installing or opening the desktop app does not change the tablet. The changes
below begin only after the owner starts setup or repair over direct USB-C and,
for first authorization, submits the one-time Developer Mode root password.

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

## On the Mac account

The native Mac setup stores its dedicated OpenSSH identity and profile under:

```text
~/Library/Application Support/com.ifixrobots.ReMarkableMirror/
```

Setup stores its protected network-context secret and wake token in the Data
Protection Keychain. Those values are Mac-specific; they are not copied from
the Windows profile. The current Mac package is unsigned and not notarized.

## On the tablet

The owner-authorized Windows and macOS setup paths both invoke the same
tablet-side prerequisite transaction. Together with the native host's key and
Wi-Fi finalization, Mirror:

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
- enables reMarkable's Developer Mode SSH-over-WLAN setting.

The shared transaction is staged as exactly nine release-pinned assets and
verifies every SHA-256 before mutation. Windows and macOS use different native
adapters but do not carry separate tablet installation bodies. See
[Tablet setup internals](DEVICE_SETUP.md).

The installer checks the Paper Pro Move model, supported software build, and
exact input devices before it changes the tablet. It modifies only the active
A/B root slot. A firmware update can activate the other slot without these
components.

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
does, connect and unlock over USB, then choose **Repair Tablet Setup** in the
matching Windows or Mac build.

## Removal boundary

The transport package has a component-level removal mode, but the repository
does not yet provide one tested operation that reverses every host and tablet
change listed above. See [Uninstall status](UNINSTALL.md) before installing if
complete stock restoration is a requirement.

Removing either desktop app, or choosing **Set Up Again…** on macOS, does not
remove the authorized tablet key, shared tablet components, wake token, or
Wi-Fi SSH setting.
