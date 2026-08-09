# Getting started

This is the full path from a normal Paper Pro Move to a working reMarkable
Mirror installation on Windows. Read it once from the top before changing the
tablet. The reset is the only part you cannot casually undo.

Follow these steps in order. If one fails, stop there and use the linked
troubleshooting section before continuing.

> [!NOTE]
> There are two unrelated settings named Developer Mode in this guide.
> **reMarkable Developer Mode** unlocks the tablet and factory-resets it.
> **Windows Developer Mode** lets Windows build and run development packages.

> [!IMPORTANT]
> I use Mirror on my own tablet and have tested its USB and Wi-Fi connections,
> input modes, screenshots, PDF and EPUB import, PDF export, and PDF drag-out to
> Explorer. One complete run on a newly set up Windows account and freshly reset
> tablet is still open before the first public binary release. If a step does
> not match what you see, stop there and report it.

The screenshots below show the current Mirror app. reMarkable may change its
settings screens between tablet updates, so use the linked official Developer
Mode guide as the authority for those menus.

## What you will end up with

At the end of this guide, you should have:

- reMarkable Mirror installed like a normal Windows app
- live display and input over a direct USB-C cable
- live display, touch, keyboard, and Pen input over Wi-Fi
- screenshots copied or saved from the app
- the Files drawer available whenever the tablet is unlocked
- PDF and DRM-free EPUB import from Windows
- documents saved to Windows as PDF or native RMDOC, including PDF drag-out to
  Explorer
- a dedicated SSH key used only for this tablet

![reMarkable Mirror connected over Wi-Fi](images/remarkable-mirror-live-wifi.png)

## Confirm that your setup matches mine

I have tested the current version with this setup:

| Part | Tested setup |
| --- | --- |
| Tablet | reMarkable Paper Pro Move, code name `chiappa` |
| Tablet software | Beta `3.28.0.164`, OS build `5.8.199` |
| Installed app | Windows 11 x64, minimum build `22621` |
| Current source build path | Windows 11 x64 `23H2` or newer with Docker Desktop using Linux containers |

I have not tested other tablets or firmware versions yet. The installer depends
on Paper Pro Move input and system details. If the model or software version is
different, stop before running tablet setup and open an issue with the exact
values shown under **Settings > General > Help > About**.

## What you need

- A reMarkable Paper Pro Move
- A USB-C cable that carries data, not a charge-only cable
- Windows 11 x64 build `22621` or newer for the installer or portable app
- Windows 11 x64 `23H2` or newer if you build the installer from source
- Sign in to Windows with an administrator account. Setup stores Mirror and its
  SSH files for that account.
- A Wi-Fi network that both the PC and tablet can join
- The tablet's reMarkable account credentials if you will restore cloud content
- About 30 to 60 minutes when the Windows tools already exist, plus however long
  the tablet reset and sync take. A fresh source-build machine will take longer
  while Visual Studio and Docker install.

If you are building from source, you also need Visual Studio 2026, .NET SDK
`10.0.302`, Go `1.26.5`, Docker Desktop, Git, PowerShell 7.5 or newer, the
Windows OpenSSH client, and Windows SDK packaging tools. The exact setup is below.

> [!NOTE]
> The PC and tablet must be able to reach each other directly on Wi-Fi. Guest
> networks and access points with client isolation usually block this.

## 1. Back up before Developer Mode

> [!WARNING]
> Enabling Developer Mode factory-resets the tablet. Anything that exists only
> on the tablet will be deleted. It also removes saved Wi-Fi networks.

