# macOS Packaging

The last audited Milestone 6 package is a private, unsigned arm64 `0.2.0 (2)`
ZIP for local review. Current source builds as a single production target under
stable Xcode 26.6.
The Release app was packaged, rehashed, freshly extracted and compared
recursively with an exact match, and its packaged binary matches the installed
app. Its executable retains a linker-generated ad-hoc signature, while the
app bundle does not pass strict code-signature verification. It has not been
Developer ID signed, notarized, hosted, released, promoted to Gold or
owner-accepted. A current product-only Debug build has completed an owner-started
USB-C connection to Live on the physical tablet, recovered an already-open
Files pane after an owner-authorized unlock in the same generation, loaded a
7-item root listing, and quit cleanly with its active owned children
retired. That proof does not transfer to this older Release archive, Wi-Fi,
signing, notarization or release.

## Local candidate

```zsh
scripts/Build-RemarkableMirrorMac.sh
scripts/Package-RemarkableMirrorMac.sh
```

The package script derives `CFBundleShortVersionString`, `CFBundleExecutable`,
and the executable architectures from the built bundle. It verifies the
archive and distinguishes a valid bundle signature from the executable's
linker-generated signature. Candidate `0.2.0 (2)` is:

```text
artifacts/macos/package/reMarkable-Mirror-0.2.0-macOS-arm64-unsigned.zip
```

SHA-256:

```text
0bb79a5331142d42a4f5d74cdf31802a660f6d8ebb1d0adb4a93a99f6fcc38cf
```

The source and the older archive have proved these states separately:

- the source builds as a single production target under stable Xcode 26.6;
- `go test ./...`, `go vet ./...` and host-policy checks pass; and
- the last audited ZIP has a recorded clean extraction and recursive Release-product
  comparison.

The last audited ZIP proves only that local Release product and archive comparison.
The packaged app was installed and its binary matched that older archive. A
newer product-only Debug build completed one owner-started USB-C session to Live
with a real tablet frame and authenticated frame, input and Files processes.
In that current-source run, an already-open Files pane recovered after an
owner-authorized unlock in the same USB generation and loaded a 7-item root
listing without reconnecting or reopening; a later Command-Q retired all active
owned children without an orphan or AppKit exception. Other current-worktree
runs physically exercised screenshot copy/save, touch and Pen taps, committed
keyboard text, a continuous swipe, folder navigation, PDF export and native
RMDOC export. That newer proof does not prove this archive, import or upload,
delete, Finder drag-out, pen stroke, eraser/right-click, Wi-Fi, the exact
fully-deep-sleep power event, Keychain behavior in an authorized signed app,
hosted artifacts, Developer ID signing, notarization, release or owner
acceptance.

A separate macOS packaging workflow file exists in the repository, but it has
not run on a hosted runner and has produced no hosted artifact.

## Signing boundary

The latest product-only Debug app is locally ad-hoc signed, with no Team
Identifier; the last audited Release archive remains unsigned. Neither is
Developer ID or notarization proof. No signing or notarization credential is
read, fabricated, or stored by the scripts.
Only explicit Wi-Fi setup calls the Data Protection Keychain adapter for the
paired Wi-Fi context secret and wake token. Direct USB-C does not use them.
Persistence and access-group behavior still require an authorized signed build.

Before a private downloadable Mac artifact can be treated as distributable:

- exercise the complete tablet-backed product path;
- run and verify the separate macOS GitHub Actions workflow without changing
  Windows jobs;
- compile each claimed architecture before calling the package universal;
- add explicit Developer ID and notarization hooks without embedding secrets;
- verify Local Network privacy and system OpenSSH in the packaged signed app;
- exercise the real Keychain access group and persistence across replacement;
  and
- record signing, notarization, hosted-artifact, owner-acceptance, and release
  status independently.

Signing, notarization, publishing, and release require explicit owner
authorization and are not part of the current Milestone 6 proof.
