# macOS packaging

The macOS app is a native SwiftUI/AppKit application. Current development
packages are arm64, unsigned, and not notarized. They are development builds,
not public releases.

## Build

Use an Apple-silicon Mac with stable Xcode 26 and the Go version pinned by the
repository:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The build script:

- selects the `ReMarkableMirror` scheme;
- builds the requested architecture for macOS 14 or newer;
- bundles the Linux ARM64 transport-wake component;
- verifies the bundle identifier, version, executable, and architectures; and
- leaves the build output unregistered with Launch Services.

The package script creates:

```text
artifacts/macos/package/reMarkable-Mirror-<version>-macOS-<architecture>-unsigned.zip
```

It stages a fresh app copy, validates the embedded tablet component and app
identity, creates one ZIP, extracts it again, and verifies the packaged app.

## Install a development build

For a local build:

```zsh
scripts/Install-RemarkableMirrorMac.sh
open "$HOME/Applications/reMarkable Mirror.app"
```

The local installer refuses to overwrite an existing app. Quit and move the
previous build aside before installing another one.

Because the current package is unsigned, macOS may require **Open** from the
Finder context menu. Do not present that bypass as the public installation
experience.

## Signing and notarization

The package script supports credentialed release hooks without storing
credentials in the repository:

```zsh
MACOS_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
MACOS_NOTARY_KEYCHAIN_PROFILE='remarkable-mirror-notary' \
scripts/Package-RemarkableMirrorMac.sh
```

When those variables are set, the script signs with hardened runtime, verifies
the signature, submits the app for notarization, waits for acceptance, and
staples the result before creating the final archive.

A public Mac artifact requires all of the following:

- Developer ID signature verification;
- successful Apple notarization and stapling;
- expected bundle identifier, version, and architecture;
- a SHA-256 published beside the download;
- matching public source and license notices;
- launch and connection testing from the packaged app; and
- release notes that state the current setup-prerequisite boundary.

The current Mac setup flow installs the transport-wake component but not every
tablet prerequisite. That installer limitation is separate from the native
app's ability to connect to the real tablet.

See [Development](../DEVELOPMENT.md) and
[Releasing](../RELEASING.md).
