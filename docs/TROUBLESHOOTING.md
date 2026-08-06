# Troubleshooting

If this is a first installation, keep [Getting started](GETTING_STARTED.md) open
and stop at the first failed step. The visible Mirror status is more useful than
repeatedly rerunning the installer or pressing **Retry**.

## USB does not create the direct tablet network

First-time setup requires the physical USB network. With
the tablet connected through a data-capable USB-C cable, Windows should show
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

Do not try to do first-time setup over Wi-Fi. The installer must see the tablet
over USB before it changes anything.

## SSH host scan returns nothing

An open TCP port alone is not enough. First pairing needs a real SSH host-key
response from the unlocked Developer Mode system.

- Confirm the direct USB addresses above.
- Wake the tablet.
- Complete its first passcode unlock after the current boot.
- Confirm Developer Mode is still enabled.
- Run only the `ssh-keyscan.exe` command from Getting started again.

Do not disable strict host-key checking to make this symptom disappear.

## A Mirror SSH key already exists

This usually means setup was started before. Do not overwrite the private key.
Set the normal paths:

```powershell
$key = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'
```

If you know the private key was created for Mirror, reuse it. Run step 7 in
Getting started from its first code block. That block derives a fresh `.pub`
file from the private key instead of trusting an old public side file. The next
direct-USB scan refreshes the tablet host key before the public key is installed
again, which is the correct path after a factory reset.

Do not test against stale host trust after a factory reset, and do not create
another key just to bypass the mismatch.

If you do not know where the private key came from, stop. Move the key, its
`.pub` file if present, and the known-hosts file to a private backup location
before starting pairing again. Never delete or publish them while diagnosing
setup.

## Connect or wake your reMarkable

Mirror cannot reach your tablet right now.

- Connect USB-C for the most direct recovery path.
- Wake the tablet physically if it entered full Linux suspend.
- Complete the first post-boot passcode unlock.
- For Wi-Fi, confirm the tablet and PC are on the same Wi-Fi network.

Deep suspend disconnects Wi-Fi. A network packet cannot reach a disconnected
radio; physical power or USB is the expected recovery path.

## Repair tablet setup

A tablet update may have removed the components Mirror installed.

First confirm that the release explicitly supports the tablet's current
software version. If it does not, stop and report the version. If it does,
connect and unlock over USB-C, then run that supported release's `Install.cmd`
again. Do not use **Retry** until setup finishes.

The installer publishes the transport service's ordinary-boot dependency under
`/usr/lib/systemd/system` instead of the tablet's volatile `/etc` overlay.
Automatic repair after a future root-slot switch is not implemented.

## Mirror is Live but Files says connect

Files is independent from display and input.

1. Unlock the tablet.
2. Enable **Settings > General > Storage > USB web interface** on the tablet.
3. Leave the Files drawer open for a few seconds or choose refresh.

The tablet turns off Files while it is passcode-locked. Unlock it and Mirror
will reconnect Files automatically.

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

Mirror should discard the stale connection and reconnect automatically. If it
shows **Retry**, select it once. If the controls still do not work, close
Mirror, confirm touch works on the tablet, and reopen it.

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

- For the current private build, download
  **remarkable-mirror-windows-installer** from a successful
  **Build Windows downloads** run in this repository's Actions tab.
- Extract the GitHub artifact, then extract the versioned installer ZIP inside
  it before running `Install.cmd`.
- Do not use the portable `ReMarkableMirror.exe` for first-time setup. It does
  not install the tablet components or create the Windows device profile.
- Use PowerShell 7.5 or newer.
- Keep the MSIX, certificate, dependency package, installer, and `components`
  directory together.
- Do not mix files from different releases.

For a public release, a visible publisher name such as `CN=iFixRobots` does not
show where the file came from. Download it from this repository's GitHub
Releases page, compare the SHA-256 and certificate fingerprint with the release
notes, and confirm the Authenticode signature is valid. The installer also
checks the package identity, publisher, version, and file hash against
`release.json`.

## After a firmware update

First confirm that the release explicitly supports the tablet's new software
version. If it does not, stop and report the new version. If it does, connect
and unlock over USB-C, then run that supported release's `Install.cmd` again.
Automatic OTA repair is not ready yet.

## Reporting a problem

Use the GitHub issue form for ordinary bugs. Use private vulnerability reporting
for security problems. Never post tablet passwords, SSH keys, wake tokens,
document contents, or unreviewed diagnostics.
