# Tablet setup reference

This is the compact operator reference. For a first installation, follow
[Getting started](GETTING_STARTED.md) from the top.

## Admission checklist

- supported reMarkable Paper Pro Move model and firmware;
- reMarkable Developer Mode enabled;
- first physical passcode unlock after the current boot completed;
- direct USB tablet address `10.11.99.1`;
- direct Windows address `10.11.99.11/27`;
- physical route `10.11.99.0/27`;
- dedicated key at `%USERPROFILE%\.ssh\remarkable_chiappa_ed25519`;
- pinned host key at `%USERPROFILE%\.ssh\remarkable_known_hosts`;
- **Settings > General > Storage > USB web interface** enabled; and
- tablet Wi-Fi rejoined and explicitly **Connected** after the Developer Mode
  reset.

Developer Mode factory-resets the tablet, deletes saved Wi-Fi networks, and
exposes root SSH. The generated root credential is under **Settings > General >
Help > About > Copyrights and Licenses**. Follow reMarkable's official
[Developer Mode documentation](https://developer.remarkable.com/documentation/developer-mode).

## Installation

The complete first setup uses the Windows package over direct USB. Keep the
tablet connected and past its first post-boot unlock while `Install.cmd`:

1. verifies the release metadata and staged assets;
2. validates the Paper Pro Move input devices;
3. installs the pinned Xovi runtime and three active extensions;
4. installs the capture/input probe;
5. installs and verifies the transport-wake service and USB suspend guard;
6. stores the protected wake token and host profile; and
7. enables and verifies Developer Mode SSH over Wi-Fi.

The detailed persistent footprint and compatibility side effects are in
[What Mirror changes](TABLET_CHANGES.md).

The Windows launcher owns SSH/SCP children through a gated Job Object and sends
its serialized payload over standard input. Do not move the remote script back
into `-EncodedCommand`; it can exceed Windows command-line limits.

## Runtime lifecycle

Launching Mirror performs no tablet probe or wake.

- **Connect USB-C** owns one bounded direct-cable attempt.
- **Connect Wi-Fi** reveals an IPv4 field, then owns one bounded attempt against
  the submitted address.
- The selected route is pinned to its frame, input, wake, and Files generation.
- Failures retire that generation and return to manual choices.
- There is no background route monitor, fallback, promotion, or reconnection.
- Clicking the Live status delegates to the opposite existing manual action.
- Files starts only when the owner opens Files.

Virtual input is session-only. No input service, Xochitl boot dependency, udev
rule, or persistent input hook is installed.

## Wi-Fi boundary

Mirror never needs the Wi-Fi password. Wi-Fi use requires the tablet and host
on the approved paired network, the dedicated key and pinned identity, Developer
Mode SSH-over-WLAN, and an awake Wi-Fi radio.

The entered IPv4 address selects only the explicit attempt. It does not replace
the pinned tablet identity or paired Windows network checks. Files remains on
tablet loopback and travels through SSH forwarding.

## Firmware updates

The tablet uses A/B root slots. An update can activate a root without the
matching Mirror components.

1. Confirm the release supports the new software version.
2. If it does not, stop and report the version.
3. If it does, connect and unlock over USB.
4. Run that release's `Install.cmd` again.
5. Reopen Mirror and explicitly choose a connection.

Automatic root-slot repair is not implemented. Complete stock removal is also
not yet supported; see [Uninstall status](UNINSTALL.md).
