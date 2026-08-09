# Development

The Windows host is WinUI 3 on .NET 10. The in-progress native Mac host is
SwiftUI plus AppKit. Tablet companions are dependency-free Go programs built
for Linux ARM64. The Files loopback extension uses a pinned reMarkable
cross-toolchain container and Xovi generator commit.

This page is for contributors. If you only want to install and use Mirror, start
with [Getting started](GETTING_STARTED.md).

## Windows development machine

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

The Windows connection lifecycle is owner-started. App launch must perform no
tablet probe or wake. **Connect USB-C** owns a bounded attempt against only
`10.11.99.1`; **Connect Wi-Fi** first reveals an IPv4 field and submission makes
one attempt against only that address. The selected route stays pinned until
its generation retires. The clickable Live route status must delegate to those
same two actions rather than implement another connection path. Reuse the
existing direct-USB adapter, cable-only wake,
paired Windows network, and pinned SSH identity checks; manual admission must
not replace those transport mechanics. Windows builds normalize multiline SSH
commands to POSIX line endings before sending them to the tablet. Do not add
background connection monitors, route
fallback or promotion, or automatic reconnection. Do not open the Files tunnel
until the owner opens Files. Keep entered Wi-Fi addresses out of diagnostics
and persistent profile writes.

Run the focused source and policy check after changing this lifecycle:

```powershell
.\scripts\Test-RemarkableMirrorManualConnectionPolicy.ps1
```

## Build the native macOS candidate

The app's deployment target is Apple silicon on macOS 14 or newer. That minimum
runtime has not yet been exercised. The packaging toolchain remains Xcode 26.6,
Swift 6.3.3 and the macOS 26.5 SDK. The Milestone 6 source builds as one
product-only target under stable Xcode 26.6. The last audited unsigned arm64
Release build and package predate the current
recovery and presentation changes. The build script selects
`/Applications/Xcode.app` explicitly so a globally selected beta Xcode does not
silently change a Release candidate.

```zsh
scripts/Build-RemarkableMirrorMac.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project mirror/macos/ReMarkableMirror.xcodeproj \
  -scheme ReMarkableMirror \
  -configuration Debug \
  -derivedDataPath artifacts/macos/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Create the unsigned arm64 review ZIP after a Release build:

```zsh
scripts/Package-RemarkableMirrorMac.sh
```

The last audited unsigned package is
`artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip`,
SHA-256
`0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
That checksum and archive audit apply only to the older package; it does not
prove parity with the current source or product-only build. On 2026-08-08,
current-worktree product runs reached **Live** over owner-started USB-C with the
real frame and owned frame, input and Files processes. They physically exercised
Files recovery and navigation, PDF and native RMDOC export, screenshot copy and
save, touch and Pen taps, committed keyboard text, a continuous swipe, and clean
owned-process shutdown. Import or upload, delete, Finder drag-out, pen stroke,
eraser/right-click, Wi-Fi and the exact fully-deep-sleep power event remain open.
A signed current-source package, notarization, hosting and owner acceptance also
remain open.

The native Mac project deliberately contains no XCTest target, Preview menu,
command-line mock states or QA bundle identity. Review its behavior in the real
product at the fixed window dimensions, and treat only an exercised physical
tablet path as evidence for pairing, mirroring, input, Files, or owner-started
connection. See
[macOS Getting Started](macos/GETTING_STARTED.md) before installing the
candidate.

Production Points of Interest use fixed names and no payload for connection
activation, first-frame delivery, PNG encoding and Finder promise fulfillment.
Capture those intervals with Instruments when measuring a real device path;
compilation alone is not product-performance evidence.

Building the Mac product does not contact or change a tablet. Local preparation
is opt-in and first proves that the same reMarkable remains attached directly
through one data-capable USB-C cable before it captures a host key or creates
local credentials. The persistent **Add This Mac…** action is separately
owner-approved. It repeats the exact direct-USB checks before appending the
dedicated public key and installing or upgrading the tablet-side USB keep-awake
service, including its wake lock and sleep guard. Its one-time root password is
never saved. **Connection > Set Up Wi‑Fi…** separately verifies the current
Wi-Fi connection without Location Services; it does not repeat the key append.
A profile waiting for that Wi-Fi step can already make an explicit
**Connect USB‑C** attempt; USB use does not silently finish or bypass Wi-Fi
verification.

Launching the Mac app, attaching USB, or observing a network change must not
communicate with the tablet. **Set Up**, **Add This Mac…**,
**Check Authorization**, and **Connection > Set Up Wi‑Fi…** are explicit bounded
operations. **Connect USB‑C** starts one bounded session that stays on the same
direct cable while it wakes the tablet, waits for its services, authenticates,
and connects. It must never inspect, select, or fall back to Wi-Fi. If the tablet
requires its passcode, the owner unlocks it and that USB-C session continues.
**Connect Wi‑Fi** is a separate owner action. An accepted password submission is
not followed by background recovery. If its outcome is uncertain,
**Check Authorization** performs one
bounded key-only check on a freshly revalidated direct USB context. Mirror does
not save the password or reopen its prompt by itself; only a current-context
key rejection makes another owner-started password attempt eligible.

