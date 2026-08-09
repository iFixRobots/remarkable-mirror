# macOS Troubleshooting

This page covers the private native Mac candidate through the Milestone 6 source
boundary. It builds as a single production target under stable Xcode 26.6. The
last audited Release package has a recorded archive audit and binary match with
the installed app. On 2026-08-08, one owner-started USB-C connection reached
Live on the physical tablet with a real frame and persistent authenticated
frame, input and Files processes. The same session recovered Files after an
owner-authorized unlock and loaded a 7-item root listing without reconnect
or pane reopen. A later clean **Command-Q** retired all active owned children
without an orphan or AppKit exception. Wi-Fi and the release package remain
separate proof boundaries.

## The wrong Xcode builds the app

The Mac may globally select a beta Xcode. Use the repository build script or
pass the stable toolchain explicitly:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -version
```

The Release scripts select Xcode 26.6 with Swift 6.3.3. The current source
builds as a single production target under that toolchain. The last audited
Release build predates the current recovery and presentation changes.

## macOS blocks the app

A locally packaged review candidate would be unsigned and not notarized. Open
it from Finder's context menu and confirm **Open**. Do not remove security
attributes from other apps or disable Gatekeeper system-wide.

## The installer refuses to continue

`Install-RemarkableMirrorMac.sh` will not overwrite an existing app. Quit and
move the earlier candidate aside explicitly, then rerun the script.

## Setup says to use the tablet's USB-C connection

Mirror could not confirm the tablet through the directly connected USB-C data
cable. The app intentionally does not contact an unverified device or create
credentials.

- Enter the tablet passcode if it asks for one.
- Reconnect the USB-C cable at both ends.
- Use a known data-capable cable and a direct Mac port where possible.
- Choose **Retry Setup** to make one new check.

Do not bypass the check by entering an address or disabling strict host-key
verification. If the warning persists, choose
**Help > Copy Connection Diagnostics**.
That report contains fixed event codes and timestamps, not raw network output,
addresses, keys, or SSH output.

## Setup is waiting for USB-C

Mirror cannot see the tablet through the direct USB-C data cable. Reconnect the
cable, enter the tablet passcode if requested, then choose **Retry Setup**. Cable appearance
does not start tablet communication. If Mirror already confirmed the connected
tablet but it did not answer, the app explains what the current setup step needs.

## The app says USB data is blocked

The Mac can see the attached device, but the direct USB-C data connection is not
available. Keep both devices unlocked, reconnect a known data-capable USB-C
cable directly, then choose the action shown for the current step again. Mirror
does not keep checking or continue automatically.

## Setup asks for the tablet passcode

Mirror confirmed the tablet through the cable, but the tablet did not answer
before initial setup could finish. This does not mean the cable is absent. Enter
the passcode on the tablet, then choose the offered USB-C setup action again.

## The app offers Add This Mac…

Mac-side preparation finished and the local profile is pending. No tablet
change has been made yet. **Add This Mac…** is the explicit persistent-change
boundary: after the exact direct-USB checks pass again, it appends this app's
dedicated public key and installs or upgrades the tablet-side USB keep-awake
service, including its wake lock and sleep guard. The confirmation opens
without inspecting the Mac's Wi-Fi connection and uses the tablet's
one-time root password without saving it. It does not change documents or the
Wi-Fi password. The authorization submission is bounded. If its outcome cannot
be confirmed, Mirror stops at **Check Authorization**; that action makes one
bounded key-only check and never reopens the password prompt by itself.

## Mirror cannot verify the Wi-Fi connection

Keep Wi-Fi enabled on the Mac, connect the Mac and tablet to the intended local
network, keep USB connected, and choose **Connection > Set Up Wi‑Fi…** again.
Mirror checks the current Wi-Fi connection without reading the network name or
requesting Location Services. If that bounded operation cannot finish, the app
returns to an action instead of continuing in the background.

## Wi‑Fi setup is still pending

The dedicated key was authorized and the tablet-side USB keep-awake service was
installed or upgraded and validated. Persistent Wi‑Fi setup is intentionally a
separate step, but it does not gate the manual IP connection path. The current
connection card still shows **Connect USB‑C** followed by
**Connect via Wi‑Fi**. The latter asks for an IPv4 address and uses it only for
that owner-started attempt; it does not complete or persist Wi-Fi setup. To
complete the separate persistent setup, keep USB connected, enter the tablet
passcode if requested, keep both devices on the intended Wi‑Fi network, and
choose **Connection > Set Up Wi‑Fi…**.

## The app says the saved setup needs attention

Mirror rejected a corrupt, unsupported, inconsistent, inaccessible, or
insecure local profile. **Set Up Again…** presents a confirmation before
removing Mirror's app-owned local profile, key and Keychain material. It does
not remove a public key already authorized on the tablet or disable Developer
Mode SSH over Wi-Fi.

## A connected tablet does not appear Live

Successful host authentication alone stops at **Secure connection ready**.
Mirror publishes **Live** only after it accepts a fresh frame and a running input
session from the same active connection. If either owned process stops or that
session ends, the app removes Live and returns to the disconnected
surface instead of leaving stale controls enabled. Choose
**Help > Copy Connection Diagnostics** if needed, then explicitly choose
**Connect USB‑C** or **Connect via Wi‑Fi**.

## Connect via Wi‑Fi asks for the tablet IP address

This is intentional. **Connect via Wi‑Fi** sits directly below
**Connect USB‑C**. Its first click changes only the local Mac presentation and
sends no tablet or network traffic. The prompt says the tablet must be awake but
may remain locked and asks for its IPv4 address. Submitting starts one bounded
Wi-Fi-only attempt to that exact address, bound to the current Wi-Fi context and
authenticated with the saved pinned SSH identity. Mirror checks a transiently
offline route every three seconds during a 45-second retry window. A bounded
check already admitted may finish afterward, but no new retry starts. The
attempt does not auto-discover or save an address, inspect or use USB, wake the
tablet, fall back to another transport, call the wake HTTP endpoint, request a
password, or require an unlock. If it ends without connecting, Mirror returns to
the same two manual choices. Files remains separate and may still require the
tablet to be unlocked.

## Files does not show tablet documents

Files is implemented, but it is a separate capability from Live. It remains
disconnected until the loopback-only SSH forward is listening and the stock
tablet service responds. Open Files once to start its 60-second readiness window.
If the tablet is locked, unlock it and leave the current USB session and Files
pane open. Mirror retries the exact current capability during that window; on
the 2026-08-08 physical run it recovered to a 7-item root listing without a
reconnect or pane reopen. Closing Files or reaching the deadline stops those
attempts. If the window has expired, choose the circular-arrow action labeled
**Try Files Again** to start a fresh 60-second owner window; you do not need to
close and reopen Files. Once the library is available, that same action becomes
**Refresh** and reloads the listing. PDF and native RMDOC Save As are physically
exercised. Import or upload, delete and Finder drag-out remain separate proof
boundaries.

## USB disconnected

Disconnecting USB ends that USB session. Mirror does not switch to Wi-Fi
automatically. To continue over Wi-Fi, keep the Mac and tablet on the same local
network, make sure the tablet is awake, and choose **Connect via Wi‑Fi**. The
first click is local only; enter the tablet’s IPv4 address and submit it to start
the bounded Wi-Fi-only attempt. The tablet may stay locked. A Wi-Fi identity mismatch does not bypass
the trust checks. To continue over USB, reconnect the cable and choose
**Connect USB-C**. That one click owns the bounded direct-cable wake, recovery,
authentication, and connection session; the owner intervenes only if the tablet
asks for its passcode.

## USB reconnected but Mirror did not connect

This is intentional. USB appearance never starts tablet communication or moves
an active Wi-Fi session. End the current connection if necessary, then choose
**Connect USB‑C**. That click stays on the direct cable, wakes and recovers the
tablet as needed, authenticates, and connects without selecting Wi-Fi.

## Keychain access fails

Only explicit persistent Wi-Fi setup stores the protected Wi-Fi context secret
and wake token in the Data Protection Keychain. The address entered through
**Connect via Wi‑Fi** is session-only and is not saved; USB-C never requires
either Keychain value. The current
app is unsigned and has no proved Team Identifier or
access-group policy, so service scoping and signed-package persistence remain
unproven. If Keychain cleanup fails, Mirror blocks local setup reset rather than
leaving secret state behind while claiming a clean reset.

## The app will not quit

Normal termination waits for Mirror-owned child processes to retire. If that
bounded cleanup fails, the app declines termination and shows a local warning
instead of claiming success while a child may remain. Retry quitting and copy
the sanitized connection details if it persists. On 2026-08-08, **Command-Q**
with active frame, input and Files children retired every owned process, left
no orphan and produced no AppKit exception. Mirror never uses `killall`,
`pkill`, or process-name matching.
