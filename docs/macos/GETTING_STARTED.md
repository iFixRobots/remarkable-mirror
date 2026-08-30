# macOS setup

## What you need

- An Apple-silicon Mac running macOS 14 or newer
- A reMarkable Paper Pro Move
- A data-capable USB-C cable

## Install Mirror

1. Download [`reMarkable-Mirror-0.2.2-macOS-arm64.dmg`](https://github.com/iFixRobots/remarkable-mirror/releases/download/v0.2.2/reMarkable-Mirror-0.2.2-macOS-arm64.dmg).
2. Open the DMG and drag **reMarkable Mirror** to **Applications**.
3. Open Mirror. macOS blocks the first launch because the app is not
   notarized: click **Done** (not Move to Trash), open **System Settings >
   Privacy & Security**, scroll to the bottom, click **Open Anyway** next to
   reMarkable Mirror, then confirm **Open Anyway** in the prompt.

## Already set up?

Do not reset the tablet again.

1. Connect the awake, unlocked tablet directly over USB-C.
2. Open Mirror and click **Start Setup**.
3. Mirror checks the saved key and installed tablet files.
4. Choose **Connect USB-C** or **Connect Wi-Fi**.

## New setup

Open Mirror and click **Start Setup**. The walkthrough guides every step below
in order; the notes here are the same guidance in document form.

1. **Back up.** Turn on **Settings > Storage > USB web interface**, connect
   the cable, and click **Back Up Tablet**. Mirror saves every document as
   `.rmdoc` under `~/Documents/reMarkable Backup/`.
2. **Enable Developer Mode** using reMarkable's
   [guide](https://developer.remarkable.com/documentation/developer-mode).
   This factory-resets the tablet.
3. After the reset, sign in again, reconnect Wi-Fi, and skip any software
   update it offers.
4. Unlock the tablet once after it starts.
5. Turn **Settings > Storage > USB web interface** back on — the reset
   switches it off.
6. Find the Developer Mode password under **Settings > General > Help >
   About > Copyrights and Licenses**.
7. Connect the tablet directly to the Mac over USB-C, keep it awake and
   unlocked, and click **Start Setup**.
8. Enter the password when asked and choose **Authorize & Install**. When
   macOS asks to allow Mirror to find devices on the local network, click
   **Allow** — that permission is how Mirror reaches the tablet.
9. Choose **Connect USB-C** or **Connect Wi-Fi**.

Setup runs entirely over the cable. Wi-Fi is optional and only needed when
you later choose **Connect Wi-Fi**. Setup is tested on reMarkable software
`3.27.1.0`, `3.28.0.164`, and `3.28.0.166`; other versions are not blocked.

Mirror uses the password for that authorization attempt and does not save it.

To put backed-up documents back on the tablet after setup, use **Connection >
Restore Backup…** with the cable connected and the USB web interface on. The
tablet places restored documents in its home screen.

## Connect over Wi-Fi

Put the Mac and tablet on the same network, open the tablet's Wi-Fi details,
and copy its IPv4 address into Mirror. Mirror connects only when you choose
**Connect Wi-Fi**.

## If something goes wrong

Keep the tablet awake and unlocked, reconnect it directly over USB-C, and use
the action Mirror shows. After a tablet software update, that may be **Repair
Tablet Setup**.

See [macOS troubleshooting](TROUBLESHOOTING.md), [supported tablet software](../PLATFORM_SUPPORT.md),
and [what Mirror changes](../TABLET_CHANGES.md) for the details.
