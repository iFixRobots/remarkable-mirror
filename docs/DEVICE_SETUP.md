# Device setup

First setup requires a direct USB-C connection. Mirror can use Wi-Fi afterward.

## 1. Back up before Developer Mode

Developer Mode factory-resets the Paper Pro Move. Save the tablet content you
care about before enabling it. Use reMarkable's supported sync/export paths or
the stock USB web interface while it is still available.

The official starting point is reMarkable's
[Developer Mode documentation](https://developer.remarkable.com/documentation/developer-mode).

## 2. Enable Developer Mode

Follow the instructions shown by reMarkable for your tablet and software
version. Let the reset and first boot finish, then enter the tablet passcode once.

The reset removes saved Wi-Fi networks. Reconnect the tablet to Wi-Fi from the
tablet UI before wireless Mirror use.

For the Files drawer, enable **General settings > Storage > USB web interface**
on the tablet after setup.

## 3. Prepare Windows

Install PowerShell 7.5 or newer and confirm the Windows OpenSSH client exists:

```powershell
pwsh --version
Get-Command ssh.exe, ssh-keygen.exe, ssh-keyscan.exe
```

Connect the unlocked tablet directly over USB-C. The Developer Mode USB address
is `10.11.99.1`.

## 4. Create a dedicated SSH key

Mirror defaults to a dedicated Ed25519 key and known-hosts file:

```powershell
$key = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'

New-Item -ItemType Directory -Path (Split-Path $key) -Force | Out-Null
ssh-keygen.exe -t ed25519 -f $key -C 'remarkable-mirror' -N ''
ssh-keyscan.exe -t ed25519 10.11.99.1 | Set-Content -LiteralPath $knownHosts -Encoding ascii
```

The empty `-N` value deliberately creates this dedicated key without a
passphrase. Mirror starts OpenSSH with `BatchMode=yes`, so it cannot stop to ask
for a key passphrase. Do not reuse this key. Anyone who obtains it can
authenticate as root to the paired Developer Mode tablet, so protect the
Windows account and its `.ssh` directory.

The host-key scan is intentionally performed only across the direct physical
USB link. Review the scanned fingerprint before trusting it:

```powershell
ssh-keygen.exe -lf $knownHosts
```

## 5. Install the public key

Use the root password shown by the tablet's Developer Mode interface for this
one command:

```powershell
Get-Content -LiteralPath "$key.pub" |
    ssh.exe -F NUL `
        -o "UserKnownHostsFile=$knownHosts" `
        -o StrictHostKeyChecking=yes `
        root@10.11.99.1 `
        'umask 077; mkdir -p /home/root/.ssh; cat >> /home/root/.ssh/authorized_keys'
```

Verify key-only authentication:

```powershell
ssh.exe -F NUL `
    -i $key `
    -o BatchMode=yes `
    -o IdentitiesOnly=yes `
    -o "UserKnownHostsFile=$knownHosts" `
    -o StrictHostKeyChecking=yes `
    root@10.11.99.1 true
```

Keep the private key on this Windows account. Never add it to this repository.

## 6. Run the installer

There is no official public binary release yet. Build a development package as
described in [Development](DEVELOPMENT.md), extract its ZIP, and run
`Install.cmd`. Keep the tablet connected and unlocked until setup finishes.
Setup installs matching tablet companions and records a protected local device
profile for USB and Wi-Fi routing.

The installer runs the tablet's `rm-ssh-over-wlan on` command and verifies the
root `dropbear-wlan.socket`. This is what makes Wi-Fi Mirror possible. It means
the tablet accepts root SSH on its trusted Wi-Fi network using the dedicated
key above. Mirror never needs the Wi-Fi password, but the root SSH service is a
real security boundary. Use wireless Mirror only on a network you trust. Wi-Fi
Mirror cannot work while root SSH-over-WLAN is disabled.

The installer never needs the Wi-Fi password. Enter Wi-Fi credentials only on
the tablet.

## After firmware updates

The tablet uses A/B root slots. A firmware update can switch to a root that does
not contain Mirror prerequisites. If the app asks for repair after an update:

1. connect over USB-C;
2. unlock the tablet;
3. run `Install.cmd` again; and
4. open Mirror after setup completes.

Manual re-provisioning is supported. Fully automatic repair after a root-slot
switch is not yet a shipped capability.