A successful **Connect USB‑C** or **Connect Wi‑Fi** session pins that selected
connection to the new generation. Cable and network changes retire the
generation and return the app to its disconnected surface. They never cause
automatic fallback, promotion, or reconnection. Active-session keep-awake
remains part of a Live owner-started connection.

Files visibility is a separate owner intent. Opening the pane creates one exact
request for a 60-second same-generation readiness window; its full deadline
begins only after an eligible Files capability claims it. Closing the pane or
reaching the deadline stops retry work. While unavailable, **Try Files Again**
renews that explicit owner window without closing the pane; after readiness the
same control becomes **Refresh**. Preserve request, capability and visibility
identity checks so stale work cannot rearm a closed pane or consume a later
request.

Normal Mac termination first cancels the AppKit quit, then starts Finder-promise
admission closure, cancellation and drain concurrently with generation shutdown.
It awaits both before evaluating the shutdown result, so generation retirement
can unblock a promise queued behind an earlier Files operation without allowing
the process to exit before the promise drain finishes. It issues a second
immediate termination only after a clean result. Do not read
`charactersIgnoringModifiers` from modifier-only
`flagsChanged` events; AppKit permits that accessor only for key-down and key-up
events. Modifier routing should continue to use key code, flags and location.

Pending Wi-Fi setup offers **Connect USB‑C** without silently completing Wi-Fi
setup. Wi-Fi setup starts from **Connection > Set Up Wi‑Fi…**, and sanitized
diagnostics are available under **Help > Copy Connection Diagnostics**.
Progress presentation is deferred for
brief attempts so an immediate result does not flash a transient spinner card.

Keep Swift 6 complete strict concurrency enabled. Mutable connection state
belongs to actors; UI state belongs to `MainActor`. Do not weaken checks with
`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, or detached
tasks. A generation must be tombstoned before process retirement, and a failed
retirement must retain ownership for retry.

Only explicit Wi-Fi setup uses the Data Protection Keychain for the paired
Wi-Fi context secret and wake token. Direct USB-C admission, status, wake and
connection never require that bearer. Persistence and access-group behavior
must be inspected in an authorized signed product; the unsigned local build
does not establish either property.

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

The normal package and portable build use the same Windows App SDK line. The
portable profile includes only Base, DWrite, Foundation, Interactive
Experiences, and WinUI. It leaves
out AI, machine learning, Widgets, and the shared-runtime package, compresses
the single-file payload, and does not build a ReadyToRun composite image.

## GitHub Actions downloads

`.github/workflows/package.yml` runs after each push to `main` and can also be
started manually. It builds the Files loopback extension on Ubuntu, then builds
and uploads two Windows artifacts:

- `remarkable-mirror-windows-installer`
- `remarkable-mirror-portable-windows-x64`

The installer artifact contains only the versioned shareable ZIP; it does not
upload a duplicate expanded release folder. The portable artifact contains
exactly one `ReMarkableMirror.exe`. GitHub wraps either artifact in its own ZIP
when it is downloaded from Actions.

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

The application MSIX includes its matching .NET runtime. The Windows App SDK
1.8 runtime remains the separate dependency inside the same release folder, so
`Install.cmd` can set up a new Windows account without a preinstalled .NET SDK
or runtime.

Release builds disable Mirror-owned PDB/CodeView output. Before signing, the
builder inspects `ReMarkableMirror.dll` and `ReMarkableMirror.exe` and stops if
either contains a rooted application CodeView path or the current repository or
user-profile root. The SDK-provided native apphost may retain its own framework
build provenance. Debug builds keep their symbols.

Package builds also require the complete public `PACKAGE_ONBOARDING.md`,
`GETTING_STARTED.md`, and `TROUBLESHOOTING.md` files plus all three images under
`docs\images`. A missing file stops the build. There is no fallback to a shorter
workspace-only guide.

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

The packaged prerequisite installer uses
`scripts\lib\RemarkableRmctlCapture.ps1` to start SSH and SCP inside a gated
Windows Job Object. Keep the generated launcher command fixed-size. The target
file path and arguments are serialized once and written through the launcher's
standard input after job assignment and gate release. Do not put that payload
back into `-EncodedCommand`; long remote setup scripts can exceed the Windows
command-length limit. `Test-RemarkableMirrorPackageMetadata.ps1` checks the
standard-input transport markers and the packaged helper copy.

## Tablet development rules

- Any Xochitl or Xovi restart path must reset `xochitl.service`'s failure budget
  immediately before the action.
- Touch, pen, and keyboard input must remain session-only.
- Do not add persistent virtual-input startup hooks.
- Keep root passwords, SSH identities, host captures, and document content out
  of the repository and issue attachments.
- Do not claim a device or firmware version is supported until the affected path
  has actually been tested there.