reMarkable recommends syncing to its cloud before enabling Developer Mode. Let
the tablet finish syncing, then open the official
[reMarkable desktop app](https://support.remarkable.com/articles/Knowledge/Desktop-app)
or mobile app and confirm that the latest notebooks, documents, and folder
structure are actually present there.

If content is not visible in another official app, do not assume it is backed
up. Stop and fix that first. PDF exports are useful copies, but they are not a
full-fidelity restore of editable notebooks and organization.

I do not yet have a general local notebook backup and restore tool for other
people's tablets. For now, use reMarkable Cloud for backup and restore.

## 2. Get the Windows installer

### Download it from GitHub Actions

The repository is private during owner review, so you must be signed into a
GitHub account that has access to it.

1. Open the repository's **Actions** tab.
2. Open **Build Windows downloads**.
3. Choose the newest successful run on `main`.
4. Under **Artifacts**, download **remarkable-mirror-windows-installer**.
5. Extract the downloaded GitHub artifact to a normal folder.
6. Extract the included `ReMarkableMirror-...-x64.zip`.
7. Open the resulting `ReMarkableMirror-...-x64` folder. Keep everything in
   that folder together.

Do not run `Install.cmd` from inside a compressed archive. Skip to
[Enable reMarkable Developer Mode](#4-enable-remarkable-developer-mode).

The Actions run also includes **remarkable-mirror-portable-windows-x64**. That
artifact extracts to one `ReMarkableMirror.exe` for a tablet and Windows account
that have already completed `Install.cmd`. It does not install the tablet
components, SSH key, device profile, or Windows package, so it is not the
first-time setup. The portable EXE is not Authenticode-signed, so Windows may
warn before opening it. Actions downloads are private previews, not public
releases.

The downloaded installer carries the .NET runtime Mirror needs. You do not need
the .NET SDK, Visual Studio, Go, Docker, or the source tree unless you choose to
build the package yourself in the next section.

### If an official release ZIP exists

Download the Windows installer ZIP from this repository's GitHub Releases page,
then extract the entire ZIP to a normal folder. Only use a download from this
repository. A visible publisher name does not tell you where a file came from.

### If you cannot use either download

Build a development package from source by completing the next section.

## 3. Build the package from source

Skip this section if you downloaded the complete installer from GitHub Actions
or GitHub Releases.

### Install the Windows tools

Open **Windows Terminal** or **Windows PowerShell** and confirm WinGet is
available:

```powershell
winget --version
```

If it is missing, install or update Microsoft's **App Installer** using the
[official WinGet instructions](https://learn.microsoft.com/windows/package-manager/winget/).
Then install Git and PowerShell 7:

```powershell
winget install --id Git.Git -e --source winget
winget install --id Microsoft.PowerShell --source winget
```

Microsoft's current WinUI setup command installs Visual Studio 2026 with the
**WinUI application development** workload and enables Windows Developer Mode:

```powershell
winget configure -f https://aka.ms/winui-config
```

That command changes Windows Developer Mode. It does not touch the tablet.

Install the exact pinned SDKs:

- [.NET SDK 10.0.302, Windows x64](https://dotnet.microsoft.com/en-us/download/dotnet/thank-you/sdk-10.0.302-windows-x64-installer)
- [Go 1.26.5, Windows x64 MSI](https://go.dev/dl/go1.26.5.windows-amd64.msi)
- [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/)

Start Docker Desktop and keep it in Linux-container mode. The first Files
extension build downloads a pinned reMarkable cross-toolchain image.

Confirm the WinUI setup installed the two Windows SDK packaging tools used by
the package builder:

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

### Confirm Windows OpenSSH

In an elevated **Windows PowerShell** window, check the OpenSSH Client:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

If its state is `NotPresent`, install it:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Open a fresh **PowerShell 7** window and confirm the tools are visible:

```powershell
pwsh --version
git --version
go version
docker version --format '{{.Server.Version}}'
Get-Command ssh.exe, scp.exe, ssh-keygen.exe, ssh-keyscan.exe
```

Expected minimums and exact pins:

- PowerShell reports `7.5` or newer
- Go reports `go1.26.5 windows/amd64`
- Docker reports a running server, not only a client
- all four OpenSSH commands resolve to real executables

### Get the source

> [!IMPORTANT]
> The repository is private during owner review. The clone command below works
> only for an authenticated GitHub account that has been added as a
> collaborator. There is no anonymous download yet.

```powershell
git clone https://github.com/iFixRobots/remarkable-mirror.git
Set-Location remarkable-mirror
dotnet --version
```

Because the repository contains `global.json`, the last command must report
exactly `10.0.302`. If it does not, install that SDK before continuing.

### Build a local package

Use a local package identity so the build cannot collide with an official
iFixRobots installation:

```powershell
$packageIdentity = New-Guid

.\scripts\Build-RemarkableMirrorPackage.ps1 `
    -Publisher 'CN=Local Mirror Build' `
    -PublisherDisplayName 'Local Mirror Build' `
    -PackageIdentity $packageIdentity
```

The first build downloads locked NuGet dependencies, the Windows App Runtime,
the pinned Xovi release, and the pinned tablet toolchain. It then creates a local
non-exportable signing certificate, a signed MSIX, and a shareable ZIP under:

```text
artifacts\remarkable-mirror\
```

The script prints the exact release folder and ZIP when it finishes. Keep the
entire release folder together. Do not mix files from separate builds.

Do not reset the tablet until this build finishes successfully and the complete
release folder exists.

## 4. Enable reMarkable Developer Mode

Use reMarkable's current
[Developer Mode documentation](https://developer.remarkable.com/documentation/developer-mode)
as the authority. On the tablet, open:

**Settings > General > Paper Tablet > Software > Advanced > Developer Mode**

Read the tablet's warning, enable Developer Mode, and let the reset complete.
Developer Mode weakens the normal secure-boot chain and grants root SSH access.
That is the capability Mirror needs, and it is a real security tradeoff.

## 5. Restore and prepare the tablet

After the reset:

1. Finish the tablet's first-run setup.
2. Sign into the same reMarkable account used for the backup.
3. Reconnect Wi-Fi from the tablet. The reset erased the old password.
4. Wait until the tablet's network screen explicitly says **Connected**.
5. Wait for cloud sync, then confirm the expected notebooks, documents, and
   folders return before installing Mirror.
6. Complete the first passcode unlock after boot.
7. Open **Settings > General > Help > About > Copyrights and Licenses**.
8. Find the Developer Mode username and generated root password under
   **General Information**.
9. Enable **Settings > General > Storage > USB web interface** for the Files
   drawer.

Cloud sync restores synced content. It does not restore the erased Wi-Fi
password, Developer Mode credentials, locally installed software, or every
device preference. Set those up again instead of assuming they came back.

Keep the root password available for the one-time SSH pairing step. Enter Wi-Fi
credentials only on the tablet. Mirror never needs the Wi-Fi password.

## 6. Prepare Windows for installation

Whether you built the package or downloaded a release, installation requires:

- PowerShell 7.5 or newer
- Windows OpenSSH Client
- a direct USB-C connection for initial pairing

Confirm the first two:

```powershell
pwsh --version
Get-Command ssh.exe, scp.exe, ssh-keygen.exe, ssh-keyscan.exe
```

Connect the tablet directly to the PC with the data cable. Wake it and complete
the first passcode unlock after boot. An ordinary screen lock is supported later,
but initial setup needs the encrypted home partition to be available.

The Developer Mode USB address is `10.11.99.1`. Check the same direct USB route
that the installer requires:

```powershell
$usbAddresses = @(
    Get-NetIPAddress `
        -IPAddress 10.11.99.11 `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue
)
if ($usbAddresses.Count -ne 1) {
    throw 'Windows does not have exactly one reMarkable USB address.'
}
$usbAddress = $usbAddresses[0]

$usbAdapters = @(
    Get-NetAdapter `
        -InterfaceIndex $usbAddress.InterfaceIndex `
        -ErrorAction SilentlyContinue
)
$usbRoutes = @(
    Get-NetRoute `
        -InterfaceIndex $usbAddress.InterfaceIndex `
        -DestinationPrefix '10.11.99.0/27' `
        -ErrorAction SilentlyContinue
)

if ($usbAddress.PrefixLength -ne 27 -or
    $usbAddress.AddressState -ne 'Preferred' -or
    $usbAddress.SkipAsSource -or
    $usbAdapters.Count -ne 1 -or
    $usbAdapters[0].Status -ne 'Up' -or
    -not $usbAdapters[0].HardwareInterface -or
    $usbAdapters[0].Virtual -or
    $usbAdapters[0].PnPDeviceID -notmatch '^USB\\' -or
    $usbRoutes.Count -ne 1 -or
    $usbRoutes[0].NextHop -ne '0.0.0.0' -or
    $usbRoutes[0].State -ne 'Alive') {
    throw 'The reMarkable direct USB address, adapter, or route is not ready.'
}

[pscustomobject]@{
    Address = "$($usbAddress.IPAddress)/$($usbAddress.PrefixLength)"
    Adapter = $usbAdapters[0].InterfaceAlias
    Route = $usbRoutes[0].DestinationPrefix
    State = $usbRoutes[0].State
}
```

The output should show `10.11.99.11/27`, a physical USB adapter,
`10.11.99.0/27`, and `Alive`. If the block throws, stop and use
[USB does not create the direct tablet network](TROUBLESHOOTING.md#usb-does-not-create-the-direct-tablet-network).

## 7. Pair one dedicated SSH key

Mirror uses a dedicated passphrase-free key because its OpenSSH connections run
with `BatchMode=yes` and cannot stop to ask for a passphrase. Do not reuse this
key for anything else.

Run the following in PowerShell 7:

```powershell
$key = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'

New-Item -ItemType Directory -Path (Split-Path $key) -Force | Out-Null

if (-not (Test-Path -LiteralPath $key)) {
    ssh-keygen.exe -t ed25519 -f $key -C 'remarkable-mirror' -N ''
}

$derivedPublicKey = @(& ssh-keygen.exe -y -f $key 2>$null)
$derivedPublicKeyFields = if ($derivedPublicKey.Count -eq 1) {
    @($derivedPublicKey[0] -split '\s+')
} else {
    @()
}
if ($LASTEXITCODE -ne 0 -or
    $derivedPublicKeyFields.Count -lt 2 -or
    $derivedPublicKeyFields[0] -ne 'ssh-ed25519' -or
    [string]::IsNullOrWhiteSpace($derivedPublicKeyFields[1])) {
    throw 'The Mirror private key could not produce one Ed25519 public key.'
}
"$($derivedPublicKeyFields[0]) $($derivedPublicKeyFields[1]) remarkable-mirror" |
    Set-Content -LiteralPath "$key.pub" -Encoding ascii
```

An existing private key is reused. Its public half is rebuilt from that private
key, so a stale or missing `.pub` file cannot pair the wrong identity. The next
step re-pairs the same dedicated key after a factory reset without replacing it.

Scan one Ed25519 host key, reject an empty or malformed result, then show the
fingerprint you are about to trust:

```powershell
$scannedHostKey = @(
    & ssh-keyscan.exe -T 5 -t ed25519 10.11.99.1 2>$null
)
if ($LASTEXITCODE -ne 0 -or
    $scannedHostKey.Count -ne 1 -or
    $scannedHostKey[0] -notmatch '^10\.11\.99\.1\s+ssh-ed25519\s+\S+$') {
    throw 'The tablet did not return one valid Ed25519 SSH host key.'
}
$scannedHostKey |
    Set-Content -LiteralPath $knownHosts -Encoding ascii

$fingerprint = (& ssh-keygen.exe -lf $knownHosts 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fingerprint)) {
    throw 'The saved tablet host key could not be fingerprinted.'
}
$fingerprint
```

If the scan fails, the tablet is not ready. Wake it, finish the first post-boot
unlock, confirm the USB address and route, and run only this scan block again.

This first USB connection saves your tablet's SSH fingerprint. Mirror uses that
fingerprint to reject a different tablet identity later.

Replace the private key's inherited Windows permissions with one rule for the
current account:

```powershell
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [System.Security.AccessControl.FileSecurity]::new()
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule(
    [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
)
Set-Acl -LiteralPath $key -AclObject $acl

$keyAcl = Get-Acl -LiteralPath $key
$keyRules = @($keyAcl.GetAccessRules(
    $true,
    $false,
    [System.Security.Principal.SecurityIdentifier]
))
[pscustomobject]@{
    Owner = $keyAcl.GetOwner(
        [System.Security.Principal.SecurityIdentifier]).Value
    Protected = $keyAcl.AreAccessRulesProtected
    RuleCount = $keyRules.Count
    RuleSid = $keyRules[0].IdentityReference.Value
    Rights = $keyRules[0].FileSystemRights
}
```

The output must show `Protected` as `True`, `RuleCount` as `1`, the current SID
for both owner and rule, and `FullControl` rights.

Now install the public key. This command prompts for the generated root password
shown on the tablet:

```powershell
Get-Content -LiteralPath "$key.pub" |
    ssh.exe -F NUL `
        -o "UserKnownHostsFile=$knownHosts" `
        -o StrictHostKeyChecking=yes `
        root@10.11.99.1 `
        'umask 077; mkdir -p /home/root/.ssh; chmod 700 /home/root/.ssh; touch /home/root/.ssh/authorized_keys; chmod 600 /home/root/.ssh/authorized_keys; key=$(cat); grep -qxF "$key" /home/root/.ssh/authorized_keys || printf "%s\n" "$key" >> /home/root/.ssh/authorized_keys'
```

You can safely run this command again. It keeps the existing key when it is
already present instead of adding another copy.

Verify that the dedicated key works without a password prompt:

```powershell
ssh.exe -F NUL `
    -i $key `
    -o BatchMode=yes `
    -o IdentitiesOnly=yes `
    -o "UserKnownHostsFile=$knownHosts" `
    -o StrictHostKeyChecking=yes `
    root@10.11.99.1 true
```

Success returns to the prompt without output. Keep the private key on this PC.
Never add it to the repository or attach it to a bug report.

## 8. Install Mirror and its tablet components

Open the complete release folder printed by the build, or the complete folder
you extracted from the private Actions installer ZIP or a future official
release ZIP. Double-click:

```text
Install.cmd
```

Keep the tablet connected and unlocked until the installer finishes. Accept the
single Windows administrator prompt used to trust the local signing certificate
and install the package.

Before starting, confirm the tablet still explicitly says Wi-Fi is
**Connected**. If Wi-Fi is not ready, the installer can finish USB work but must
pause wireless pairing. Connect Wi-Fi on the tablet and run the same
`Install.cmd` again.

The installer verifies its release metadata, installs the Windows App Runtime
and Mirror, and then installs the matching tablet probe, Xovi runtime and
extensions, Files loopback, and USB transport wake support. Touch, pen, and
keyboard input are started only when Mirror connects. They are not installed as
persistent tablet startup hooks.

The installer also enables reMarkable's `rm-ssh-over-wlan` setting. Mirror then
reuses the SSH key you set up over USB when the PC and tablet are on the same
Wi-Fi network. It does not expose the Files web service directly on Wi-Fi.

On success, the installer window closes and reMarkable Mirror opens
automatically. If the installer window stays open, setup failed and the last
lines contain the error. Read that error before closing the window.

## 9. Connect over USB-C

Mirror should already be open after a successful install. If it was closed, open
**reMarkable Mirror** from the Windows Start menu. Launch waits for you and does
not contact the tablet. Leave USB connected, then choose **Connect USB-C**.

That action starts a bounded attempt against only the direct cable. It moves
through **Connecting** or **Preparing your reMarkable**, then reaches **Live over
USB**. If the tablet just rebooted, complete its first passcode unlock. If it is
only at the ordinary lock screen, Mirror can stay live and let you enter the
passcode through the mirrored UI.

![Mirror preparing the display and controls](images/remarkable-mirror-preparing.png)

That card is a temporary progress state. If the attempt ends, Mirror returns to
the two manual connection choices. Use the visible status and Troubleshooting
before choosing **Connect USB-C** again.

Check each item:

1. The tablet image updates in the Windows app.
2. In **Touch + Type**, a mouse click behaves like touch.
3. Without changing modes, type into a text field with the hardware keyboard.
4. Select **Pen** and confirm the mouse behaves like a stylus.
5. Select the camera button and confirm the screenshot toast appears. A normal
   click copies the image. Right-click the button and choose **Save screenshot
   as...** to open **Save As**.
6. Open **Files** while the tablet is unlocked. Confirm the library loads.
7. Drop a small disposable PDF and a DRM-free EPUB onto the send area, one at a
   time, and confirm both appear on the tablet.
8. Drag a document row out of Mirror and release it in a normal Windows Explorer
   folder. The drag should begin immediately, without a **Preparing** message.
   Confirm that a human-named PDF appears there. Start another drag, cancel it,
   then immediately drag the same document again. The retry should begin right
   away and Mirror should stay responsive.
9. Click a document to open **Save As** for its PDF. Right-click it and confirm
   you can choose **Save as PDF...** or **Save native RMDOC...**.

When the tablet is passcode-locked, the live mirror can remain available while
Files waits. That is expected:

![Files waits for unlock while the mirror stays live](images/remarkable-mirror-files.png)

## 10. Check each manual connection

Confirm that the tablet and PC are connected to the same Wi-Fi network. Remember

After the USB checks, close and reopen Mirror so it returns to the manual
connection choices. Then:

1. Leave the tablet awake and find its IPv4 address in its Wi-Fi network details.
2. While Mirror says **Live over USB**, click that status. Mirror uses the same
   **Connect Wi-Fi** action. Only then does Mirror reveal the IP address field.
3. You may leave USB-C attached; this owner-selected attempt checks only Wi-Fi.
4. Enter the tablet's IPv4 address and choose **Connect**.
5. Confirm the status reads **Live over Wi-Fi**.
6. Repeat touch, keyboard, Pen, and screenshot checks.
7. Open **Files** and confirm that the library loads over Wi-Fi. Drop one small
   PDF and one DRM-free EPUB, drag one tablet document into Explorer, then save
   one document as native RMDOC to Windows.
8. With USB-C attached, click **Live over Wi-Fi**. Mirror uses the same bounded
   **Connect USB-C** action.
9. Confirm **Live over USB**, **Touch + Type**, and Files still work.

The entered address selects where to make the attempt; it does not replace the
pinned tablet identity or paired Windows network checks. An invalid address,
another tablet, or the wrong network is rejected.

> [!NOTE]
> During an active Mirror session, the USB carrier guard prevents suspend while
> attached, and the selected input session holds its own wake lease. If Linux
> already completed suspend before a connection starts, there is no
> source-proven host wake guarantee. Press the tablet's power button once, enter
> its passcode, then explicitly choose the connection again. Cable and network
> changes never start, switch, or reopen a connection by themselves.

## You are done when

- [ ] The Windows app appears in Start and opens normally
- [ ] **Connect USB-C** reaches **Live over USB**
- [ ] **Touch + Type** accepts both mouse and keyboard without a mode switch
- [ ] **Pen** accepts mouse-as-stylus input
- [ ] screenshot copy and Save As both work
- [ ] Files loads when the tablet is unlocked
- [ ] a PDF and DRM-free EPUB can be dropped into the tablet over Wi-Fi
- [ ] the corrected upload also works over USB
- [ ] dragging a tablet document into Explorer starts immediately and creates a
      normal PDF; canceling and immediately retrying does not freeze Mirror
- [ ] a document can be saved as PDF and native RMDOC to a Windows folder
- [ ] **Connect Wi-Fi** reveals the IP field only after it is selected
- [ ] entering the tablet IPv4 address reaches **Live over Wi-Fi**
- [ ] Wi-Fi touch and keyboard input work
- [ ] Wi-Fi Pen input works
- [ ] Wi-Fi Files loads when the tablet is unlocked
- [ ] reopening Mirror and choosing **Connect USB-C** returns to **Live over USB**
- [ ] **Touch + Type** and Files work after returning to USB

If one box fails, do not call the setup finished. Start with
[Troubleshooting](TROUBLESHOOTING.md) and include the exact visible app status in
any issue.

## After a firmware update

The tablet uses A/B root slots. A firmware update can activate a root that does
not contain Mirror's matching components. If Mirror shows **Repair** after an
update:

1. check that the release explicitly supports the tablet's new software
   version;
2. if it does not, stop and report the new version;
3. if it does, connect the tablet over USB-C;
4. wake it and complete the first post-boot unlock;
5. run `Install.cmd` from that supported release again; and
6. reopen Mirror after setup completes.

Do not choose **Retry** repeatedly while tablet setup is incomplete. Automatic
repair after every future root-slot switch is not ready yet.

## What the common states mean

| App state | Meaning | What to do |
| --- | --- | --- |
| **Connect to your reMarkable** | Mirror is idle and has not contacted the tablet | Choose **Connect USB-C** or **Connect Wi-Fi** |
| **Connecting** | The owner-selected route is opening | Wait for this bounded attempt |
| **Preparing your reMarkable** | Display and input for this connection are starting | Wait; unlock if this is the first post-boot unlock |
| **Live over USB** | Display and input are ready through the cable | Click the status to enter a Wi-Fi address and switch routes |
| **Live over Wi-Fi** | Display, touch, keyboard, and Pen are ready over Wi-Fi | Click the status to start a USB-C switch |
| **Connect to your reMarkable** after a failure | The selected session ended or could not start | Fix the cable, network, address, or tablet state, then explicitly choose a route again |
| **Repair** | The active tablet root is missing matching components | Confirm firmware support, then run the supported release's `Install.cmd` over unlocked USB |
| Files says connect while Mirror is live | The tablet is locked or the stock Files listener is unavailable | Unlock and confirm USB web interface is enabled |

For deeper recovery, continue with [Troubleshooting](TROUBLESHOOTING.md).
