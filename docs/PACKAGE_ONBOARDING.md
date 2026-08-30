# Start here

This guide is included with the complete Windows installer package. Extract the
whole package and keep its files together.

> [!WARNING]
> A tablet that is not already configured for Mirror requires reMarkable
> Developer Mode, which factory-resets the tablet and erases saved Wi-Fi
> networks. Verify your content first.

> [!IMPORTANT]
> This package targets the reMarkable Paper Pro Move (`chiappa`). Existing
> runtime readiness is capability-based. Installation and repair admit only
> the paired software targets in the release statement; do not combine a
> version from one pair with the build from another.

## Install the app

1. Verify the package source, SHA-256, and signing notes.
2. Extract every ZIP layer to a normal folder.
3. Double-click `Install.cmd`.
4. Accept the administrator and development-certificate prompts only after
   verifying the package.

The installer installs and opens Mirror on **Setup**. It waits for **Start
Setup** and does not contact or change the tablet before that click.

## Already configured?

Do not reset the tablet again. Connect it directly over USB-C, keep it awake
and unlocked, then click **Start Setup**. Mirror checks the existing key and
tablet components. If they are current, it opens **Connect USB-C** and
**Connect Wi-Fi** without a password or reinstall.

Use the preparation steps below only for a new or unconfigured tablet, or when
Mirror explicitly says authorization or installation is required.

## Prepare the tablet

1. Back up the tablet and confirm its content in an official reMarkable app.
2. Follow reMarkable's official
   [Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
   The tablet resets.
3. Complete first-run setup again, sign in, reconnect Wi-Fi, and wait for cloud
   restoration.
4. Complete the first physical unlock after boot.
5. Enable **Settings > General > Storage > USB web interface**.
6. Find the Developer Mode root password under **Settings > General > Help >
   About > Copyrights and Licenses**.

Mirror does not store that password. Enter the Wi-Fi password only on the
tablet.

## Run setup in Mirror

1. Connect the awake, unlocked tablet directly to the PC with a data-capable
   USB-C cable.
2. Click **Start Setup**.
3. Mirror checks for an existing complete setup. If it finds one, it opens the
   connection choices without reinstalling anything.
4. Otherwise, enter the one-time Developer Mode password when asked, choose
   **Authorize & Install**, and keep the tablet attached while Mirror finishes
   setup.
5. If asked, reconnect Wi-Fi on the tablet and choose **Continue Setup**.

You do not need to run SSH, PowerShell pairing, or tablet installation commands
yourself. The technical process is documented in
[Tablet setup internals](DEVICE_SETUP.md).

## Connect

1. Choose **Connect USB-C** and wait for the Live status.
2. Check Touch + Type, Pen, a screenshot, and Files while the tablet is
   unlocked.
3. Choose **Connect Wi-Fi**, enter the tablet's current Wi-Fi IPv4 address, and
   wait for **Live over Wi-Fi**.
4. Click the Live status whenever you want to switch routes.

Mirror tries only the action you select. Opening the app, attaching a cable, or
changing networks does not start setup or a connection. Mirror never falls
back, switches, or reconnects by itself.

## Before installation or repair

Mirror adds software and a dedicated host key to the tablet. A complete tested
one-click stock-restoration workflow does not exist yet. Read
[What Mirror changes](TABLET_CHANGES.md) and
[Uninstall status](UNINSTALL.md).

After a firmware or root-slot switch, first let Mirror inspect any existing
capabilities. Use **Repair Tablet Setup** only if components are missing and
this release lists the observed software/build pair as an install target.

If a step fails, stop at that step and use
[Troubleshooting](TROUBLESHOOTING.md). Do not disable strict host-key checking
or repeatedly retry without reading the error.
