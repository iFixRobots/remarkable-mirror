# Windows setup

## What you need

- Windows 11 x64
- A reMarkable Paper Pro Move
- [PowerShell 7.5 or newer](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
- Windows **OpenSSH Client** from **Settings > System > Optional features**
- A data-capable USB-C cable

## Install Mirror

Download [`ReMarkableMirror-Windows-x64-portable.exe`](https://github.com/iFixRobots/remarkable-mirror/releases/download/v0.2.1/ReMarkableMirror-Windows-x64-portable.exe)
and open it. The portable app includes the tablet setup files it needs.

The release also includes a complete installer ZIP if you prefer a normal
Windows installation. Extract the whole ZIP and run `Install.cmd`.

## Already set up?

Do not reset the tablet again.

1. Connect the awake, unlocked tablet directly over USB-C.
2. Open Mirror and click **Start Setup**.
3. Mirror checks the saved key and installed tablet files.
4. Choose **Connect USB-C** or **Connect Wi-Fi**.

## New setup

Developer Mode factory-resets the tablet. Back it up and confirm your documents
appear in an official reMarkable app before you continue.

1. Follow reMarkable's [Developer Mode guide](https://developer.remarkable.com/documentation/developer-mode).
2. After the reset, sign in again, reconnect Wi-Fi, and wait for your documents
   to restore.
3. Unlock the tablet once after it starts.
4. Enable **Settings > General > Storage > USB web interface**.
5. Find the Developer Mode password under **Settings > General > Help > About >
   Copyrights and Licenses**.
6. Connect the tablet directly to the PC over USB-C and keep it awake and
   unlocked.
7. Open Mirror and click **Start Setup**.
8. Enter the Developer Mode password when asked and choose **Authorize &
   Install**.
9. When setup finishes, choose **Connect USB-C** or **Connect Wi-Fi**.

Mirror uses the password for that authorization attempt and does not save it.

## Connect over Wi-Fi

Put the PC and tablet on the same network, open the tablet's Wi-Fi details, and
copy its IPv4 address into Mirror. Mirror connects only when you choose
**Connect Wi-Fi**.

## If something goes wrong

Keep the tablet awake and unlocked, reconnect it directly over USB-C, and use
the action Mirror shows. After a tablet software update, that may be **Repair
Tablet Setup**.

See [Troubleshooting](TROUBLESHOOTING.md), [supported tablet software](PLATFORM_SUPPORT.md),
and [what Mirror changes](TABLET_CHANGES.md) for the details.
