# Mirror input protocol

Mirror input is owned by one SSH session. Windows starts
`rmmirror-probe input --heartbeat-timeout 15s` after SSH becomes reachable; the
helper creates the temporary Linux input devices, serves newline-delimited JSON
over that process's standard input and output, and tears everything down at EOF.
There is no boot service, Unix socket, Xochitl systemd dependency, or udev rule.

Only one helper can own input at a time. It holds
`/run/rmmirror-input.lock` for its lifetime and rejects an overlapping session
with `input_session_busy`.

## Device handoff and recovery

Xochitl must discover the virtual pen during startup for synthetic pen strokes
to render. Each input connection therefore performs this bounded handoff:

1. Open the physical Elan marker and create the virtual touch, pen, and keyboard.
2. Start a detached cleanup watchdog.
3. Stop Xochitl, briefly bind `/dev/null` over `/dev/input/event2`, and start
   Xochitl so it selects the virtual pen.
4. Verify that Xochitl holds the virtual pen and not the physical marker, then
   immediately remove the bind mount.
5. Relay complete physical-marker frames into the virtual pen for the rest of
   the session.

Normal EOF releases held input, stops Xochitl, destroys the virtual devices,
and restarts Xochitl against the physical marker. If the SSH helper crashes or
is killed, the detached watchdog takes the lock, removes any remaining bind
mount, restarts Xochitl, and verifies that it reopened the physical marker.
The tablet still boots and runs normally when Mirror is not connected.

Every Mirror-owned Xochitl start or restart first executes
`systemctl reset-failed xochitl.service`. This covers the initial handoff,
normal restoration, and detached-watchdog restoration. If that reset fails,
the action is blocked and returns `xochitl_restart_budget_reset_failed`.
Connection-time Xovi activation and stock rollback apply the same ordering. This
prevents Mirror from exhausting Xochitl's stock four-start budget and entering
its emergency reboot path.

Every received protocol line renews a 15-second lease. Windows sends a `ping`
at least every three seconds while idle. Missing heartbeats close the session
and run the same cleanup path.

## Host sequencing and retry boundary

Display capture and input both involve Xochitl, so the Windows host serializes
them instead of letting independent retry loops restart the process underneath
one another:

1. Run `input-ready --restore-timeout 50s` before connection-time display
   preparation. This barrier waits for a stale helper/watchdog to finish
   restoring the physical marker.
2. Prepare the Xovi-backed display. Xovi is installed during package setup but
   is started only here, for a Mirror connection; it is never a boot service.
3. Start one input helper for the current connection generation and wait for its
   ready handshake. Startup is bounded at 100 seconds.
4. Revalidate the display after the input handoff's deliberate Xochitl restart,
   then open the frame stream.
5. Publish `Live` only after both a fresh frame and a running input session from
   that same generation. Graceful restoration is bounded at 100 seconds.

One automatic input recovery is available per connection generation in total.
If a transient input failure occurs before `Live`, the host first confirms
cleanup/restoration, rebuilds both display and input-ready barriers, and then
retries once. If an established session loses input, it uses the same remaining
one-shot allowance; input and display recovery are coupled regardless of which
loss is observed first, and `Live` cannot return until the replacement input
session is running and a frame newer than the loss has arrived. A second
failure, a persistent failure, or uncertain cleanup/restoration stops automatic
recovery and requires explicit `Retry`. Mirror never publishes a frame-only
session as `Live`.

A missing first frame is bounded at 10 seconds. After four consecutive
auto-retryable display failures, the host stops background retries and requires
the explicit `Retry` action. Retry fences the old display and input generation,
waits for physical restoration, and only then publishes the next attempt.

## Handshake

The helper writes this first line only after the handoff is complete:

```json
{"schema":"rmmirror.input/v1","ready":true,"display_state":"unknown","touch":{"x_max":1248,"y_max":2208},"pen":{"x_max":6760,"y_max":11960},"text":"us-ascii"}
```

