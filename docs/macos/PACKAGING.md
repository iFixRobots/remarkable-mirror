# Build the Mac app

Use an Apple-silicon Mac with Xcode 26, the Go version pinned in
`mirror/agent/go.mod`, PowerShell 7, and Docker Desktop.

From the repository root:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The build script creates the native app and bundles the tablet components it
needs. The package script checks that bundle and creates both files under
`artifacts/macos/package/`:

```text
reMarkable-Mirror-<version>-macOS-arm64.dmg
reMarkable-Mirror-<version>-macOS-arm64-unsigned.zip
```

The DMG is the file to share. Open it and drag **reMarkable Mirror** to
**Applications**.

To install a local build without packaging it:

```zsh
scripts/Install-RemarkableMirrorMac.sh
```

The local installer does not overwrite an existing copy. Quit Mirror and move
the old app aside first.
