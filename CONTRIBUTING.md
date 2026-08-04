# Contributing

Thanks for helping make reMarkable Mirror better.

## Before opening a change

- Search existing issues first.
- Keep personal tablet data, document names, network details, passwords, keys,
  tokens, captures, and diagnostic logs out of commits.
- Separate observed behavior from assumptions about reMarkable firmware.
- Do not claim a tablet path is tested unless you tested that exact path.
- Keep input session-only. Do not add persistent Xochitl or virtual-input boot
  hooks.

For security problems, use the private reporting path in [SECURITY.md](SECURITY.md)
instead of a public issue.

## Development setup

Follow [Development](docs/DEVELOPMENT.md). Before submitting a pull request:

```powershell
Push-Location mirror\agent
go test ./...
go vet ./...
Pop-Location

dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    -p:Platform=x64
```

Run the non-live focused PowerShell checks relevant to your change. A script with
`Live` in its name may contact or change a prepared tablet and is never a
casual test.

## Pull requests

A useful pull request explains:

- the user-visible problem;
- the chosen fix and why;
- which exact checks ran;
- whether a real tablet path was tested;
- screenshots for visual changes; and
- any behavior that has not been tested.

Keep changes focused. Update user-facing documentation in the same pull request
when behavior changes.

## Licensing

Contributions are accepted under `GPL-3.0-only`, the repository's project
license. Preserve third-party notices and SPDX identifiers. New dependencies
must have a clear redistributable license and be added to
`THIRD_PARTY_NOTICES.md`.
