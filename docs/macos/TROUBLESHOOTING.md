# macOS troubleshooting

Start with [macOS Getting started](GETTING_STARTED.md). The current app is an
unsigned development build. Its host-native setup can install or repair the
same complete tablet prerequisite set as Windows, but that full Mac mutation
path does not yet have a separately authorized fresh-tablet physical acceptance
run.

## macOS blocks the app

Current packages are unsigned and not notarized. In Finder, Control-click the
app, choose **Open**, and confirm **Open**.

Do not disable Gatekeeper system-wide or remove security attributes from other
apps. A public Mac release needs Developer ID signing and notarization.

## The build uses the wrong Xcode

Use the repository script, which selects stable Xcode, or verify it explicitly:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -version
```

See [Development](../DEVELOPMENT.md) for the pinned toolchain.

## The local installer refuses to continue

`Install-RemarkableMirrorMac.sh` does not overwrite an existing app. Quit the
installed build, move it aside, then run the installer again.

## Mirror reports a missing or mismatched prerequisite

Confirm that this Mac build explicitly supports the tablet model and software
version. Keep the tablet unlocked on direct USB, then choose **Repair Tablet
Setup**. Mirror uses the saved Mac key and the same audited tablet transaction
used for first installation.

If Mirror reports an unknown, unmarked, or incompatible Xovi tree, stop. Do not
bypass the capability check, overwrite owner-managed Xovi, or install unpinned
components manually.

## Setup cannot confirm USB-C

Mirror requires one direct data-capable cable before it captures a host key or
creates credentials.

1. Wake the tablet and complete its first passcode unlock after boot.
2. Reconnect the cable at both ends.
3. Use a direct Mac port and a cable known to carry data.
4. Choose **Retry Setup** for one new bounded check.

Cable appearance does not start tablet communication. Do not bypass the check
with an IP address or by disabling strict host-key verification.

## Setup asks for the tablet passcode

The cable was found, but the Developer Mode system did not answer. Enter the
passcode on the tablet, then choose the offered setup action again.

The tablet passcode is never sent to or stored by Mirror.

## Setup asks for the Developer Mode password

The direct-cable checks passed, but the tablet has not yet authorized this Mac.
The secure password sheet is the explicit persistent-change boundary.

Enter the generated root password and choose **Authorize & Install**. Mirror:

- appends its dedicated public SSH key;
- installs or repairs the probe, pinned Xovi runtime, three Mirror extensions,
  transport-wake service, and suspend guard through one verified transaction;
  prepares Developer Mode SSH over Wi-Fi; and
- uses the one-time Developer Mode root password without saving it.

If the result cannot be confirmed, choose **Continue Setup**. That explicit
action first proves any saved key, then resumes the incomplete stage. It never
reopens the password prompt by itself.

If a later tablet step fails, **Repair Tablet Setup** reuses that confirmed key
and the same pinned transaction. If Mirror instead says **Tablet setup can't
run**, the app bundle or a required macOS setup tool is missing or unsafe; quit
it and install a complete build rather than repeating the tablet action.

If Mirror says **Existing Xovi setup needs attention**, it found an unknown or
different owner-managed Xovi tree and left it unchanged. If it says **Existing
tablet setup needs attention**, an app-owned tablet path is a link or another
unsafe file type. Neither condition is fixed by Retry: back up and reconcile
the existing owner-managed Xovi installation before running Mirror again.

## Setup is waiting for Wi-Fi

The shared tablet components are installed, but the app could not finish
preparing Developer Mode SSH over Wi-Fi.

To continue:

1. Keep USB connected.
2. Put the Mac and tablet on the same network that you control.
3. Reconnect Wi-Fi from the tablet and wait until it says **Connected**.
4. Unlock the tablet if needed.
5. Choose **Continue Setup**.

Mirror verifies the current network context and Developer Mode Wi-Fi SSH. It
does not read or store the Wi-Fi password, read the SSID, request Location
Services, or append the SSH key again.

This final stage creates Mac-specific profile and Keychain state. It is not
copied from Windows. Success returns to the manual connection choices without
connecting.

## Connect Wi-Fi asks for an IP address

This is intentional. The first click changes only the local Mac presentation
and sends no tablet or network traffic. Enter the tablet's current IPv4 address
and choose **Connect Wi-Fi**.

The tablet must be awake but may remain locked. Submitting starts one bounded
Wi-Fi-only attempt to that address, bound to the current Wi-Fi context and
authenticated with the pinned tablet identity. Mirror may check a transiently
offline route every three seconds during a 45-second attempt. It does not
auto-discover or save the address, inspect or use USB, wake the tablet, fall
back to another route, call the wake HTTP endpoint, request a password, or
require an unlock.

## The saved setup needs attention

Mirror rejected a corrupt, unsupported, inconsistent, inaccessible, or insecure
local profile. **Set Up Again…** confirms before removing the app-owned local
profile, SSH files, and Keychain material.

It does not remove the already authorized tablet key, disable Developer Mode
Wi-Fi SSH, or remove tablet components. Removing the app bundle has the same
tablet-side limitation.

## Authentication succeeds but Live does not appear

`Live` requires a fresh frame and running input session from the same active
connection. SSH authentication alone is not enough.

Unlock the tablet if asked. If the selected session ends, choose
**Connect USB-C** or **Connect Wi-Fi** again; Mirror does not reconnect or
fall back automatically.

Use **Help > Copy Connection Diagnostics** for a sanitized state summary.
Review it before sharing.

## Files does not show documents

Files is separate from Live and starts only when you open it. It uses an
authenticated SSH forward to the tablet-loopback stock Files service.

- Unlock the tablet and leave Files open during its readiness window.
- If the window ends, choose **Try Files Again**.
- Do not reconnect the entire mirror solely to retry Files.

Closing Files ends its retry window.

## USB was disconnected or reconnected

Disconnecting USB retires that USB session. Reconnecting the cable does not
start another session or move an active Wi-Fi session.

- Choose **Connect USB-C** for a new cable session.
- Choose **Connect Wi-Fi** and enter the tablet address for a new Wi-Fi
  session.

Each action uses only the selected route.

While Live, click **Live over USB-C** to open the same Wi-Fi address prompt or
**Live over Wi-Fi** to start the same USB-C action. Canceling the address prompt
leaves USB-C Live.

## Keychain access fails

First-time setup stores the protected network-context secret and wake token in
the Data Protection Keychain. The manually entered address is session-only and
is not saved. USB-C does not use those secrets.

The current unsigned app has no production Team Identifier or proved
signed-package persistence. If Keychain cleanup fails, Mirror blocks local
reset instead of claiming that secret state was removed.

## The app will not quit

Normal termination waits for Mirror-owned frame, input, Files, and wake work to
retire. If cleanup fails, Mirror declines termination and shows a local warning
instead of leaving a possible child process behind silently.

Retry quitting and copy the sanitized diagnostics if the problem persists.
Mirror never uses `killall`, `pkill`, or process-name matching.
