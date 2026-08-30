# Privacy

reMarkable Mirror talks directly to your tablet over USB-C or your local
network. The app makes no other network connections.

## Data the app handles

Mirror handles these categories on the local host:

- live framebuffer pixels;
- pointer, pen, and keyboard input;
- document metadata needed for the Files pane;
- files you explicitly import or export;
- screenshots you explicitly copy or save;
- a protected device profile; and
- SSH and wake credentials.

The app does not need the tablet's Wi-Fi password. Enter that password only on
the tablet.

## Windows storage

The Windows setup uses:

```text
%USERPROFILE%\.ssh\remarkable_chiappa_ed25519
%USERPROFILE%\.ssh\remarkable_known_hosts
%USERPROFILE%\.ssh\remarkable_chiappa_wake_token
%LOCALAPPDATA%\ReMarkableMirror\device-profile.json
```

The dedicated private key authenticates as tablet root and must remain private.
The device profile stores bounded connection metadata and protected credential
references, not the root password or Wi-Fi password.

An IPv4 address entered after **Connect Wi-Fi** is used for that explicit
attempt and resulting session. Editing it does not rewrite the persistent paired
profile. Diagnostics record a route kind and fixed result category, not the
entered address.

Clipboard screenshots use a temporary PNG so the clipboard remains valid after
the app closes. Mirror does not yet guarantee immediate deletion of every copied
screenshot. Files dragged out to Explorer are staged in the app cache only when
Windows requests the payload; partial work is removed, and stale completed
staging files are swept on later launches.

## macOS storage

The macOS app keeps its profile and OpenSSH files under:

```text
~/Library/Application Support/com.ifixrobots.ReMarkableMirror/
```

Directories use mode `0700`; files use mode `0600`. The profile does not contain
the private-key bytes, bearer token, password, Wi-Fi name, raw network
identifier, or an absolute credential path.

Only explicit Wi-Fi setup stores the paired network-context secret and wake
token in the Data Protection Keychain. Direct USB-C does not use those secrets.

**Set Up Again…** removes Mirror-owned local Mac profile, SSH, and Keychain
material. It does not remove the authorized tablet key or disable tablet Wi-Fi
SSH, and it does not uninstall the tablet prerequisite components. Removing the
app bundle has the same tablet-side limitation.

## Network boundary

Owner-approved host setup authorizes a dedicated key. Persistent Wi-Fi setup
separately enables and verifies Developer Mode root SSH over Wi-Fi. Anyone who
obtains that private key can access the paired tablet as root.

- Use Wi-Fi Mirror only on a network you control.
- Use USB-C on public, guest, or shared networks.
- Files stays on tablet loopback and is reached through authenticated SSH
  forwarding.
- The wake endpoint listens only on tablet loopback and the fixed direct-USB
  address; it does not listen on the tablet's Wi-Fi address.
- The tokenless USB wake capability is limited to the verified direct cable and
  bounded status/power-button-equivalent operations.

## Logs and diagnostics

Application logs are designed to omit:

- document contents and filenames;
- screenshots;
- root and Wi-Fi passwords;
- private keys and public-key bytes;
- wake tokens;
- raw SSH output; and
- a Wi-Fi address entered for a manual attempt.

Upload failures use a result category and numeric HTTP status instead of the
local filename. Diagnostics can still reveal app/tablet software versions,
route state, timestamps, and local network characteristics. Review every report
before posting it publicly.

## Release artifacts

Release packages must not contain device profiles, keys, tokens, captures,
documents, diagnostics, or personal network values. Release Windows builds
disable Mirror-owned PDB/CodeView output, and the package builder scans the app
binary for rooted checkout or user-profile paths.

Those checks cover the product's own output; they do not make an arbitrary
local Debug build safe to distribute. Verify release archives separately from
source.

## Deletion and uninstall

Removing the desktop app does not remove every credential or tablet component.
There is not yet a complete tested stock-restoration workflow. See
[Uninstall status](UNINSTALL.md) and [What Mirror changes](TABLET_CHANGES.md).

Never publish keys, tokens, root passwords, unreviewed diagnostics, or tablet
content while requesting support.
