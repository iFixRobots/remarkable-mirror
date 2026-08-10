# Windows setup

This is the first-time path for a reMarkable Paper Pro Move and the native
Windows 11 app. Mirror performs SSH pairing, tablet installation, verification,
and Wi-Fi preparation inside the app.

> [!WARNING]
> A tablet that is not already configured for Mirror requires reMarkable
> Developer Mode. Enabling it factory-resets the tablet, removes saved Wi-Fi
> networks, and weakens the normal secure-boot boundary. Verify your backup
> first.

> [!NOTE]
> The app-led setup path still needs a clean-Windows, freshly reset tablet
> acceptance run before the first public binary release. Stop and report any
> model, version, or result that does not match the release notes.

## Before you begin

You need:

- a reMarkable Paper Pro Move (`chiappa`) on a software version supported by
  the matching Mirror build;
- Windows 11 x64, build `22621` or newer, with an administrator account;
- [PowerShell 7.5 or newer](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows);
- Windows **OpenSSH Client** from **Settings > System > Optional features**;
- a direct data-capable USB-C cable; and
- a Wi-Fi network that allows the PC and tablet to reach each other.

Do not continue on another tablet model or firmware unless the release notes
explicitly support it. See [Platform support](PLATFORM_SUPPORT.md).

## 1. Install Mirror first

Obtain the complete Windows installer before resetting the tablet.

1. Download the installer ZIP from the repository's **Releases** page or the
   approved Windows installer artifact.
2. Verify the published SHA-256 and signing notes.
3. Extract the entire ZIP to a normal folder and keep its files together.
4. Double-click `Install.cmd`.
5. Accept the administrator and development-certificate prompts only after
   verifying the package source.

The installer installs and opens the Windows app. A fresh install without a
completed local profile shows **Setup** and waits. Tablet contact begins only
when you click **Start Setup**.

## Already configured? Try this first

Do not reset the tablet again.

1. Connect the awake, unlocked tablet directly over USB-C.
2. Open Mirror and click **Start Setup**.
3. Mirror proves the saved key, checks the installed tablet components, and
   refreshes this computer's protected local profile.
4. If everything is current, Mirror opens **Connect USB-C** and **Connect
   Wi-Fi** without asking for a password or reinstalling anything.

Continue with the reset path below only for a new or unconfigured tablet, or
when Mirror explicitly says authorization or installation is required.

## 2. Back up the tablet

1. Finish the tablet's normal first-run setup.
2. Confirm its model and software version are supported by this Mirror build.
3. Let reMarkable cloud sync finish.
4. Confirm your notebooks and documents appear in an official reMarkable
   desktop or mobile app.
5. Export anything that exists only on the tablet.

If the content is not safely available somewhere else, stop. Developer Mode
erases the tablet's local state.

## 3. Enable Developer Mode

Follow reMarkable's official
[Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
On supported tablet software, the setting is under:

**Settings > General > Paper Tablet > Software > Advanced > Developer Mode**

Read the warning, enable Developer Mode, and let the factory reset finish. This
is unrelated to Windows Developer Mode.

## 4. Prepare the reset tablet

After the reset:

1. Complete first-run setup again and sign in with the same reMarkable account.
2. Reconnect Wi-Fi on the tablet and wait until it says **Connected**.
3. Wait for cloud restoration and confirm the expected content returned.
4. Set or restore the passcode, then complete the first physical unlock after
   boot.
5. Enable **Settings > General > Storage > USB web interface**.
6. Find the Developer Mode root password under **Settings > General > Help >
   About > Copyrights and Licenses**.

Keep that password available for setup. Mirror uses it only for the current
authorization attempt and does not save it. Enter the Wi-Fi password only on
the tablet.

## 5. Let Mirror set itself up

1. Connect the tablet directly to the PC with the data-capable USB-C cable. Do
   not use a dock.
2. Keep the tablet awake and unlocked.
3. Open Mirror and click **Start Setup**.
4. Mirror checks the tablet first. If this computer is already authorized and
   the tablet components are current, Mirror opens the connection choices.
5. Otherwise, enter the one-time Developer Mode root password when asked and
   choose **Authorize & Install**. Leave the tablet attached while Mirror
   finishes setup.

Mirror creates one dedicated Ed25519 key, pins the tablet's SSH identity over
the direct cable, authorizes only that public key, installs the pinned tablet
payload, and enables Developer Mode SSH over Wi-Fi. You do not need to run SSH,
PowerShell pairing, or tablet installation commands yourself.

If Wi-Fi was not ready, reconnect it on the tablet and choose **Continue
Setup**. Interrupted setup remains stopped until you click the offered resume
or repair action; it never retries in the background.

Setup is complete when Mirror returns to **Connect USB-C** and **Connect
Wi-Fi**.

## 6. Connect over USB-C

1. Keep the cable attached and wake or unlock the tablet.
2. Choose **Connect USB-C**.
3. Wait for the Live status.
4. Test **Touch + Type**, **Pen**, and the screenshot button.
5. Open **Files** and confirm the library loads while the tablet is unlocked.

Files can wait for an unlock even when display and input are already Live.

## 7. Connect over Wi-Fi

1. Put the PC and tablet on the same Wi-Fi network that you control.
2. Find the tablet's current IPv4 address in its Wi-Fi details.
3. Choose **Connect Wi-Fi**, or click the Live USB status to switch.
4. Enter that IPv4 address and choose **Connect**.
5. Wait for **Live over Wi-Fi**.

Click **Live over Wi-Fi** to start the normal USB-C action. You may leave the
cable attached during a Wi-Fi attempt; Mirror checks only the route you chose.

Mirror never auto-discovers an address, falls back to another route, switches,
or reconnects by itself. Use Wi-Fi Mirror only on a network you control. Guest
or client-isolated networks usually block direct access.

## Repair and firmware updates

A tablet firmware update can activate the other A/B root slot without Mirror's
components.

1. Confirm that your Mirror release supports the new tablet software.
2. Connect the awake, unlocked tablet directly over USB-C.
3. Open Mirror and choose its explicit repair action.
4. Let the app reinstall and verify the same pinned payload.
5. Choose USB-C or Wi-Fi again when repair finishes.

Repair never runs automatically. A complete tested stock-restoration path does
not exist yet; see [Uninstall status](UNINSTALL.md).

## Important boundaries

- Opening Mirror, attaching a cable, or changing networks does not contact the
  tablet.
- Setup, connect, switch, resume, and repair begin only after an owner click.
- Mirror cannot enable Developer Mode, avoid its reset, sign into the tablet,
  enter a Wi-Fi password, approve USB, or bypass the tablet passcode.
- The root password is not stored. The dedicated private key is a root
  credential and must remain protected.
- Files stays on tablet loopback and travels through authenticated SSH.

For exact installed components, hashes, and recovery behavior, see
[Tablet setup internals](DEVICE_SETUP.md) and
[What Mirror changes](TABLET_CHANGES.md). For failures, see
[Troubleshooting](TROUBLESHOOTING.md).
