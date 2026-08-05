# Architecture

Mirror keeps the Windows product surface native and the tablet-side footprint
small. SSH is the authenticated control boundary for both USB and Wi-Fi.

```text
Windows WinUI app
  |
  +-- route monitor: USB preferred, Wi-Fi fallback
  +-- frame SSH session -------------------------+
  +-- input SSH session -----------------------+ |
  +-- Files local forward -------------------+ | |
  +-- USB-only wake client ----------------+ | | |
                                         | | | |
Tablet                                   | | | |
  +-- transport-wake service <----------+ | | |
  +-- rmmirror-probe ----------------------+ | |
  +-- session-only virtual input -----------+ |
  +-- Xovi framebuffer-spy/message broker ----+
  +-- Xovi Files loopback -> 127.0.0.1:80
```

## Windows host

The WinUI 3 application owns the window, route selection, connection state,
frame presentation, input routing, screenshots, and file-transfer UI.

One route generation owns all of its child processes. Switching routes cancels
the old generation before publishing the replacement. **Live** requires both a
fresh frame and a running input session from that same generation.

USB is preferred and paired Wi-Fi is the fallback. Promotion back to USB waits
for sustained passive health and until pointer input and Files operations are
idle.

## Frame capture

Xovi loads `framebuffer-spy` and `xovi-message-broker` for the connection. The
ARM64 probe reads the Paper Pro Move framebuffer stream, crops each 960-pixel
source row to the visible `954x1696` viewport, and streams BGRA frames over SSH.
Xovi is activated on demand; Mirror does not add a tablet boot hook for it.

The probe treats session signals and standard-input closure as cancellation.
The Windows host closes retired SSH streams and waits for connection shutdown
on normal app exit. Its Job Object remains the fallback for a crash or forced
termination.

## Input

Input is session-only. After SSH and display prerequisites are ready, the probe
hands Xochitl to virtual touch, pen, and keyboard devices. Closing the app or
losing the session removes those devices and restores stock physical input.

Every Mirror-owned Xochitl/Xovi start or restart first resets Xochitl's systemd
failure budget. This prevents repeated connection work from exhausting the stock
restart limit and selecting the tablet's emergency target.

## Files

Xochitl normally scopes its Files web service to the USB interface. The
GPL-3.0-only `rmmirror-files-loopback` extension changes that bind decision to
tablet loopback. Windows creates a strict authenticated SSH forward from a local
ephemeral port to `127.0.0.1:80`. It never exposes the bearer-authenticated
service directly on the Wi-Fi network.

Files is an independent capability. Xochitl closes its web service while
`userLocked` is true. Display and input can remain Live; the Files probe retries
and publishes readiness automatically after the owner unlocks the tablet.

Imports use the stock browser-style multipart form: an unquoted boundary and a
quoted `name="file"` and `filename="..."` without .NET's `filename*` extension.
Mirror accepts PDFs and DRM-free EPUBs up to the stock service's size limit.
Upload logs record the result category and numeric HTTP status, not the local
document filename.

## Sleep and wake

When USB carrier is present, a transport service prevents the specific
`suspend-then-hibernate` executor from completing while renewing Xochitl's
watchdog. It does not permanently mask sleep targets. Detach or uncertain carrier
state fails open to stock sleep.

The service's bearer-authenticated HTTP endpoint listens only on tablet
loopback and the direct USB interface. It does not bind the Wi-Fi interface.
The Windows pre-SSH wake path pins its socket to the direct USB adapter;
loopback is available only on the tablet or through authenticated SSH
forwarding.

Deep Linux suspend removes Wi-Fi reachability. Mirror cannot send a network
request to a radio that is no longer associated. The current product gives clear
physical-wake/USB guidance and reconnects automatically when the tablet returns.

## Trust boundaries

- SSH host identity is pinned once over direct USB and reused for Wi-Fi through
  `HostKeyAlias=10.11.99.1`.
- Wi-Fi is accepted only on the paired Windows network identity.
- Wake bearer traffic stays on verified direct USB or tablet loopback; loopback
  is reachable remotely only through authenticated SSH forwarding.
- Credentials, device profiles, screenshots, and documents stay on the local
  Windows account unless the user explicitly saves or transfers them.
