# Privacy

reMarkable Mirror talks directly to your tablet.

## Data flow

The app connects to the tablet over USB or Wi-Fi. There is no iFixRobots account,
relay, analytics service, document index, or screenshot upload service.

Mirror handles these categories locally:

- live framebuffer pixels;
- pointer and keyboard input;
- document metadata needed to render the Files drawer;
- files explicitly imported or exported by the user;
- screenshots explicitly copied or saved;
- a protected device profile; and
- SSH and wake credentials stored outside the repository.

The native Mac candidate first proves that the same reMarkable remains attached
directly through one data-capable USB-C cable while it reads the tablet's SSH
identification. It then captures the public Ed25519 host key through system
OpenSSH and persists a dedicated Mac-side identity plus a non-secret pending
profile. Cable continuity does not prove ownership of the hardware; the pinned
SSH identity is the tablet trust anchor. The separately confirmed **Add This
Mac…** action repeats those exact direct-cable checks before appending the
dedicated public key and installing or
upgrading the tablet-side USB keep-awake service, including its wake lock and
sleep guard. It does not identify the Mac's Wi-Fi network in that action. Its
one-time root password is never saved; documents and the Wi-Fi password are not
read or changed. **Connection > Set Up Wi-Fi…** separately verifies the active
Wi-Fi connection without reading its name or requesting Location Services. The
Mac project uses one product target with no test, Preview/mock or QA runtime.
On 2026-08-08, one owner-started Mac USB-C connection reached Live on the
physical tablet, rendered its real frame, and retained its authenticated frame,
input and Files processes. Physical touch/pen effects, unlocked Files
operations, screenshots, deep-sleep wake and Wi-Fi remain unexercised.

## Local storage

The device profile is stored for the current Windows user. It contains connection
settings and paths to Mirror's credential files. It never stores the Wi-Fi
password. The tablet and Windows manage that password themselves.

On macOS, the profile and OpenSSH files live under the current user's
Application Support directory. The profile stores fixed relative credential
filenames, the pinned SSH fingerprint, pairing state and bounded capability
metadata. It does not contain the private key, public-key bytes, bearer token,
password, Wi-Fi network name, device identifier, personal address, or an absolute
credential path. Directories use `0700`; files use `0600`.

Only explicit Wi-Fi setup stores the protected Wi-Fi network-context secret and
wake token in the Data Protection Keychain. Direct USB-C does not use those
secrets. The current unsigned app has no proved Team Identifier
or Keychain access-group policy, so signed-package usability and persistence are
not claimed.

**Set Up Again…** removes Mirror-owned local profile, SSH and Keychain material.
That local reset does not remove the public key already authorized on the
tablet or disable Developer Mode SSH over Wi-Fi.

Clipboard screenshots use a temporary PNG file so they remain valid after the
app closes. Mirror does not automatically remove those files yet. You can delete
old Mirror PNGs from the Windows temporary directory.

Dragging a tablet document into Windows stages its PDF in Mirror's local app
cache only after Windows requests the file. Canceling before that request writes
nothing; partial or canceled work is removed immediately. After an accepted
drop, Mirror keeps the staged file for 15 minutes so the destination can finish
reading it. If the app closes first, abandoned drag files are removed after they
are a day old the next time Mirror opens.

## Logs

Application logs are designed to omit document contents, document filenames,
tokens, private keys, and Wi-Fi passwords. Upload failures record a result
category and numeric HTTP status instead of the local filename. A diagnostic
report can still reveal software versions, route state, timestamps, and local
network characteristics. Review diagnostics before posting them publicly.

The Mac candidate's copyable report is a bounded list of fixed event codes and
timestamps. It does not include raw route output, interface names, addresses,
absolute paths, host keys, SSH output, credentials, or tablet data.

## Release artifacts

The current Milestone 6 review artifact is the unsigned arm64 package
`artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`,
SHA-256
`0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
The archive audit passed and its packaged binary matches the installed unsigned
`0.2.0 (2)` app. Its executable has a linker-generated ad-hoc signature, but the
app bundle is not Developer ID signed. The package must contain no device
profile, key, token, capture, document, diagnostic report or personal network
value. It has not been notarized, hosted, exercised through persistent Mac
authorization, Live mirroring or USB-to-Wi-Fi handoff, or owner-accepted, and
it is not a public release.

Release builds disable Mirror-owned PDB/CodeView output. Before signing, the
package builder inspects the app DLL and EXE and stops if either embeds a rooted
application CodeView path or the current repository or Windows user-profile
root. The SDK-provided native apphost may retain its own framework build
provenance; it is not a path produced from this checkout. Debug builds keep
their symbols and should not be distributed as release packages.

## Network boundary

Setup enables Developer Mode root SSH over WLAN and creates a dedicated SSH key
so Mirror can reconnect without prompting. The key lives under the current
Windows user's `.ssh` directory. Windows limits the device profile and wake token
to that user. Anyone who obtains the SSH key can access the paired tablet as
root, so keep it private.

Mac setup creates a separate app-owned SSH key only after the direct USB-C cable
check passes, then pins the tablet host key with system OpenSSH. The same
cable-attached tablet must still be present afterward. **Add This Mac…** makes
the separate persistent changes:
it appends that public key after explicit confirmation and repeated exact-USB
checks, then installs or upgrades the tablet-side USB keep-awake service and
its sleep guard. **Connection > Set Up Wi-Fi…** separately enables and verifies Developer Mode
SSH over Wi-Fi. The private key has root-access sensitivity and must remain
private to that Mac account. The one-time root password is not stored, and
Mirror never requests or changes the Wi-Fi password.

Files and Wi-Fi wake access use bearer credentials on the tablet. Direct USB-C
status and wake are instead limited to the exact cable listener and the bounded
power-button-equivalent operation. Mirror does not expose either service
directly over Wi-Fi. Files travels through authenticated SSH. Use Wi-Fi Mirror
on your home Wi-Fi, not on public or guest Wi-Fi. If you do not control who can
join the network, use USB-C instead.
