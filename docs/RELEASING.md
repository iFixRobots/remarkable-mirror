# Make a release

reMarkable Mirror ships two files people can open directly:

- `ReMarkableMirror-Windows-x64-portable.exe`
- `reMarkable-Mirror-<version>-macOS-arm64.dmg`

The Windows installer ZIP is useful too, but the portable EXE is the simplest
download to share.

## 1. Pick the version

Update the Mac version in two places that must match:

- `MARKETING_VERSION` in
  `mirror/macos/ReMarkableMirror.xcodeproj/project.pbxproj`
- the expected product identity check in
  `.github/workflows/package-macos.yml`

The Windows package uses its four-part MSIX version separately.

## 2. Build Windows

On Windows 11 with the toolchain from [Development](DEVELOPMENT.md):

```powershell
$version = "1.$(Get-Date -Format yyMM).$([int](Get-Date -Format dd)).1"
.\scripts\Build-RemarkableMirrorPackage.ps1 -Version $version
```

The portable EXE is written under `artifacts\remarkable-mirror\`.

## 3. Build macOS

On an Apple-silicon Mac:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The DMG is written under `artifacts/macos/package/`.

## 4. Check the files

Before uploading them:

- open the Windows EXE on Windows;
- open the DMG, drag Mirror to Applications, and open that copy;
- confirm both apps show the version you expect;
- confirm the Mac app is arm64;
- calculate SHA-256 hashes for the exact files you will upload; and
- make sure the README links use those exact filenames.

On macOS:

```zsh
shasum -a 256 artifacts/macos/package/*
```

On Windows:

```powershell
Get-FileHash artifacts\remarkable-mirror\ReMarkableMirror-Windows-x64-portable.exe -Algorithm SHA256
```

## 5. Publish

Create the GitHub release, attach the EXE, DMG, checksum file, and corresponding
source archive, then read the release page once as someone who has never seen
the project. The download and setup path should be obvious without reading the
source tree.
