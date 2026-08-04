# Changelog

Notable user-visible changes are recorded here.

## Unreleased

- Created the standalone public GPL-3.0-only product repository.
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

No public binary version has been released yet.
