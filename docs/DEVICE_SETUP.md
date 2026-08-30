# Tablet setup internals

This is the technical reference for contributors and operators. New users
should follow [Windows setup](GETTING_STARTED.md) or
[macOS setup](macos/GETTING_STARTED.md); the apps perform these steps.

## User-visible contract

Both native apps present the same setup stages in their own platform-native UI:

1. show the Developer Mode/reset disclosure and preparation checklist;
2. verify one direct USB-C connection;
3. prove an existing dedicated key and inspect the installed tablet payload;
4. return to the chooser immediately when that setup is already complete;
5. otherwise ask for the one-time Developer Mode root password in a secure
   field, authorize the host, and install the shared tablet payload;
6. enable the tablet's Wi-Fi SSH listener over the cable, without
   needing any Wi-Fi network; and
7. return to the manual USB-C/Wi-Fi chooser without connecting.

The first attempt is **Start Setup**. An interrupted attempt becomes one
explicit resume or repair action. Nothing starts because the app launched, a
cable appeared, or the network changed.

The app cannot automate Developer Mode, its factory reset, account sign-in,
Wi-Fi password entry, the first physical unlock, USB accessory approval, or
finding and entering the generated root password.

## Admission checks

Pairing and inspection admit only:

- a Paper Pro Move (`chiappa`);
- reMarkable Developer Mode;
- an awake tablet past its first post-boot unlock;
- one direct data-capable USB-C connection;
- direct tablet address `10.11.99.1`;
- the stock **USB web interface** enabled; and
- no tablet Wi-Fi network at all; setup is cable-only.

Firmware and build are recorded as tablet identity and profile state, not as
a pairing or passive-runtime gate. Installation compares the observed
`IMG_VERSION` + `VERSION_ID` pair with the package's tested list and logs an
untested pair instead of blocking on it.

Windows also verifies the expected `10.11.99.11/27` address and
`10.11.99.0/27` route on a physical USB adapter. macOS verifies its direct
cable context and any required accessory approval.

## SSH authorization

First trust is established only over the verified cable network.

- The host creates or reuses one dedicated passphrase-free Ed25519 key.
- It scans and pins exactly one Ed25519 tablet host key.
- The owner enters the generated Developer Mode root password once.
- The host appends only its public key to
  `/home/root/.ssh/authorized_keys` and proves key-only access.
- Later USB-C and Wi-Fi sessions require that pinned tablet identity.

Windows stores the dedicated identity at:

```text
%USERPROFILE%\.ssh\remarkable_chiappa_ed25519
%USERPROFILE%\.ssh\remarkable_known_hosts
```

The private-key ACL is restricted to the current Windows account. The Windows
password bridge carries the password in memory to system OpenSSH; it is not put
in a command line, environment variable, file, or log.

macOS keeps its app-owned OpenSSH material and profile under:

```text
~/Library/Application Support/com.ifixrobots.ReMarkableMirror/
```

The root password is never saved. The dedicated private key authenticates as
tablet root and must be protected as a root credential.

## One shared tablet transaction

Windows and macOS use different host adapters but one tablet mutation body:

- Windows: `TabletSetupCoordinator` and `OpenSshSetupClient`, then
  `scripts/Install-RemarkableMirrorPrerequisites.ps1`;
- macOS: `TabletPairingFinalizer` and `TabletPrerequisiteInstaller.swift`; and
- tablet: `mirror/agent/deploy/install-mirror-prerequisites.sh`.

Each adapter uploads the exact nine-asset payload to a private, leased USB-only
SSH stage:

```text
install-mirror-prerequisites.sh
install-transport-wake.sh
rmmirror-files-loopback.so
rmmirror-prerequisites.env
rmmirror-probe
rmmirror-transport-wake
rmmirror-transport-wake.service
rmmirror-usb-sleep-guard.conf
xovi-aarch64.tar.gz
```

`rmmirror-prerequisites.env` is the canonical schema, paired install-target
allowlist, component versions, Xovi hash, transport policy, and extension-set
contract. The host supplies verified SHA-256 values for every asset. The tablet
script rechecks them before its first installation mutation.

The transaction:

1. validates the target model, paired software install target, input devices,
   asset contract, and existing Xovi state;
2. installs or repairs the pinned Xovi runtime;
3. activates `framebuffer-spy.so`, `xovi-message-broker.so`, and
   `rmmirror-files-loopback.so`;
4. installs `rmmirror-probe`;
5. installs and verifies transport-wake and the USB suspend guard;
6. proves the completed capability state;
7. writes an exact completion marker; and
8. removes its private remote stage.

Unknown, unmarked, or incompatible Xovi state fails closed. The transaction
does not start Xovi or Xochitl and does not install persistent virtual input.
Rollback restores the previous package-owned files and service state when an
installation step fails.

After the shared transaction, the native coordinator enables the tablet's
Wi-Fi SSH listener (`rm-ssh-over-wlan`, explicitly starting its
socket-activated service on tablet software that only enables it), verifies
the listener, and proves that the
Wi-Fi route presents the same pinned SSH identity. This is setup preparation,
not a connection attempt. The app still returns to the manual chooser.

## Persistent result

Completed app-led setup leaves:

- the dedicated host public key;
- `rmmirror-probe`;
- pinned Xovi and the three active Mirror extensions;
- transport-wake, its systemd service, and the USB suspend guard;
- the root-owned wake token; and
- Developer Mode SSH over Wi-Fi.

Each host keeps its own private key, pinned host identity, local readiness
profile, and protected wake/network state. Hosts do not copy those secrets or
profiles to one another. See [What Mirror changes](TABLET_CHANGES.md) for exact
paths and side effects.

## Runtime boundary

Setup completion never starts a mirror session.

Passive recognition preserves the observed firmware and root slot but admits
runtime use from the verified Mirror component contract. A firmware change by
itself does not require repair.

- **Connect USB-C** owns one bounded direct-cable attempt.
- The Wi-Fi action opens an IPv4 field, then owns one bounded attempt against
  that address.
- Clicking a Live status delegates to the opposite existing manual action.
- A retired generation does not fall back, switch, or reconnect.
- Files starts only when the owner opens Files.

Virtual input is session-only. No input service, Xochitl boot dependency, udev
rule, or persistent input hook is installed.

## Repair and recovery

Setup and repair are safe to retry only through the app's explicit action.

- A missing key or identity mismatch stops before tablet installation. On
  Windows, the identity-mismatch card offers **Set Up as New Tablet…**, which
  archives the previous pairing files and restarts first-time setup for the
  connected tablet.
- An interrupted upload leaves no successful completion marker; a later
  explicit attempt uses a new leased stage.
- A valid existing key lets the app resume without asking for the password
  again.
- A component mismatch runs the same transaction in repair mode only when the
  active software/build pair is an install target.
- A firmware/root-slot switch requires explicit USB-C repair when the newly
  active root lacks Mirror components.
- Automatic root-slot repair and complete stock restoration are not
  implemented.

Do not disable strict host-key checking, replace an existing key casually, or
run the tablet script outside its native adapter. See
[Troubleshooting](TROUBLESHOOTING.md) and
[Uninstall status](UNINSTALL.md).

## Evidence boundary

Source review, policy checks, compilation, package inspection, installation,
authentication, and physical-device acceptance are different evidence levels.
Do not describe the complete first-run path as physically accepted until that
exact host, package, and freshly reset tablet path has been exercised.
