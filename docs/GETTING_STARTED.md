# Getting started: new tablet to Live

This is the complete first-time path for a reMarkable Paper Pro Move and a
Windows 11 PC. Read it once before enabling Developer Mode.

> [!WARNING]
> Enabling reMarkable Developer Mode factory-resets the tablet, removes saved
> Wi-Fi networks, and weakens the normal secure-boot boundary. Verify your
> backup first.

> [!IMPORTANT]
> The Windows app has the complete installer and setup path. The real native
> macOS app is currently an unsigned development build; its setup flow does not
> yet install every tablet prerequisite. ARM64 Linux components run on the
> reMarkable itself and are not a third desktop app.

The current setup path is implemented but has not yet completed an independent
clean-Windows/fresh-reset acceptance run. If a screen, model, version, or result
does not match this guide, stop at that step and report it.

## Before you begin

You need:

- a reMarkable Paper Pro Move (`chiappa`) on a software version explicitly
  supported by the installer release;
- a Windows 11 x64 PC, build `22621` or newer;
- a Windows account that is itself an administrator;
- PowerShell 7.5 or newer;
- Windows OpenSSH Client;
- a direct data-capable USB-C cable;
- a Wi-Fi network that allows the PC and tablet to reach each other; and
- 30 to 60 minutes, plus cloud-restoration time.

Do not continue on another tablet model or firmware unless the release notes
explicitly support it. See [Platform support](PLATFORM_SUPPORT.md).

## 1. Get the complete installer first

Obtain the installer before resetting the tablet. The download must contain
`Install.cmd`, the MSIX and certificate, runtime dependencies, `release.json`,
the `components` directory, and these guides.

- When a supported public build exists, download the Windows installer ZIP from
  this repository's **Releases** page and verify the published SHA-256.
- Repository collaborators can use the
  **remarkable-mirror-windows-installer** artifact from a successful
  **Build Windows downloads** Actions run.
