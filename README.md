# reMarkable Mirror

I built reMarkable Mirror so I could use my Paper Pro Move from a real desktop
app. It mirrors the tablet over USB-C or Wi-Fi and gives you mouse, keyboard,
pen, screenshots, and Files.

<p align="center">
  <img src="docs/images/remarkable-mirror-live-wifi.png" width="558" alt="reMarkable Mirror connected to a Paper Pro Move over Wi-Fi">
</p>

## Download

- **Windows 11:** download [`ReMarkableMirror-Windows-x64-portable.exe`](https://github.com/iFixRobots/remarkable-mirror/releases/download/v0.2.3/ReMarkableMirror-Windows-x64-portable.exe) and open it.
- **macOS 14 or newer on Apple silicon:** download [`reMarkable-Mirror-0.2.3-macOS-arm64.dmg`](https://github.com/iFixRobots/remarkable-mirror/releases/download/v0.2.3/reMarkable-Mirror-0.2.3-macOS-arm64.dmg), open it, and drag reMarkable Mirror to Applications.

All versions and their SHA-256 checksums are on the [releases page](https://github.com/iFixRobots/remarkable-mirror/releases).

Windows also needs [PowerShell 7.5 or newer](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
and the Windows **OpenSSH Client** optional feature.

macOS blocks the first launch because the app is not notarized: click
**Done** (not Move to Trash), open **System Settings > Privacy & Security**,
scroll to the bottom, click **Open Anyway** next to reMarkable Mirror, then
confirm **Open Anyway** in the prompt.

Mirror currently supports the **reMarkable Paper Pro Move** only, and pairs
with one tablet at a time. Setup has been tested on reMarkable software
**3.27.1.0**, **3.28.0.164**, and **3.28.0.166**; other versions are not
blocked — if setup fails on yours, the app says exactly where, and PRs adding
support are welcome. To switch tablets, use **Connection > Set Up
Again…** and run setup for the other tablet.

## Start here

If this computer and tablet were already set up with Mirror, do not reset the
tablet. Connect it directly over USB-C, keep it awake and unlocked, open Mirror,
and click **Start Setup**. Mirror checks the existing setup and takes you to
**Connect USB-C** or **Connect Wi-Fi**.

For a new tablet setup:

1. Download Mirror before changing anything on the tablet.
2. Open Mirror and click **Start Setup**. The walkthrough guides everything
   from here, starting with a USB-C backup of the tablet's documents before
   anything is erased.
3. Enable [Developer Mode](https://developer.remarkable.com/documentation/developer-mode)
   when the walkthrough says so. This factory-resets the tablet.
4. Sign in again, reconnect Wi-Fi, skip any software update it offers, unlock
   the tablet once, and turn **Settings > Storage > USB web interface** back
   on.
5. Connect the tablet directly to the computer with a data-capable USB-C
   cable and continue the walkthrough.
6. Enter the one-time Developer Mode password when Mirror asks for it, and
   click **Allow** when macOS asks to let Mirror find devices on the local
   network.
7. Choose **Connect USB-C** or **Connect Wi-Fi**. To put backed-up
   documents back, use **Connection > Restore Backup…**.

That is the whole setup. You do not need to copy SSH keys, run tablet commands,
or paste a PowerShell script.

## What it does

- Mirrors the Paper Pro Move display in a compact native window
- Sends mouse, keyboard, pen, and eraser input while a session is active
- Copies screenshots or saves them as PNG files
- Imports PDFs and DRM-free EPUBs
- Exports PDFs and native RMDOC files
- Backs up the tablet's documents before setup and restores them after
- Opens the tablet's Files service through the existing SSH connection
- Switches between direct USB-C and local Wi-Fi when you choose it

Everything runs locally between your computer and the tablet.

## Help

- [Windows setup](docs/GETTING_STARTED.md)
- [macOS setup](docs/macos/GETTING_STARTED.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Supported tablet software](docs/PLATFORM_SUPPORT.md)
- [What Mirror changes on the tablet](docs/TABLET_CHANGES.md)
- [Uninstall status](docs/UNINSTALL.md)

## Build it yourself

Windows:

```powershell
$project = 'mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj'
dotnet restore $project --configfile mirror\windows\NuGet.config --locked-mode `
    -p:PublishProfile=win-x64-portable.pubxml
dotnet publish $project --configuration Release --no-restore `
    -p:PublishProfile=win-x64-portable.pubxml `
    -o artifacts\remarkable-mirror-portable
```

macOS:

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The Mac package appears under `artifacts/macos/package/`. Contributor setup and
toolchain details are in [Development](docs/DEVELOPMENT.md).

## About

reMarkable Mirror is independent community software. It is not affiliated with,
endorsed by, or supported by reMarkable AS.

The project is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE) and
[third-party notices](THIRD_PARTY_NOTICES.md).
