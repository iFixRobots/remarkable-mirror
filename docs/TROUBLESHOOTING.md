# Troubleshooting

For first setup, keep the Getting started guide included with your host package
open and stop at the first failed step. Both native apps can install or repair
the same tablet prerequisite set through different explicit setup flows. The
visible Mirror state is more useful than repeatedly rerunning setup or starting
the same connection again.

## USB does not create the direct tablet network

First-time setup requires a verified direct USB connection. With the tablet
connected through a data-capable USB-C cable, Windows should show
`10.11.99.11/27` and the tablet should answer as `10.11.99.1`.

Check Windows:

```powershell
Get-NetIPAddress -IPAddress 10.11.99.11 -AddressFamily IPv4
Get-NetRoute -DestinationPrefix 10.11.99.0/27
```

If both are missing:

1. make sure the cable carries data;
2. connect the tablet directly instead of through a dock;
3. wake the tablet and complete the first passcode unlock after boot;
4. unplug and reconnect USB once; and
5. check Windows Device Manager for a disabled or failed USB network adapter.

Do not try to do first-time setup over Wi-Fi. The selected host setup must
verify the tablet over direct USB before it changes anything.

On macOS, use a direct Mac port and choose **Start Setup** or **Retry Setup**.
The app verifies the exact cable context before authorization; do not replace
that check with a manually entered IP.

## Setup cannot pin the tablet identity

An open TCP port alone is not enough. First pairing needs a real SSH host-key
response from the unlocked Developer Mode system.

- Confirm the direct USB addresses above.
- Wake the tablet.
- Complete its first passcode unlock after the current boot.
- Confirm Developer Mode is still enabled.
- Return to Mirror and choose its explicit setup retry once.

Mirror performs the host-key scan and pinning. Do not run a replacement manual
pairing flow or disable strict host-key checking to make this symptom
disappear.

## A Mirror SSH key already exists

This usually means setup was started before. Mirror safely reuses a valid
dedicated private key and derives its public key again. The normal Windows
paths are:

```powershell
$key = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'
```

Choose **Start Setup** or the offered resume action. The app reuses and proves
the key before installing anything. Do not create another key just to bypass a
host-identity mismatch.

If Mirror reports that the connected tablet does not match the pinned identity
and you reset or replaced the tablet yourself, choose **Set Up as New
Tablet…** on that card. Mirror archives the previous pairing files into a
dated folder next to them, keeps the dedicated key, and starts first-time
setup for the connected tablet.

If you did not reset or replace the tablet, or you do not know where the
private key came from, stop. Preserve the key and known-hosts file and ask for
support. Never delete, move, or publish them while diagnosing setup.

## A manual connection could not start

Mirror checks the tablet only after you choose a connection.

- For USB-C, connect a data-capable cable, wake or unlock the tablet, then choose
  **Connect USB-C**. That bounded attempt checks only the cable.
- For Wi-Fi, confirm the tablet and PC are on the paired Wi-Fi network, choose
  **Connect Wi-Fi**, enter the tablet's current IPv4 address, and choose
  **Connect**.
- During an active selected session, the USB carrier guard and input wake lease
  are designed to prevent the tablet from reaching full suspend.
- If Linux already completed suspend before Mirror could reach it, press its
  power button once. There is no source-proven host wake guarantee from that
  terminal state.
- Complete the first post-boot passcode unlock.

Launch, cable changes, and network changes never start, switch, or reopen a
connection. A Wi-Fi attempt confirms an authenticated component mismatch once
inside that owner action before showing **Repair**. A direct USB setup failure
still appears immediately.

While Live, click **Live over USB** to enter a Wi-Fi address, or click
**Live over Wi-Fi** to start the bounded USB-C action. These are the same manual
actions shown while disconnected; the status does not add another connection
system.

## Repair tablet setup

A tablet update may have removed the components Mirror installed.

