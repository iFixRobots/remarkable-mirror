# Repository instructions

This repository contains the public reMarkable Mirror product only.

## Before changing code

Read `README.md`, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, and the nearest
component README.

## Rules

- Never commit tablet credentials, tokens, keys, captures, document data,
  diagnostics, device identifiers, or personal network details.
- Do not claim a path is tested unless that exact path was exercised.
- Keep virtual input session-only. Do not add persistent Xochitl/Xovi/input boot
  hooks.
- Before every Mirror-owned Xochitl or Xovi start/restart, reset
  `xochitl.service`'s systemd failure budget and block the action if that reset
  fails.
- Keep Files behind authenticated SSH forwarding. Do not expose its bearer HTTP
  service directly on Wi-Fi.
- Preserve the fixed compact window and accepted reversible Files transition
  unless a change intentionally redesigns them.
- Use `apply_patch` for manual text edits and keep unrelated working-tree changes.
- Never commit or push without explicit owner approval.

## Validation

Run Go tests and vet, a Debug x64 Windows build, and the focused PowerShell checks
for changed policy. Live tablet scripts are opt-in and must be named clearly in
the handoff.

Update user-facing documentation in the same change when behavior changes.
