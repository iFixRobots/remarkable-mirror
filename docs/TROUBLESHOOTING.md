# Troubleshooting

## Connect or wake your reMarkable

Mirror has no reachable authenticated route yet.

- Connect USB-C for the most direct recovery path.
- Wake the tablet physically if it entered full Linux suspend.
- Complete the first post-boot passcode unlock.
- For Wi-Fi, confirm the tablet is connected to the paired local network.

Deep suspend disconnects Wi-Fi. A network packet cannot reach a disconnected
radio; physical power or USB is the expected recovery path.

## Repair tablet setup

The app reached the tablet but the current active root does not have matching
prerequisites. This commonly follows a firmware A/B root-slot switch.

Connect and unlock over USB-C, then run `Install.cmd` from the same release again.
Do not use **Retry** until setup finishes.

## Mirror is Live but Files says connect

Files is independent from display and input.

1. Unlock the tablet.
2. Enable **General settings > Storage > USB web interface** on the tablet.
3. Leave the Files drawer open for a few seconds or choose refresh.

Xochitl deliberately closes its web service while passcode-locked. The existing
SSH forward remains safe and the app detects the listener after unlock.

## Frames update but controls do not

Current releases revoke **Live** when their input child disappears and perform at
most one cleanup-proved retry. Choose **Retry** if the app asks. If the condition
persists, close Mirror once, verify physical tablet touch works, then reopen it.

Do not repeatedly launch multiple Mirror instances. Include the app's copied
diagnostic details in a bug report, after reviewing them for local network data.

## The tablet asks for its passcode after an apparent sleep screen

An E-ink sleep image does not prove the tablet finished booting or that encrypted
home storage is available. Enter the passcode on the tablet or through Mirror
once input becomes available. Mirror treats this state neutrally rather than
claiming a reboot cause.

## Wi-Fi stopped after Developer Mode setup

Developer Mode's factory reset removes saved Wi-Fi networks. Reconnect from the
tablet UI. If the tablet can scan networks but has no saved profile, no Windows
repair command can supply the missing Wi-Fi password.

## Package installation fails

- There is no official public binary release yet. Build a development package
  from this source rather than trusting an unofficial download.
- Extract the full ZIP before running `Install.cmd`.
- Use PowerShell 7.5 or newer.
- Keep the MSIX, certificate, dependency package, installer, and `components`
  directory together.
- Do not mix files from different releases.

For a future official package, do not treat the visible publisher name
`CN=iFixRobots` as proof by itself. Confirm that the download came from this
repository's GitHub Releases page, compare its SHA-256 and certificate
fingerprint with the values published on that release, and then confirm the
Authenticode signature is valid. The installer also checks package identity,
publisher, version, and file hash against `release.json`, but an internal
manifest cannot establish the origin of an untrusted download by itself.

## After a firmware update

Run the full installer again over unlocked USB. Manual active-root provisioning
is supported; automatic OTA repair is not yet claimed.

## Reporting a problem

Use the GitHub issue form for ordinary bugs. Use private vulnerability reporting
for security problems. Never post tablet passwords, SSH keys, wake tokens,
document contents, or unreviewed diagnostics.