First let Mirror inspect the existing installation. If the runtime capabilities
are complete, a firmware change alone does not require repair. If components
are missing, confirm that the release lists the observed software/build pair as
an install target, connect and unlock over USB-C, then choose **Repair Tablet
Setup** in the matching Windows or Mac build. Both apps invoke the same
tablet-side prerequisite transaction; neither runs automatically. Do not use an
ordinary connection **Retry** until setup finishes.

The installer publishes the transport service's ordinary-boot dependency under
`/usr/lib/systemd/system` instead of the tablet's volatile `/etc` overlay.
Automatic repair after a future root-slot switch is not implemented.

## Mirror is Live but Files says connect

Files is independent from display and input.

1. Unlock the tablet.
2. Enable **Settings > General > Storage > USB web interface** on the tablet.
3. Leave the Files drawer open during its owner-requested readiness window, or
   choose **Try Files Again** after that window ends.

The tablet turns off Files while it is passcode-locked. Unlock it and Mirror
can complete the still-open Files request without reopening the route.

## Files says "Couldn't send"

1. Unlock the tablet and wait for the Files library to load.
2. Use a PDF or DRM-free EPUB no larger than 100 MB.
3. Choose **Retry** once after Files is ready.

If the same file still fails, copy the diagnostic details and include them in a
bug report after reviewing them. Mirror omits the local document filename from
upload diagnostics, but the report can still contain software versions,
timestamps, and local network details. DRM-protected EPUB files are not
supported by the tablet.

## Frames update but controls do not

Mirror retires that selected session instead of reopening it. Confirm touch
works directly on the tablet, then explicitly choose **Connect USB-C** or
**Connect Wi-Fi** again. For Wi-Fi, submit the tablet's current IPv4 address.
If physical input restoration could not be confirmed, restart the tablet and
reopen Mirror before trying either route.

Do not repeatedly launch multiple Mirror instances. Include the app's copied
diagnostic details in a bug report after checking them for local network details.

## The tablet asks for its passcode after an apparent sleep screen

The screen can keep showing a sleep image while the tablet is still starting.
Enter the passcode on the tablet, or through Mirror once input appears, to finish
unlocking it.

## Wi-Fi stopped after Developer Mode setup

Developer Mode's factory reset removes saved Wi-Fi networks. Reconnect from the
tablet UI. If the tablet can scan networks but has no saved profile, no Windows
repair command can supply the missing Wi-Fi password.

## Package installation fails

Current source sends the gated launcher payload through standard input rather
than embedding the long tablet setup script in the Windows command line. If an
older package reports a command-line length or launcher-start failure, use a
newer package built from current source instead of retrying the same extracted
files.

- For the current packaged build, download the installer from
  [`v0.2.1`](https://github.com/iFixRobots/remarkable-mirror/releases/tag/v0.2.1)
  and verify its published SHA-256.
- Use **remarkable-mirror-windows-installer** from a successful **Build Windows
  downloads** Actions run only when testing a newer, unreleased commit.
- A Release download is already the installer ZIP. An Actions download contains
  the versioned installer ZIP inside the GitHub artifact; extract both layers
  before running `Install.cmd`.
- Use the complete installer when you want a normal Windows installation. The
  portable app carries the setup payload, but it does not install
  Windows prerequisites, app registration, or the package certificate.
- Use PowerShell 7.5 or newer.
- Keep the MSIX, certificate, dependency package, installer, and `components`
  directory together.
- Do not mix files from different releases.

A visible publisher name does not prove where a file came from. Compare the
SHA-256 and certificate fingerprint with the release notes and inspect
`release.json`. Current development packages use a release-specific self-signed
certificate that setup adds to **Local Machine > Trusted People**; that is not
a public code-signing identity.

## After a firmware update

Let Mirror inspect the existing runtime first. If the newly active root lacks
components, confirm that the release lists its software/build pair as an
install target, connect and unlock over USB-C, then choose **Repair Tablet
Setup** in the matching Windows or Mac build. Automatic OTA repair is not ready
yet.

## Reporting a problem

Use the GitHub issue form for ordinary bugs. Use private vulnerability reporting
for security problems. Never post tablet passwords, SSH keys, wake tokens,
document contents, or unreviewed diagnostics.
