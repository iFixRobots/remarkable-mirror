# Releasing

This project has no public binary release yet. A green build is necessary, but
it is not enough to publish software that changes a tablet and installs trusted
host credentials.

## Release outputs

A release may contain four kinds of output:

| Output | Purpose | Public-release requirement |
| --- | --- | --- |
| Windows installer ZIP | Complete Windows app and first-time tablet provisioning | Stable publisher signature and clean-device acceptance |
| Windows portable EXE | App-only use after the installer/setup path | Authenticode signature and matching source |
| macOS app ZIP | Native SwiftUI/AppKit desktop app | Developer ID signing, notarization, and a clearly stated setup-prerequisite limit |
| Linux ARM64 components | Probe, transport wake, and Xovi Files extension for the tablet | Corresponding source and reproducible build metadata |

There is no Linux desktop package.

## Public-readiness gate

Before the first public release:

1. While the repository is still private, review every file for credentials,
   personal data, device identifiers, captures, private diagnostics, and rooted
   build paths.
2. Review the complete reachable Git history, not only the current tree. If a
   deleted or replaced blob contains private operator/device evidence, keep the
   repository private until the owner explicitly approves a cleaned publication
   history. Deleting a file from the tip is not history sanitization.
3. Inventory existing Actions artifacts and remove anything that should not
   become visible with the repository.
4. Exercise the published Windows Getting started path on a clean Windows
   account and a freshly reset, explicitly supported tablet.
5. Publish a tested uninstall or recovery-to-stock procedure for every
   persistent host and tablet change.
6. Replace the local self-signed Windows development identity with a stable
   public signing process.
7. Sign and notarize the macOS artifact. An unsigned build may remain a clearly
   labeled development artifact, but it is not a public-release download.
8. Publish an exact model and firmware support policy. Do not imply that any
   retail tablet version is supported.
9. Keep the current Mac setup-prerequisite limitation and the role of the
   tablet's ARM64 Linux components visible in the README and release notes.
10. Change repository visibility only after every earlier gate passes and the
   owner gives a separate explicit instruction.

## Build from a clean commit

Reconcile `CHANGELOG.md` and all user-facing documentation first. Then run:

```powershell
Push-Location mirror\agent
go test ./...
go vet ./...
Pop-Location

dotnet restore mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configfile mirror\windows\NuGet.config `
    --locked-mode

dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    --no-restore `
    -p:Platform=x64
```

Build the ARM64 companions and Files extension twice and compare their hashes.
Build the Windows Release package and the macOS Release package from the same
public commit.

The official Windows package command uses an explicit four-part MSIX version:

```powershell
$version = "1.$(Get-Date -Format yyMM).$([int](Get-Date -Format dd)).1"
.\scripts\Build-RemarkableMirrorPackage.ps1 -Version $version
```

Official builds must refuse a dirty tree. Do not use a development bypass for a
public artifact. Increment the final numeric component when rebuilding on the
same day.

On an Apple-silicon Mac:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

## Artifact verification

Verify each artifact independently:

- the version and source commit are exact and the source tree was clean;
- Windows Authenticode and MSIX identities match the published signer;
- the macOS app has the expected bundle identity, architecture, signature, and
  notarization result;
- packaged hashes match `release.json` and the published checksums;
- all tablet binaries are static Linux AArch64 objects with recorded versions
  and hashes;
- the ZIP has one coherent root and contains no private keys, tokens, profiles,
  captures, diagnostics, rooted user paths, or signing material;
- legal files, third-party notices, license payloads, and corresponding source
  are present;
- `ONBOARDING.md`, `GETTING_STARTED.md`, `TROUBLESHOOTING.md`,
  `PLATFORM_SUPPORT.md`, `TABLET_CHANGES.md`, and `UNINSTALL.md` match the
  release behavior;
- screenshots contain no personal documents, handwriting, network details, or
  unrelated windows; and
- the portable executable starts from an empty working directory with the
  correct window and taskbar icon.

`release.json` should identify the source commit, toolchains, package identity,
publisher, version, architecture, certificate, bundled runtime, tablet
component versions, Xovi/toolchain pins, and hashes. It must say
`source_dirty: false`.

## Physical acceptance

Compilation and package inspection do not prove the device path. On the exact
supported tablet and firmware, exercise:

- first provisioning from the published Windows package;
- manual USB-C connection from an idle launch;
- manual Wi-Fi connection using the entered address;
- both directions of the clickable Live route switch;
- display, Touch + Type, Pen, screenshot, and owner-opened Files;
- physical wake after deep suspend;
- close/unload cleanup with no owned process left behind; and
- reinstall or recovery after a supported firmware/root-slot change.

Record failures and untested paths in the release notes. Do not translate
partial evidence into a broader support claim.

## Corresponding source

Every GPL-covered binary must ship with corresponding source from the exact
release inputs. The source archive must include:

- the tagged Mirror repository;
- build and installation scripts;
- the pinned Xovi and `rm-xovi-extensions` source snapshots needed for bundled
  binaries;
- notices and GPL license text; and
- exact toolchain references needed to rebuild the components.

## Publish

Create the release from the exact tagged public commit. Attach the Windows
installer ZIP, portable EXE, signed/notarized macOS ZIP when available,
`release.json`, public signing material that users need for verification, and
the corresponding-source archive.

Publish SHA-256 checksums and signing fingerprints in the release notes. State
which host/tablet combinations were physically exercised and which were not.

Never publish a dirty-tree artifact, private signing key, unreviewed Actions
artifact, or binary whose corresponding source is unavailable.
