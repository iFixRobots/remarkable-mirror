# Contributing

Thanks for helping make reMarkable Mirror better.

## Know the platform boundaries

- **Windows 11 x64** has the native WinUI app and complete installer/setup path.
- **macOS on Apple silicon** has a real native SwiftUI/AppKit app. Current
  development builds are unsigned.
- **ARM64 Linux components** run on the reMarkable tablet and support both
  desktop apps. They are not a third desktop app.

See [Platform support](docs/PLATFORM_SUPPORT.md) before changing setup or
connection behavior.

## Before opening a change

- Search existing issues first.
- Keep tablet credentials, keys, tokens, document data, captures, diagnostics,
  device identifiers, and personal network details out of commits and issues.
- Separate observed behavior from assumptions about reMarkable firmware.
- Do not claim a tablet path is tested unless you tested that exact path.
- Keep input session-only. Do not add persistent Xochitl or virtual-input boot
  hooks.

For security problems, use the private reporting path in [SECURITY.md](SECURITY.md)
instead of a public issue.

## Build and test

Follow [Development](docs/DEVELOPMENT.md) for the pinned toolchains and complete
commands. Run the checks for every component you changed.

The tablet-side Go checks run on Windows, macOS, or Linux:

```text
cd mirror/agent
go test ./...
go vet ./...
```

Build the Windows host on Windows:

```powershell
dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    -p:Platform=x64
```

Build the macOS host on Apple silicon:

```zsh
scripts/Build-RemarkableMirrorMac.sh
```

Run the non-live policy checks relevant to your change. A PowerShell script with
`Live` in its name may contact or change a tablet; never run
one as a routine check.

## Pull requests

A useful pull request explains:

- the user-visible problem;
- the chosen fix and why;
- the exact host OS, commands, and checks that ran;
- whether a physical tablet path was tested, including model, firmware, and
  USB-C or Wi-Fi route;
- screenshots for visual changes; and
- any behavior that has not been tested.

Keep changes focused. Update user-facing documentation in the same pull request
when behavior changes.

## Licensing

Contributions are accepted under `GPL-3.0-only`, the repository's project
license. Preserve third-party notices and SPDX identifiers. New dependencies
must have a clear redistributable license and be added to
`THIRD_PARTY_NOTICES.md`.