The successful handoff has just restarted Xochitl, invalidating any
pre-restart journal state, so the current helper reports `display_state` as
`unknown`. Windows sends no wake event for `normal` or `unknown`. If a future
transport can authoritatively
report `deep_sleep`, Windows allows one atomic `KEY_POWER` click. It uses an
atomic `KEY_F12` click after 45 seconds without user input to keep an
already-unlocked display awake. Periodic `KEY_POWER` events are not used.

The helper creates:

- a direct, single-contact type-B touchscreen with `X=0..1248`, `Y=0..2208`,
  and pressure `0..255`;
- a pen with `X=0..6760`, `Y=0..11960`, pressure `0..4096`, distance
  `0..65535`, tilt `-9000..9000`, and no `INPUT_PROP_DIRECT`, matching the
  physical Elan marker profile used by Xochitl;
- a virtual keyboard exposing the keys accepted below.

## Commands

Each command is one JSON object followed by `\n`. It needs a non-zero integer
`id`. Coordinates and pressure are normalized values in the inclusive range
`0..1`.

```json
{"id":1,"type":"touch","action":"down","x":0.25,"y":0.50,"pressure":1.0}
{"id":2,"type":"touch","action":"move","x":0.30,"y":0.55}
{"id":3,"type":"touch","action":"up"}

{"id":4,"type":"pen","action":"down","x":0.25,"y":0.50,"pressure":0.5,"tool":"pen"}
{"id":5,"type":"pen","action":"move","x":0.30,"y":0.55,"pressure":0.6}
{"id":6,"type":"pen","action":"up"}

{"id":7,"type":"key","action":"down","key":"KEY_A"}
{"id":8,"type":"key","action":"up","key":"KEY_A"}
{"id":9,"type":"key","action":"click","key":"KEY_F12"}
{"id":10,"type":"text","text":"Hello, reMarkable!\n"}

{"id":11,"type":"reset"}
{"id":12,"type":"ping"}
```

`touch` and `pen` require coordinates for `down` and `move`; `up` ignores them.
Pressure defaults to full touch pressure and half pen pressure. A pen `down`
accepts `tool` as `pen` or `eraser`; later moves retain that tool.

`key` accepts Linux names with or without `KEY_` for letters, digits,
punctuation, modifiers, navigation keys, and F1 through F12. `click` performs
the down/up pair inside one server command and resets held state if release
fails. Repeated `down` commands emit Linux key-repeat value `2`.

`text` validates the full string before typing it. It supports printable US
ASCII plus tab, backspace, CR, and LF. `reset` releases active touch, pen, and
keyboard state. EOF and heartbeat expiry perform the same release before
device cleanup.

## Responses

Responses preserve ordering and echo the command ID:

```json
{"id":1,"ok":true}
{"id":2,"error":"invalid_coordinates"}
```

Rejected commands do not terminate the session. Diagnostic text is written to
stderr and never shares the protocol stream. If Windows cancels a command after
writing it but before receiving the response, it discards the SSH process so a
later response cannot be paired with the wrong command.

## Current boundary

Input remains single-contact; two-finger gestures and Unicode/IME text are not
encoded yet. The host presents `Touch + Type` and `Pen`; hardware keys are
automatic while the mirrored page owns focus, without changing this concurrent
protocol.

The current implementation provides virtual touch and keyboard input over USB
and Wi-Fi, the physical-marker relay, graceful physical input restoration,
short-sleep recovery, and the rule that `Live` requires both current input and a
current frame. The restart-budget reset and bounded retry policy protect
Xochitl's stock start limit. The current-generation publication rule prevents
recovery from silently publishing a frame-only session.

Pen input works over both USB and Wi-Fi in the tested setup. Killed-helper
watchdog restoration from a downloadable build, multi-touch, Unicode/IME input,
other tablet models, and firmware versions without release evidence remain
outside the current support claim. Runtime admission is capability-based;
release notes must still say exactly which paths were tested for that release.

The event/device mechanics follow the Linux kernel's
[uinput interface](https://kernel.org/doc/html/latest/input/uinput.html) and
[type-B multitouch protocol](https://kernel.org/doc/html/latest/input/multi-touch-protocol.html).
