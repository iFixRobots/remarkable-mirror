# Start here

You already have a reMarkable Mirror installer package. Keep every extracted
file and folder together.

> [!WARNING]
> First-time setup uses reMarkable Developer Mode, which factory-resets the
> tablet and erases saved Wi-Fi networks. Verify your content before enabling
> it.

> [!IMPORTANT]
> This package targets the reMarkable Paper Pro Move (`chiappa`) on beta
> `3.28.0.164`, OS build `5.8.199`. Stop if the model or software version does
> not match the support statement for this release.

The installed app requires Windows 11 x64 build `22621` or newer. Windows has
the complete installer and setup path. The native macOS app is currently an
unsigned development build, and its setup flow does not yet install every
tablet prerequisite.

## Read the complete guide

Open [GETTING_STARTED.md](GETTING_STARTED.md). It contains the exact path from
backup and Developer Mode through USB pairing, installation, and both manual
connections.

Do not skip the one-time SSH pairing. Before `Install.cmd` can prepare the
tablet, the current Windows account must have:

```text
%USERPROFILE%\.ssh\remarkable_chiappa_ed25519
%USERPROFILE%\.ssh\remarkable_known_hosts
```

The complete guide creates or safely reuses that dedicated key, pins the tablet
identity over direct USB, restricts the private-key ACL, installs only the
public key, and verifies key-only access. Inside that complete pairing block,
the tablet-side append is idempotent:

```shell
key=$(cat)
grep -qxF "$key" /home/root/.ssh/authorized_keys ||
    printf '%s\n' "$key" >> /home/root/.ssh/authorized_keys
```

## Installation checklist

1. Extract the entire release folder.
2. Back up and verify tablet content.
3. Enable reMarkable Developer Mode using the official guide.
4. After reset, sign in again, reconnect Wi-Fi, wait for cloud restoration,
   complete the first physical unlock, find the Developer Mode root password,
   and enable **USB web interface**.
5. Prepare PowerShell 7.5+ and Windows OpenSSH Client.
6. Pair the dedicated key over the direct USB-C network by following
   `GETTING_STARTED.md`.
7. Confirm the tablet still says Wi-Fi is **Connected**.
8. Return to this extracted folder and double-click `Install.cmd`.
9. Accept the administrator/certificate prompt only after verifying the package
   source and hashes.
10. Keep the tablet connected and unlocked until setup finishes.

The installer adds more than a desktop app. It installs the tablet probe, Xovi
runtime and extensions, Files loopback, transport-wake service, USB suspend
guard, protected wake token and device profile, then enables Developer Mode SSH
over Wi-Fi. It does not store the tablet root password or Wi-Fi password.

There is no complete tested one-click stock-restoration workflow yet. Read
[TABLET_CHANGES.md](TABLET_CHANGES.md) and [UNINSTALL.md](UNINSTALL.md) before
installation.

## First connection

Launch waits without contacting the tablet.

1. Choose **Connect USB-C** and wait for **Live over USB**.
2. Check Touch + Type, Pen, and a screenshot.
3. Unlock the tablet, open Files, send a small PDF and a DRM-free EPUB, and
   confirm a human-named PDF appears in Explorer when dragged out. The drag
   should begin immediately.
4. Use the document menu and confirm **Save native RMDOC...** is available.
5. Click **Live over USB**. Only then does the IP address field appear.
6. Enter the tablet's current Wi-Fi IPv4 address and wait for
   **Live over Wi-Fi**.
7. Click **Live over Wi-Fi** to start the USB-C switch.

Mirror checks only the route you select. It never switches or reconnects by
itself.

![Mirror preparing the selected connection](images/remarkable-mirror-preparing.png)

## If something fails

Stop at the first failed step and use the bundled
[Troubleshooting guide](TROUBLESHOOTING.md). Do not disable strict host-key
checking or repeatedly rerun the installer without understanding the error.

After a firmware/root-slot switch, rerun this release only if its support notes
explicitly include the tablet's new software version.