- Contributors can build a development package by following the repository's
  [Development guide](https://github.com/iFixRobots/remarkable-mirror/blob/main/docs/DEVELOPMENT.md).

Extract every ZIP layer to a normal folder. Do not run `Install.cmd` from inside
a compressed archive and do not mix files from different builds.

The portable `ReMarkableMirror.exe` is not a first-time installer. It does not
create credentials, install tablet components, or create the device profile.

## 2. Back up and verify the tablet

1. Power on the tablet and complete its normal first-run setup.
2. Open **Settings > General > Software** and compare the model/software
   information with the release's support list.
3. Let reMarkable cloud sync finish.
4. Confirm the expected notebooks, documents, and folders are visible in an
   official reMarkable desktop or mobile app.
5. Export anything that exists only on the tablet.

If your content is not visible somewhere other than the tablet, stop. Developer
Mode will erase the local tablet state.

## 3. Enable reMarkable Developer Mode

Follow reMarkable's current official
[Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
On the tested software, the tablet path is:

**Settings > General > Paper Tablet > Software > Advanced > Developer Mode**

Read the tablet's warning, enable Developer Mode, and let the factory reset
finish. This is unrelated to Windows Developer Mode.

## 4. Restore and prepare the tablet

After the reset:

1. Complete first-run setup again.
2. Sign in with the same reMarkable account.
3. Reconnect Wi-Fi from the tablet; the reset erased the saved password.
4. Wait until the network screen says **Connected**.
5. Wait for cloud restoration and verify the expected content returned.
6. Set or restore the passcode, then complete the first physical unlock after
   boot.
7. Open **Settings > General > Help > About > Copyrights and Licenses** and
   find the Developer Mode root username and generated password.
8. Enable **Settings > General > Storage > USB web interface**. Mirror uses the
   stock Files service behind SSH.

Keep the generated root password available for the one-time pairing step.
Mirror never stores it. Enter the Wi-Fi password only on the tablet.

## 5. Prepare Windows

Install PowerShell 7 if needed. Microsoft documents current options in
[Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows).
With WinGet:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Open **Windows PowerShell as Administrator** and check the OpenSSH Client:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

If its state is `NotPresent`, install it:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Open PowerShell 7 as the same signed-in Windows account and confirm:

```powershell
pwsh --version
Get-Command ssh.exe, scp.exe, ssh-keygen.exe, ssh-keyscan.exe
```

## 6. Pair one dedicated SSH key

Connect the unlocked tablet directly to the PC with the data-capable USB-C
cable. Do not use a dock. The Developer Mode cable network is:

- tablet: `10.11.99.1`;
- Windows: `10.11.99.11/27`; and
- route: `10.11.99.0/27`.

Run the following entire block in PowerShell 7. It verifies the physical USB
route, creates or reuses one dedicated key, pins the tablet's Ed25519 host key,
restricts the private-key ACL to the current Windows account, installs the
public key, and verifies key-only access.

```powershell
$ErrorActionPreference = 'Stop'

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

$scannedHostKey = @(
    & ssh-keyscan.exe -T 5 -t ed25519 10.11.99.1 2>$null
)
if ($LASTEXITCODE -ne 0 -or
    $scannedHostKey.Count -ne 1 -or
    $scannedHostKey[0] -notmatch '^10\.11\.99\.1\s+ssh-ed25519\s+\S+$') {
    throw 'The tablet did not return one valid Ed25519 SSH host key.'
}
$scannedHostKey | Set-Content -LiteralPath $knownHosts -Encoding ascii

$fingerprint = (& ssh-keygen.exe -lf $knownHosts 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fingerprint)) {
    throw 'The saved tablet host key could not be fingerprinted.'
}
Write-Host 'Pinned tablet host key:'
$fingerprint

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
$keyFile = [System.IO.FileInfo]::new(
    [System.IO.Path]::GetFullPath($key)
)
[System.IO.FileSystemAclExtensions]::SetAccessControl($keyFile, $acl)

Write-Host 'Enter the tablet Developer Mode root password when SSH asks.'
Get-Content -LiteralPath "$key.pub" |
    ssh.exe -F NUL `
        -o "UserKnownHostsFile=$knownHosts" `
        -o StrictHostKeyChecking=yes `
        root@10.11.99.1 `
        'umask 077; mkdir -p /home/root/.ssh; chmod 700 /home/root/.ssh; touch /home/root/.ssh/authorized_keys; chmod 600 /home/root/.ssh/authorized_keys; key=$(cat); grep -qxF "$key" /home/root/.ssh/authorized_keys || printf "%s\n" "$key" >> /home/root/.ssh/authorized_keys'
if ($LASTEXITCODE -ne 0) {
    throw 'The tablet did not accept the dedicated Mirror public key.'
}

ssh.exe -F NUL `
    -i $key `
    -o BatchMode=yes `
    -o IdentitiesOnly=yes `
    -o "UserKnownHostsFile=$knownHosts" `
    -o StrictHostKeyChecking=yes `
    root@10.11.99.1 true
if ($LASTEXITCODE -ne 0) {
    throw 'Key-only SSH verification failed.'
}

Write-Host 'Mirror SSH pairing is ready.'
```

The host fingerprint is trust-on-first-use over the verified physical cable.
An existing Mirror private key is reused; the block does not overwrite it.
Success ends with `Mirror SSH pairing is ready.`

If the block stops, do not disable strict host-key checking or create random
replacement keys. Use [Troubleshooting](TROUBLESHOOTING.md).

## 7. Install Mirror and the tablet components

Before starting, confirm the tablet still says Wi-Fi is **Connected**. Keep it
connected by USB and past the first post-boot unlock.

From the fully extracted installer folder, double-click `Install.cmd`.

The installer verifies `release.json`, the package signature and hashes,
installs the Windows app and runtimes, installs the tablet components, saves the
protected profile and wake token, and enables Developer Mode SSH over Wi-Fi.
It does not enable Developer Mode, bypass the passcode, or ask for the Wi-Fi
password.

Accept the Windows administrator/certificate prompt only after verifying the
package source. The current development package uses a release-specific
self-signed certificate added to **Local Machine > Trusted People**.

On success, the installer launches Mirror. If its terminal remains open, read
the last error before closing it. Do not rerun setup repeatedly without
understanding the failure.

Review the exact persistent footprint in [What Mirror changes](TABLET_CHANGES.md).

## 8. Connect over USB-C

Launching Mirror waits for you and does not contact the tablet.

1. Keep the data-capable cable attached.
2. Wake or unlock the tablet.
3. Choose **Connect USB-C**.
4. Wait for **Live over USB**.
5. Test **Touch + Type**, **Pen**, and the screenshot button.
6. Unlock the tablet, open **Files**, and confirm the library loads.

Files can wait while the tablet is passcode-locked even when display and input
are Live. Unlocking allows the stock Files service to start.

## 9. Connect over Wi-Fi and switch routes

1. Keep the tablet and PC on the same Wi-Fi network that you control.
2. Find the tablet's current IPv4 address in its Wi-Fi network details.
3. While USB is Live, click **Live over USB**.
4. Enter the tablet IPv4 address and choose **Connect**.
5. Wait for **Live over Wi-Fi**.
6. Test input, screenshots, and Files again.
7. Click **Live over Wi-Fi** to start the same bounded USB-C action.

You may leave the cable attached during a Wi-Fi attempt. Mirror tries only the
route you selected and never falls back, promotes, switches, or reconnects by
itself.

Use Wi-Fi Mirror only on a network you control. Guest/client-isolated networks
usually prevent direct access. Mirror never needs the Wi-Fi password.

## You are done when

- [ ] the app opens from Start and waits for a connection choice;
- [ ] **Connect USB-C** reaches **Live over USB**;
- [ ] Touch + Type, Pen, and screenshots work;
- [ ] Files loads while the tablet is unlocked;
- [ ] a small PDF or DRM-free EPUB can be imported;
- [ ] a document can be exported as PDF and native RMDOC;
- [ ] clicking **Live over USB** reveals the Wi-Fi address field;
- [ ] the entered address reaches **Live over Wi-Fi**; and
- [ ] clicking **Live over Wi-Fi** starts the USB-C switch.

## After a firmware update

A firmware update can switch the tablet to a root slot without Mirror's
components.

1. Do not repeatedly press **Repair**.
2. Confirm that the installed Mirror release explicitly supports the new
   tablet software.
3. Connect and unlock the tablet over USB.
4. Run that supported release's `Install.cmd` again.
5. Reopen Mirror and explicitly choose a connection.

Automatic root-slot repair is not implemented.

## Common app states

| State | Meaning | What to do |
| --- | --- | --- |
| **Choose USB-C or Wi-Fi** | Mirror is idle and has not contacted the tablet | Choose one route |
| **Preparing** | The owner-selected attempt is checking display and controls | Wait; unlock if asked |
| **Live over USB** | Display and input are ready through the cable | Click the status to enter a Wi-Fi address |
| **Live over Wi-Fi** | Display and input are ready through Wi-Fi | Click the status to attempt USB-C |
| **Repair** | Matching tablet components are missing or incompatible | Confirm firmware support, then rerun the matching installer over unlocked USB |
| Files is unavailable while Live | The tablet is locked or its stock Files listener is not ready | Unlock, leave Files open, or choose **Try Files Again** |

For symptoms and recovery, see [Troubleshooting](TROUBLESHOOTING.md).
