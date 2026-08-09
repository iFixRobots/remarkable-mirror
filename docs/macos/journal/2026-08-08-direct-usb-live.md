# Direct USB-C Live checkpoint — 2026-08-08

This checkpoint supersedes the earlier same-day cable and repair observations.
Those failures were application and tablet-service defects, not evidence that
either tested USB-C cable was charge-only.

## Exercised path

- Built the single production Mac target for arm64 Debug with stable Xcode 26.6.
- Kept one Paper Pro Move physically attached by USB-C.
- Launched the real product with its durable pending-Wi-Fi profile.
- Chose **Connect USB-C** once.
- The app moved through authenticated preparation to **Live over USB-C**.
- The real tablet frame rendered in the fixed product window.
- The authenticated input session completed its ready handshake and remained
  alive with protocol heartbeats.
- The frame stream and loopback-only Files SSH forward remained attached.
- Files was opened before the connection while the tablet was locked.
- With the owner's authorization, the passcode was entered through the mirrored
  tablet UI. The same USB generation recovered within the owner-opened bounded
  readiness window and loaded a 7-item root listing without reconnecting or
  reopening Files.
- Touch + Type and Pen were each selected with one click during the earlier
  pass, then Touch + Type was restored.
- A later **Command-Q** with active frame, input and Files children retired every
  owned process. No orphaned forward remained, and the final unified-log check
  contained no AppKit exception.

Direct USB-C admission, status and wake used the exact verified cable and did
not read a Keychain bearer or inspect Wi-Fi. The owner-authorized passcode was
used only through the visible tablet UI; it was not recorded in this checkpoint.

## Fixed causes

- Short interactive pipe reads now use one blocking `read(2)` call, so the
  tablet input handshake is delivered before its heartbeat deadline instead of
  being held until EOF.
- USB data qualification now accepts carrier `1` or exactly one configured UDC,
  while retaining the power-after-data latch and fail-open unknown state.
- Installer success now requires an operational hold rather than accepting an
  idle service that the Mac immediately rejects.
- Mac USB status and wake use the cable-authorized endpoint directly; Wi-Fi
  bearer persistence is reserved for explicit Wi-Fi setup.
- The direct-cable listener is bound to `usb0` on Linux in addition to checking
  its fixed local and peer endpoints.
- Files readiness now belongs to one exact owner-open request. The bounded
  window starts when the current generation has an eligible capability, and
  pane close or deadline prevents further retry work.
- Modifier-only AppKit events no longer read key-event character data. This
  removed the `flagsChanged` exception reached by Command-Q while preserving
  local shortcut routing and clean generation shutdown.

## Not proved by this checkpoint

- a physical touch, pen, eraser or keyboard event changing the tablet;
- screenshot copy or save;
- Files import, export, open, delete or Finder drag-out;
- an actual power event from a fully deep-sleeping tablet;
- short-sleep recovery;
- Wi-Fi setup or connection;
- Data Protection Keychain persistence in an authorized signed package;
- Developer ID signing, notarization, hosted artifacts, release, Gold or owner
  acceptance.

## Same-day product follow-up

Later current-worktree product runs extended the physical boundary without
changing the historical checkpoint above:

- Clipboard screenshot copy and Save As each produced a valid `954 x 1696` PNG.
- Files loaded seven root items, navigated into a folder and back, exported a
  valid PDF, and exported a valid native RMDOC ZIP archive with a single
  `.rmdoc` suffix.
- The exact final request-identity build opened Files before connection, reached
  Live while the tablet was locked, exposed enabled **Try Files Again** with the
  unlock instruction, and recovered to seven items after unlock without closing
  the pane or reconnecting.
- A Touch tap opened tablet search, committed keyboard text appeared on the
  tablet, and a Pen tap opened the same target. A bundled tutorial opened and
  closed normally.
- The Mac input queue previously replaced adjacent motion even below capacity.
  After removing that unconditional replacement, a focused continuous drag with
  40 motion events advanced the bundled tutorial from page 3 to page 4 on the
  physical tablet. The persisted library position confirmed the page change.
- One explicit USB-C connection brought a previously unreachable locked tablet
  back to its passcode. This is wake/recovery evidence, not authoritative proof
  that the exact `deep_sleep` handshake and guarded power event ran.
- Clean product quits retired all owned children without an orphan. A separate
  debugger-forced process termination created one orphaned forward; it was
  identified and terminated explicitly and is not counted as a product quit.

The remaining physical gaps are import or upload, delete, Finder drag-out, pen
stroke, eraser/right-click, short-sleep recovery, the exact fully-deep-sleep
power event, Wi-Fi, authorized signed-package Keychain persistence, Developer
ID signing, notarization, hosted artifacts, release, Gold and owner acceptance.
