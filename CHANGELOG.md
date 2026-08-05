# Changelog

Notable user-visible changes are recorded here.

## Unreleased

- Created the standalone GPL-3.0-only product repository.
- Added repeatable builds, contributor guidance, installation instructions,
  security reporting, and complete third-party attribution.
- Restricted the bearer-authenticated wake endpoint to tablet loopback and the
  direct USB interface.
- Documented the root SSH-over-WLAN and dedicated key security boundary.
- Replaced the fragmented first-run notes with an illustrated end-to-end Getting
  started guide and a self-contained package onboarding guide.
- Added GitHub Actions builds for a complete Windows installer and a portable
  Windows executable.
- Reduced the portable executable from 283.52 MiB to about 67 MiB by removing
  unused AI, machine-learning, Widgets, and ReadyToRun payloads and compressing
  the remaining self-contained runtime.
- Made clean-runner installer builds carry Mirror's matching .NET runtime and
  stopped uploading a duplicate expanded installer folder beside the release
  ZIP.
- Recorded owner-tested Pen input over Wi-Fi in installed Gold
  `1.2608.416.5801`.
- Tested automatic USB-to-Wi-Fi fallback and Wi-Fi-to-USB promotion on my tablet
  with Mirror left open. Touch + Type and Files worked after each connection
  settled.
- On the first USB-to-Wi-Fi handoff, Mirror reached Live, later entered a
  38-second host-side Disconnected interval, and then returned to Live
  automatically. The tablet journal showed no suspend, Wi-Fi loss, Xochitl
  sleep, reboot, or transport-wake event during that interval.
- Made retired frame streams stop promptly when a connection changes, the probe
  is cancelled, or the app closes normally.
- Made normal window close await connection shutdown while retaining the
  Windows Job Object as a crash fallback.
- Fixed PDF and DRM-free EPUB drag-in by matching the stock tablet importer's
  multipart header format. Upload diagnostics report the failure category and
  HTTP status without recording the document filename. Confirmed the corrected
  path over Wi-Fi; its USB repetition remains open.

No public binary version has been released yet.
