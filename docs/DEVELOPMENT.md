# Development

This page is for contributors. To install and use Mirror, start with
[Getting started](GETTING_STARTED.md).

Mirror has two native desktop apps and a set of tablet components:

| Target | Runs on | Toolchain |
| --- | --- | --- |
| Windows host | Windows 11 x64 | .NET 10, WinUI 3, PowerShell 7.5 |
| macOS host | Apple silicon, macOS 14+ | Xcode 26, Swift, Go |
| Tablet components | Linux ARM64 on the Paper Pro Move | Go and the pinned Xovi toolchain |

There is no Linux desktop host. The Linux outputs are tablet companions used by
the Windows and macOS apps.

## Get the source

```powershell
git clone https://github.com/iFixRobots/remarkable-mirror.git
Set-Location remarkable-mirror
```

Do not put tablet passwords, SSH keys, wake tokens, profiles, captures,
diagnostics, signing keys, document names, or personal network details in the
repository. Keep generated output in ignored directories.

## Toolchains

The repository pins .NET in `global.json` and Go in `mirror/agent/go.mod`.
Use the pinned versions rather than relying on compatible roll-forward behavior.

### Windows

Use Windows 11 x64 with:

- Visual Studio and the **WinUI application development** workload;
- the pinned .NET SDK;
- the pinned Go release;
- PowerShell 7.5 or newer;
- Windows OpenSSH Client; and
- Docker Desktop with Linux containers when building the Xovi Files extension.

Microsoft's current WinUI workload can be installed with:

```powershell
winget configure -f https://aka.ms/winui-config
```

Verify the local tools from PowerShell 7:

```powershell
$PSVersionTable.PSVersion
dotnet --version
go version
Get-Command ssh.exe, scp.exe, ssh-keygen.exe, ssh-keyscan.exe
docker version --format '{{.Server.Version}}'
```

The Windows SDK supplied by Visual Studio must include x64 `makeappx.exe` and
`signtool.exe` before you build an MSIX package.

### macOS

Use an Apple-silicon Mac with stable Xcode 26, the pinned Go release, and the
Xcode command-line tools. The build script defaults to
`/Applications/Xcode.app` and produces an arm64 app unless another supported
architecture is requested explicitly.

## Validate shared and tablet code

Run the Go suite from the repository root:

```powershell
Push-Location mirror\agent
go test ./...
go vet ./...
Pop-Location
```

Build the two deterministic Linux ARM64 companions:

```powershell
.\scripts\Build-RemarkableMirrorAgent.ps1 -Force
.\scripts\Build-RemarkableTransportWake.ps1 -Force
```

These are static AArch64 ELF binaries for the tablet. They are not a Linux
desktop application.

Build the Xovi Files loopback extension with Docker Desktop running Linux
containers:

```powershell
.\scripts\Build-RemarkableFilesLoopback.ps1 -Force
```

The builder pins its toolchain image and Xovi generator. Review ABI and license
changes before updating either pin.

## Build the Windows host

Restore only the locked dependency graph, then build x64 Debug:

```powershell
dotnet restore mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configfile mirror\windows\NuGet.config `
    --locked-mode

dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    --no-restore `
    -p:Platform=x64
```

Build the self-contained portable executable with:

```powershell
$project = 'mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj'
$nugetConfig = 'mirror\windows\NuGet.config'

dotnet restore $project `
    --configfile $nugetConfig `
    --locked-mode `
    -p:PublishProfile=win-x64-portable.pubxml

dotnet publish $project `
    --configuration Release `
    --no-restore `
    -p:PublishProfile=win-x64-portable.pubxml `
    -o artifacts\remarkable-mirror-portable
```

The portable executable can run Mirror, but it cannot prepare a new tablet.
First-time provisioning belongs to the complete installer package described in
[Getting started](GETTING_STARTED.md).

For a local development package, use a unique identity and a clearly local
publisher:

```powershell
$identity = ([guid]::NewGuid().ToString('D')).ToUpperInvariant()
$version = "1.$(Get-Date -Format yyMM).$([int](Get-Date -Format dd)).1"
.\scripts\Build-RemarkableMirrorPackage.ps1 `
    -Version $version `
    -PackageIdentity $identity `
    -Publisher 'CN=Local Mirror Build'
```

Development packages are self-signed. Installing one changes the Windows trust
store and should never be presented as a public release.

## Build the macOS host

On the Mac:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The default build is an unsigned arm64 app. Signing and notarization require
release credentials and are separate release steps.

The macOS app is a real native host. Its current setup flow installs only the
transport-wake prerequisite, not the probe and Xovi stack. Follow
[macOS Getting started](macos/GETTING_STARTED.md), and keep this installer gap
separate from claims about the app itself.

## Non-live policy checks

PowerShell scripts named `Test-RemarkableMirror*.ps1` are source and packaging
checks unless their name includes `Live`. Run checks relevant to the changed
policy. For the Windows connection lifecycle, run:

```powershell
.\scripts\Test-RemarkableMirrorManualConnectionPolicy.ps1
.\scripts\Test-RemarkableMirrorPassiveRouteProbe.ps1
.\scripts\Test-RemarkableMirrorPackageMetadata.ps1
```

Never run a `Live` script as routine validation. Live scripts may contact or
change a tablet and require explicit owner intent.

## Connection invariants

Keep these behaviors shared:

- App launch is network-inert.
- **Connect USB-C** checks only the direct cable.
- The Wi-Fi action first reveals an IPv4 field, then checks only that address.
- The clickable Live status delegates to the existing USB-C and Wi-Fi actions.
- A route generation owns its frame, input, wake, SSH, and Files work.
- Failure retires the generation and returns to manual choices.
- There is no background route monitor, fallback, promotion, or automatic
  reconnection.
- Files opens its SSH-forwarded service only after the owner opens Files.
- Entered addresses stay out of diagnostics and persistent profile data.

Windows labels the action **Connect Wi-Fi**; macOS labels it
**Connect via Wi-Fi**. On Mac, **Connection > Set Up Wi-Fi…** is a separate
optional persistent setup action and must not gate the manual IP path.

Reuse the proven transport, identity, cable, and wake mechanisms. Manual
admission is a gate in front of those mechanisms, not a replacement transport
stack.

## Tablet safety rules

- Keep virtual input session-only; never add persistent input or Xochitl boot
  hooks.
- Before every Mirror-owned Xochitl or Xovi start or restart, reset the
  `xochitl.service` systemd failure budget and stop if that reset fails.
- Keep Files behind authenticated SSH forwarding. Never expose its bearer HTTP
  service directly on Wi-Fi.
- Treat model, firmware, active root slot, Xovi, and extension versions as
  explicit prerequisites.
- Update [Tablet changes](TABLET_CHANGES.md) and [Uninstall](UNINSTALL.md) when
  persistent behavior changes.
- Do not call compilation physical-device proof. Record exact live paths
  separately and only after they were exercised.

## Continuous integration

The Windows CI job runs Go tests and vet, a locked Debug x64 Windows build,
PowerShell parsing, and the focused host policy checks. The macOS package job
builds and audits the unsigned arm64 app on the configured macOS runner.

CI proves source and artifact construction. It does not prove a fresh-tablet
install, authentication, physical input, suspend recovery, or user acceptance.

See [Releasing](RELEASING.md) for the stronger public-release gate.
