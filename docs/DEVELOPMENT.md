# Development

## Toolchain

The host application is WinUI 3 on .NET 10. Tablet companions are dependency-free
Go programs built for Linux ARM64. The Files loopback extension uses the pinned
reMarkable cross-toolchain container and Xovi generator commit.

Install:

- Windows 11 x64
- Visual Studio 2026 with Windows application development tools, or the exact
  command-line SDKs documented here
- .NET SDK 10.0.302 (pinned by the root `global.json`)
- PowerShell 7.5 or newer
- Go 1.26.5 exactly
- Docker Desktop using Linux containers
- Git and Windows OpenSSH

## Get the source

```powershell
git clone https://github.com/iFixRobots/remarkable-mirror.git
Set-Location remarkable-mirror
```

Do not place tablet passwords, SSH keys, captures, device profiles, or signing
keys in the repository. The default ignored locations cover local build output
and captures.

## Validate the tablet agent

```powershell
Push-Location mirror\agent
go test ./...
go vet ./...
Pop-Location
```

Build deterministic Linux ARM64 companions:

```powershell
.\scripts\Build-RemarkableMirrorAgent.ps1 -Force
.\scripts\Build-RemarkableTransportWake.ps1 -Force
```

## Build the Files extension

Docker must be running with Linux containers:

```powershell
.\scripts\Build-RemarkableFilesLoopback.ps1 -Force
```

The script pins both the toolchain image and Xovi generator commit. Do not update
either pin without reviewing the generated ABI and the upstream license.

## Build the Windows app

```powershell
dotnet restore mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configfile mirror\windows\NuGet.config `
    --locked-mode

dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    -p:Platform=x64
```

## Run focused checks

The repository keeps policy checks as standalone PowerShell scripts so they can
exercise the exact source expressions used by the app and installer:

```powershell
Get-ChildItem scripts\Test-RemarkableMirror*.ps1 |
    Where-Object Name -NotMatch 'Live' |
    ForEach-Object { & $_.FullName }
```

Scripts with `Live` in the name can contact or change a provisioned tablet. Run
them only when you understand the named live checkpoint.

## Build a development package

Use your own publisher and package identity. This avoids colliding with official
iFixRobots installations:

```powershell
$identity = New-Guid
.\scripts\Build-RemarkableMirrorPackage.ps1 `
    -Publisher 'CN=Your Name' `
    -PublisherDisplayName 'Your Name' `
    -PackageIdentity $identity
```

The build creates or reuses a local non-exportable signing certificate for that
publisher, signs the MSIX, and writes the release ZIP under ignored `artifacts`.
The installer reads the package identity and publisher from its release metadata.

Official iFixRobots packages refuse a dirty source tree. A clearly marked local
development override exists for maintainers, but its output must not be published
as an official release.

## Device development

Finish [Device setup](DEVICE_SETUP.md) first. Provision tablet components through
a development package with your own package identity. The public tree does not
include a one-shot launcher that stages components and changes live tablet state
outside that package flow.

The explicitly named `Live` check is for focused work on an already provisioned
tablet. It is not an onboarding shortcut. Read it before running it and keep
credentials and output outside the repository.

Any Xochitl or Xovi restart path must reset `xochitl.service`'s failure budget
immediately before the action. Input stays session-only; never add persistent
virtual-input startup hooks.
