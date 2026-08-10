# macOS development build

The native SwiftUI/AppKit app mirrors a real reMarkable Paper Pro Move over
authenticated USB-C or Wi-Fi. The current Mac package is an unsigned,
unnotarized development build.

> [!WARNING]
> A tablet that is not already configured for Mirror requires reMarkable
> Developer Mode. Enabling it
> factory-resets the tablet, removes saved Wi-Fi networks, and weakens the
> normal secure-boot boundary. Back up and verify your content first.

> [!NOTE]
> The app-led Mac setup path has not yet completed a separately authorized
> fresh-tablet physical acceptance run. Do not treat this guide as evidence of
> a public, signed, or independently accepted Mac release.

## Before you begin

You need:

- an Apple silicon Mac running macOS 14 or newer;
- a reMarkable Paper Pro Move (`chiappa`) on a software version supported by
  the matching Mirror build;
- a direct data-capable USB-C cable; and
- a Wi-Fi network that allows the Mac and tablet to reach each other.

Do not continue on another tablet model or firmware unless the release notes
explicitly support it. See [Platform support](../PLATFORM_SUPPORT.md).

## 1. Install Mirror first

Obtain the matching development package before resetting the tablet.

1. Verify the package source, SHA-256, and release notes.
2. Extract the package and move `reMarkable Mirror.app` into Applications.
3. Because the app is unsigned, use Finder's **Open** action if macOS asks you
   to confirm it.

Contributors can build and install from source by following
[Development](../DEVELOPMENT.md) and [Mac packaging](PACKAGING.md). This guide
does not claim a Mac build succeeded unless that exact build was run and
reported separately.

On a clean app install, Mirror shows **Setup** and waits for **Start Setup**.

## Already configured? Try this first

Do not reset the tablet again.

1. Connect the awake, unlocked tablet directly over USB-C and approve the USB
   accessory if macOS asks.
2. Open Mirror and click **Start Setup**.
3. Mirror proves this Mac's saved key and checks the installed tablet
   components.
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

Read the warning, enable Developer Mode, and let the factory reset finish.

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

1. Connect the tablet directly to the Mac with the data-capable USB-C cable.
2. Approve the USB accessory if macOS asks, then keep the tablet awake and
   unlocked.
3. Open Mirror and click **Start Setup**.
4. Mirror checks the tablet first. If this Mac is already authorized and the
   tablet components are current, Mirror opens the connection choices.
5. Otherwise, enter the one-time Developer Mode root password when asked and
   choose **Authorize & Install**. Leave the tablet attached while Mirror
   finishes setup.

Mirror creates one dedicated Ed25519 key, pins the tablet's SSH identity over
the direct cable, authorizes only that public key, installs the pinned tablet
payload, and enables Developer Mode SSH over Wi-Fi. You do not need to run SSH
or tablet installation commands yourself.

If Wi-Fi was not ready, reconnect it on the tablet and choose **Continue
Setup**. Interrupted setup remains stopped until you click the offered resume
or repair action; it never retries in the background.

Setup is complete when Mirror returns to **Connect USB-C** and **Connect
Wi-Fi**.

## 6. Connect over USB-C

1. Keep the cable attached and wake or unlock the tablet.
2. Choose **Connect USB-C**.
3. Wait for the Live status before using **Touch + Type** or **Pen**.
4. Open **Files** and confirm the library loads while the tablet is unlocked.

One click owns the bounded USB-C attempt. It does not inspect, select, or fall
back to Wi-Fi.

## 7. Connect over Wi-Fi

1. Put the Mac and tablet on the same Wi-Fi network that you control.
2. Find the tablet's current IPv4 address in its Wi-Fi details.
3. Choose **Connect Wi-Fi**, or click **Live over USB-C** to switch.
4. Enter that IPv4 address and choose **Connect**.
5. Wait for **Live over Wi-Fi**.

Click **Live over Wi-Fi** to start the normal USB-C action. Mirror checks only
the route you chose. It does not discover or save the address, wake the tablet
over Wi-Fi, fall back to USB-C, or reconnect by itself.

Use Wi-Fi Mirror only on a network you control. Files stays on tablet loopback
and travels through authenticated SSH forwarding.

## Repair and local reset

If a supported tablet component is missing or a firmware update activates a
new A/B root slot:

1. Confirm that your Mirror build supports the tablet software.
2. Connect the awake, unlocked tablet directly over USB-C.
3. Choose **Repair Tablet Setup**.
4. Let Mirror reinstall and verify the same pinned payload.
5. Choose USB-C or Wi-Fi again when repair finishes.

Repair never runs automatically.

**Set Up Again…** removes Mirror-owned local profile, SSH, and Keychain
material from the Mac. It does not remove the authorized public key or tablet
components, disable tablet Wi-Fi SSH, or restore the tablet to stock. See
[Uninstall status](../UNINSTALL.md).

## Important boundaries

- Opening Mirror, attaching a cable, or changing networks does not contact the
  tablet.
- Setup, connect, switch, resume, repair, and local reset require owner clicks.
- Mirror cannot enable Developer Mode, avoid its reset, sign into the tablet,
  enter a Wi-Fi password, approve USB, or bypass the tablet passcode.
- The root password is not stored. The dedicated private key is a root
  credential and must remain protected.
- Full Linux suspend can still require one physical power-button press, an
  unlock, and another explicit connection.

Use **Help > Copy Connection Diagnostics** for a sanitized event summary, then
review it before sharing. For failures, see
[macOS troubleshooting](TROUBLESHOOTING.md). For exact setup internals and
persistent changes, see [Tablet setup internals](../DEVICE_SETUP.md) and
[What Mirror changes](../TABLET_CHANGES.md).
