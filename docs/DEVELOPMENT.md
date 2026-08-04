# Development

The Windows host is WinUI 3 on .NET 10. Tablet companions are dependency-free
Go programs built for Linux ARM64. The Files loopback extension uses a pinned
reMarkable cross-toolchain container and Xovi generator commit.

This page is for contributors. If you only want to install and use Mirror, start
with [Getting started](GETTING_STARTED.md).

## Development machine

Use Windows 11 x64. The app itself targets Windows build `22621` or later. The
current Docker Desktop WSL 2 requirements make Windows 11 `23H2` or later the
practical baseline for a full source build.

Confirm WinGet is available, then install Git and PowerShell 7:

```powershell
winget --version
winget install --id Git.Git -e --source winget
winget install --id Microsoft.PowerShell --source winget
```

If WinGet is missing, install or update Microsoft's **App Installer** using the
[official WinGet instructions](https://learn.microsoft.com/windows/package-manager/winget/).

Install Visual Studio 2026 with the **WinUI application development** workload
using Microsoft's current configuration:

```powershell
winget configure -f https://aka.ms/winui-config
```

That command also enables Windows Developer Mode. It does not change reMarkable
Developer Mode on the tablet.

Install these exact or required tools:

- [.NET SDK 10.0.302, Windows x64](https://dotnet.microsoft.com/en-us/download/dotnet/thank-you/sdk-10.0.302-windows-x64-installer)
- [Go 1.26.5, Windows x64 MSI](https://go.dev/dl/go1.26.5.windows-amd64.msi)
- [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/), running Linux containers
- Windows OpenSSH Client

The Visual Studio workload supplies the Windows SDK used for `makeappx.exe` and
`signtool.exe`. The package builder searches the installed Windows Kits and
stops with a specific error if either tool is missing.

Confirm both x64 tools are present:

```powershell
$windowsKitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeAppx = @(
    Get-ChildItem -LiteralPath $windowsKitsRoot `
        -Filter makeappx.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object FullName -Match '\\x64\\'
)
$signTool = @(
    Get-ChildItem -LiteralPath $windowsKitsRoot `
        -Filter signtool.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object FullName -Match '\\x64\\'
)
if ($makeAppx.Count -eq 0 -or $signTool.Count -eq 0) {
    throw 'The x64 Windows SDK packaging tools are missing. Repair the WinUI workload.'
}
[pscustomobject]@{
    MakeAppx = $makeAppx[0].FullName
    SignTool = $signTool[0].FullName
}
```

Check OpenSSH from elevated Windows PowerShell:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Install it if the state is `NotPresent`:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Open a new PowerShell 7 terminal after installing tools.

## Get the source

```powershell
git clone https://github.com/iFixRobots/remarkable-mirror.git
Set-Location remarkable-mirror
```

Do not place tablet passwords, SSH keys, captures, device profiles, wake tokens,
or signing keys in the repository. Local build output and captures belong only
in ignored locations.

## Verify the toolchain

Run these commands from the repository root:

```powershell
$PSVersionTable.PSVersion
dotnet --version
go version
docker version --format '{{.Server.Version}}'
Get-Command ssh.exe, scp.exe, ssh-keygen.exe, ssh-keyscan.exe
```

The required results are:

- PowerShell `7.5` or newer
- .NET SDK exactly `10.0.302`
- `go version go1.26.5 windows/amd64`
- a running Docker server using Linux containers
- all four Windows OpenSSH commands

The repository's `global.json` disables .NET SDK roll-forward. The package and
agent scripts also reject Go version drift.

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

Docker Desktop must be running with Linux containers:

```powershell
.\scripts\Build-RemarkableFilesLoopback.ps1 -Force
```

The script pins the toolchain image by digest and pins the Xovi generator
commit. Do not update either pin without reviewing the generated ABI and
upstream license.

## Build the Windows app

```powershell
dotnet restore mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configfile mirror\windows\NuGet.config `
    --locked-mode

dotnet build mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj `
    --configuration Debug `
    --no-restore `
    -p:Platform=x64
```

## Run focused checks

The repository keeps host policy checks as standalone PowerShell scripts:

```powershell
Get-ChildItem scripts\Test-RemarkableMirror*.ps1 |
    Where-Object Name -NotMatch 'Live' |
    ForEach-Object { & $_.FullName }
```

Scripts with `Live` in the name can contact or change an already prepared
tablet. Read the named checkpoint before running one. They are not onboarding
shortcuts.

## Build the portable Windows executable

The portable build is one self-contained x64 `.exe`. It is useful for a Windows
account and tablet that have already completed the full installer. It does not
replace first-time setup.

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

The normal package remains on the same Windows App SDK used by the accepted
Gold build. The portable profile has a separate locked dependency set for its
unpackaged Windows data folders.

## GitHub Actions downloads

`.github/workflows/package.yml` runs after each push to `main` and can also be
started manually. It builds the Files loopback extension on Ubuntu, then builds
and uploads two Windows artifacts:

- `remarkable-mirror-windows-installer`
- `remarkable-mirror-portable-windows-x64`

The installer artifact contains the complete release folder and shareable ZIP.
The portable artifact contains exactly one `ReMarkableMirror.exe`.

## Build a development package

Use a separate publisher and package identity so a local build cannot collide
with an official iFixRobots installation:

```powershell
$packageIdentity = New-Guid

.\scripts\Build-RemarkableMirrorPackage.ps1 `
    -Publisher 'CN=Local Mirror Build' `
    -PublisherDisplayName 'Local Mirror Build' `
    -PackageIdentity $packageIdentity
```

The build creates or reuses a local non-exportable signing certificate for that
publisher, signs the MSIX, and writes the release folder and ZIP under ignored
`artifacts\remarkable-mirror`.

Official iFixRobots packages refuse a dirty source tree. The explicit dirty-tree
override exists for a maintainer's local development artifact. Do not publish
an artifact created with that override as an official release.

## Pair a development tablet

Build the package first, then follow these sections of Getting started:

1. [Back up before Developer Mode](GETTING_STARTED.md#1-back-up-before-developer-mode)
2. [Enable reMarkable Developer Mode](GETTING_STARTED.md#4-enable-remarkable-developer-mode)
3. [Restore and prepare the tablet](GETTING_STARTED.md#5-restore-and-prepare-the-tablet)
4. [Prepare Windows for installation](GETTING_STARTED.md#6-prepare-windows-for-installation)
5. [Pair one dedicated SSH key](GETTING_STARTED.md#7-pair-one-dedicated-ssh-key)
6. [Install Mirror and its tablet components](GETTING_STARTED.md#8-install-mirror-and-its-tablet-components)

The package flow is the supported way to install the tablet components.
The repository does not include a second launcher that stages arbitrary tablet
state outside that package.

## Tablet development rules

- Any Xochitl or Xovi restart path must reset `xochitl.service`'s failure budget
  immediately before the action.
- Touch, pen, and keyboard input must remain session-only.
- Do not add persistent virtual-input startup hooks.
- Keep root passwords, SSH identities, host captures, and document content out
  of the repository and issue attachments.
- Do not claim a device or firmware version is supported until the affected path
  has actually been tested there.
