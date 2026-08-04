# Device setup reference

For a first installation, use [Getting started](GETTING_STARTED.md). It is the
canonical end-to-end guide and includes the Windows tools, exact commands,
screenshots, install path, and success checklist.

This page is the shorter tablet-side reference for people who already know the
project.

## Required tablet state

- reMarkable Paper Pro Move in Developer Mode
- first passcode unlock after the current boot completed
- direct USB address `10.11.99.1`
- Windows direct USB address `10.11.99.11/27`
- dedicated key at `%USERPROFILE%\.ssh\remarkable_chiappa_ed25519`
- pinned host key at `%USERPROFILE%\.ssh\remarkable_known_hosts`
- **Settings > General > Storage > USB web interface** enabled
- tablet rejoined to Wi-Fi after the Developer Mode reset

Developer Mode setup, SSH trust, and public-key installation are documented in
[Pair one dedicated SSH key](GETTING_STARTED.md#7-pair-one-dedicated-ssh-key).

## Developer Mode facts that matter here

- Enabling it factory-resets the tablet.
- The reset deletes saved Wi-Fi networks.
- The root username and generated password are under **Settings > General >
  Help > About > Copyrights and Licenses**.
- SSH over Wi-Fi is off by default.
- Mirror's installer enables reMarkable's `rm-ssh-over-wlan on` setting.
- Full Linux suspend disconnects Wi-Fi and cannot be woken by a packet that
  cannot reach the radio.

For the tablet's own Developer Mode steps, follow reMarkable's
[Developer Mode documentation](https://developer.remarkable.com/documentation/developer-mode).

## Install the tablet pieces

The first setup must use the direct USB route. Keep the tablet connected and
unlocked while `Install.cmd` installs the matching probe, Xovi
runtime and extensions, Files loopback, and transport wake component.

Touch, pen, and keyboard input are session-only. Mirror starts them when a
connection is ready. They are not persistent tablet boot hooks.

## Use Wi-Fi

Mirror never needs the Wi-Fi password. Enter it only on the tablet. Wireless
Mirror requires:

- the tablet connected to the paired trusted network;
- root SSH-over-WLAN enabled by the installer;
- the dedicated SSH key and pinned host identity; and
- a tablet state where the Wi-Fi radio is awake.

The stock Files service is not exposed directly on Wi-Fi. Mirror reaches the
tablet-local listener through authenticated SSH forwarding.

## After firmware updates

The tablet uses A/B root slots. A firmware update can switch to a root without
the package-matching components. If the app shows **Repair**:

1. confirm that the release explicitly supports the tablet's new software
   version;
2. if it does not, stop and report the new version;
3. if it does, connect over USB-C;
4. complete the first post-boot unlock;
5. run `Install.cmd` from that supported release again; and
6. reopen Mirror after setup finishes.

Running the installer again is supported. Automatic repair after every future
root-slot change is not ready yet.
