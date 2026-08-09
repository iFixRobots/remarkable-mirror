# Wake-recovery correction — 2026-08-07

This checkpoint corrects the live sleep diagnosis, records the two source
repairs that followed it, and preserves the remaining device boundary. It is
not physical unlock, Live mirroring, signing, notarization or release proof.
The appended current record at the end supersedes this checkpoint's initial
interpretation of the normal Windows continuity contract and records the later
package validation.

> [!NOTE]
> The Mac recovery behavior originally recorded at this checkpoint is historical
> evidence from an earlier build and is superseded by the current owner-started
> connection contract. Launch, USB appearance, and network changes do not start tablet
> communication. Setup, authorization, authorization checking, and Wi-Fi setup
> are explicit bounded operations. One **Connect USB-C** click owns a bounded
> same-cable wake, recovery, authentication, and connection session. It never
> selects or falls back to Wi-Fi. The owner intervenes only if the tablet asks
> for its passcode. **Connect Wi-Fi** is a separate action. This note does not
> alter the Windows behavior recorded in this journal.

## Correction and live evidence

- The diagnostic mistake was treating a sleeping tablet that did not answer as
  cable absence and a terminal stop. The current USB-C action instead owns a
  bounded wake-through-connect recovery session on the same cable.
- macOS confirmed the Paper Pro Move through the direct USB-C cable. At this
  checkpoint, neither the secure shell service nor the wake service answered.
- The earlier conclusion that authorized USB recovery required a physical
  power-button press is superseded. The current Mac action asks the direct-cable
  wake service to recover the tablet and waits for its services. Only passcode
  entry may require the owner.
- The initially installed app was stale relative to Milestone 6 wake handling,
  and no local device profile existed, so it could not exercise the paired wake
  client. The current app was installed and launched afterward.
- The app installed at that checkpoint displayed an earlier recovery state.
  That observation is preserved only as historical evidence; it is not the
  current product contract.

## Source repairs

- After the direct cable is verified, the current **Connect USB-C** session asks
  the wake service to recover the same tablet and waits for its services before
  deciding that the connection cannot finish. A missing SSH endpoint is not
  mislabeled as cable absence.
- When the wake endpoint reports `starting`, an already authenticated ready
  result for that exact USB candidate remains eligible for activation. A
  transitional endpoint observation no longer suppresses known-ready SSH
  evidence.

## Refreshed package and remaining boundary

The refreshed unsigned arm64 `0.2.0 (2)` package is:

```text
artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip
```

Its SHA-256 is
`25a1c9fc93a0782dd360b2210f3b735562f3e5977ae1378dfcbf502c84febbca`.
The package remains unsigned and is only a local review artifact.

Physical passcode unlock and the resulting endpoint return, authentication,
frame, input, Files and **Live** publication remain unexercised because ports 22
and 51337 were still unavailable at the end of this checkpoint. No persistent
tablet change, signing, notarization, hosted publication, commit or push was
performed here.

## Current record: Windows-parity continuity and refreshed package

The initial checkpoint above described the terminal case after Linux has
already completed suspend. It did not capture the normal Windows behavior that
prevents an active session from reaching that state:

- while USB carrier is present, the tablet transport service renews a kernel
  wake lock and prevents the suspend executor from completing;
- the session-only input helper holds its own wake lock for an active USB or
  Wi-Fi session;
- an exact `deep_sleep` input handshake triggers one atomic `KEY_POWER` attempt
  before publication, with no retry in that session after failed or partial
  acknowledgement;
- Wi-Fi sends an immediate `KEY_F12` before controls publish, then sends
  `KEY_F12` every 10 seconds; USB sends it every 45 seconds;
- acknowledged user input resets the activity deadline; and
- three-second protocol `ping` messages continue between activity events.

The Mac input session implements the same active-session continuity in source.
In addition, one owner-started **Connect USB-C** session owns direct-cable wake,
service recovery, authentication, and connection without selecting Wi-Fi. The
tablet passcode is the only owner intervention that authorized USB session may
require.

The refreshed unsigned arm64 `0.2.0 (2)` package remains:

```text
artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip
```

Its SHA-256 is
`0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf`.
The archive audit recorded a clean extraction, and the packaged binary matches
the installed unsigned app.

Live setup is still incomplete. The Mac saw the tablet through the direct USB-C
cable, but the tablet services did not answer even after unlock. No persistent
Mac key authorization, physical Live mirroring, or owner-started USB-C and
Wi-Fi connection validation completed. No tablet change, signing, notarization,
hosted publication, commit, or push was performed in this follow-up.
