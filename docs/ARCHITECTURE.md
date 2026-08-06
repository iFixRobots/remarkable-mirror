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

Mirror sends an SSH keepalive every three seconds and tolerates two unanswered
probes before the third ends a persistent session. Frame and input paths treat
that timeout as reconnectable instead of turning one brief Wi-Fi pause into a
persistent failure.

Package setup uses a gated PowerShell launcher assigned to a Windows Job Object
before it may start the target process. Its JSON payload now travels through
standard input instead of being embedded in `-EncodedCommand`. This keeps the
launcher command fixed-size when the remote setup script grows and avoids the
Windows command-length limit. A payload-transfer failure terminates and verifies
the owned process tree.

## Frame capture

Xovi loads `framebuffer-spy` and `xovi-message-broker` for the connection. The
ARM64 probe reads the Paper Pro Move framebuffer stream, crops each 960-pixel
source row to the visible `954x1696` viewport, and streams BGRA frames over SSH.
Xovi is activated on demand; Mirror does not add a tablet boot hook for it.

The probe treats session signals and standard-input closure as cancellation.
The Windows host closes retired SSH streams and waits for connection shutdown
on normal app exit. Its Job Object remains the fallback for a crash or forced
termination.

Every frame SSH generation also has its own lease. Windows writes one pulse
immediately and then every three seconds. The probe expires the generation
after 15 seconds without a pulse and exits without waiting for a frame write
that may be blocked on a dead connection. Windows treats that timeout as a
reconnectable stream interruption.

During an upgrade, the prerequisite installer retires only the exact probe
processes running `stream`. Input and its watchdog are outside that match.

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

Files can export documents as PDF or native RMDOC. Dragging a document row out
of Mirror starts synchronously: `DragStarting` registers a delayed Windows
`StorageItems` provider and returns without contacting the tablet or showing a
preparation state. Explorer asks that provider for the file when it needs the
payload. Mirror then creates a human-named PDF in the current user's local app
cache on a worker thread and supplies it with copy-only semantics. This avoids
blocking the native drag transaction on tablet I/O or a brokered `StorageFile`
handoff. A private drag marker prevents Mirror's own import target from
accepting that same outbound file. A drag canceled before the provider is
requested creates no file; partial or canceled work is removed immediately.
Export requests share a cancellation-aware gate. If a canceled provider is
still unwinding, its replacement waits under the new provider's Windows
deadline instead of failing busy; the visible drag has already started.
Accepted files are kept briefly so the destination can finish reading them,
and abandoned cache entries are swept on a later launch. Native RMDOC import is
not implemented.

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

The installer defines this service as static and publishes its
`multi-user.target` dependency under `/usr/lib/systemd/system`, because this
tablet's `/etc` overlay is volatile across reboot. It verifies both the exact
link and the dependency loaded by systemd. A firmware update can activate a
different root slot, which may need the matching components installed again.

Deep Linux suspend removes Wi-Fi reachability. Mirror cannot send a network
request to a radio that is no longer associated. The current product gives clear
physical-wake/USB guidance and reconnects automatically when the tablet returns.

## Release package

Release builds disable Mirror-owned PDB/CodeView output while Debug builds keep
their symbols. Before signing, the package builder inspects the app DLL and EXE
and stops if either embeds a rooted application CodeView path or the current
repository or user-profile root. The SDK-provided native apphost may retain its
own framework build provenance; it is not a path produced from this checkout.

The installer package also requires the complete public onboarding, Getting
started, and Troubleshooting guides plus all three app screenshots. A missing
guide or image stops the build; there is no shorter guide fallback.

## Trust boundaries

- SSH host identity is pinned once over direct USB and reused for Wi-Fi through
  `HostKeyAlias=10.11.99.1`.
- Wi-Fi is accepted only on the paired Windows network identity.
- Wake bearer traffic stays on verified direct USB or tablet loopback; loopback
  is reachable remotely only through authenticated SSH forwarding.
- Credentials, device profiles, screenshots, and documents stay on the local
  Windows account unless the user explicitly saves or transfers them.
