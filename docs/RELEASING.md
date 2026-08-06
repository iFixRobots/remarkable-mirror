# Releasing

Official releases are built from a clean public commit and signed with the
iFixRobots package identity. The build uses .NET SDK 10.0.302 and Go 1.26.5;
the root `global.json`, Go module, CI workflow, and package builder enforce those
exact versions.

Every push to `main` also creates private GitHub Actions downloads for owner
review. A successful workflow proves that the installer and portable download
were built; it does not make either one a public release. Public releases still
follow the signing, source, and publishing steps below.

The installer Actions artifact contains only the versioned distribution ZIP;
the expanded staging directory is not uploaded beside it. The portable artifact
contains only its self-contained EXE.

No public binary version has been released yet.

## Before building

1. Reconcile user-facing documentation and `CHANGELOG.md`.
2. Run the agent tests and vet checks.
3. Run every non-live focused PowerShell check.
4. Build Debug and Release x64 Windows configurations.
5. Build the ARM64 companions and Files loopback extension twice and compare
   hashes.
6. Confirm `git status --short` is empty.
7. Prepare a corresponding-source archive for every GPL-covered binary that the
   release will distribute.
8. Confirm the complete public onboarding, Getting started, and Troubleshooting
   guides plus all three app screenshots are present. The builder must not
   fall back to a shorter guide.
9. Complete the published Getting started path on a fresh Windows account and a
   freshly reset supported tablet configuration.

## Build

Choose an explicit four-part MSIX version:

```powershell
.\scripts\Build-RemarkableMirrorPackage.ps1 -Version 1.YYMM.DD.BUILD
```

Official builds refuse a dirty tree. `release.json` must contain:

- the exact public source commit;
- `source_dirty: false`;
- the .NET SDK and host runtime reported by the build process;
- the exact Go toolchain reported by both ARM64 companion builds;
- the identity and version read from the packaged Windows App Runtime MSIX;
- package identity, publisher, version, architecture, and hash;
- certificate identity and hash;
- every tablet component version and hash;
- pinned Xovi release, runtime, generator, toolchain, notice, and license; and
- the honest onboarding and active-root installation boundaries.

## Verify

- Authenticode signature is valid.
- The MSIX manifest identity matches `release.json`.
- The packaged process helper reads its gated launcher payload from standard
  input and does not interpolate the payload into the outer `-EncodedCommand`.
- A long-argument round trip verifies that the process helper does not regress
  to a Windows command-length failure.
- The Release app DLL and EXE contain no rooted application CodeView path and
  no current repository or user-profile root. Debug builds retain symbols but
  are not release artifacts.
- The application MSIX contains its declared self-contained .NET runtime, while
  the release folder contains exactly one matching Windows App Runtime
  dependency.
- The MSIX and ZIP contain the project legal files and the exact restored
  Microsoft license/notice payload under `ThirdParty/Microsoft`.
- The ZIP contains one coherent release tree and no private keys or captures.
- The ZIP contains `ONBOARDING.md`, `GETTING_STARTED.md`,
  `TROUBLESHOOTING.md`, and the three referenced app screenshots.
  `ONBOARDING.md` starts from an already downloaded package and never tells the
  user to build that same package.
- README and Getting started screenshots contain no personal notebooks,
  handwritten content, credentials, network details, or background windows.
- The package is non-development after installation.
- The changed path is tested on a real tablet.
- Previously accepted window shape, Files motion, input, and screenshot behavior
  remain unchanged unless the release intentionally changes them.
- The corresponding-source archive contains the exact tagged Mirror repository,
  including build and installation scripts, plus source snapshots at the pinned
  commits for bundled Xovi and `rm-xovi-extensions` binaries.
- The source archive includes the notices, GPL license text, and exact toolchain
  references needed to rebuild the GPL-covered components.

## Publish

Tag the exact source commit. Attach the ZIP, MSIX, public certificate, and
`release.json` to the GitHub release. Attach the versioned corresponding-source
archive beside them. Publish SHA-256 values for the ZIP, MSIX, and source archive
plus the signing certificate fingerprint in the release notes. A publisher
common name or a manifest inside the download does not tell users where the file
came from.

Release notes must distinguish tested behavior from work that has not been
tested. A binary release is not complete until its corresponding source is
available from the same release.

Never publish an artifact built from a non-public source tree or a dirty tree.
Never upload the signing private key.
