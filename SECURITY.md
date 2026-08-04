# Security policy

## Supported versions

There is no public binary release yet. Security fixes currently target the
`main` branch. After binary releases begin, fixes will target the latest
published release and `main`; older development builds may be replaced rather
than patched.

## Report privately

Do not open a public issue for a vulnerability, credential exposure, or a bug
that could damage tablet content.

Use GitHub's
[private vulnerability reporting](https://github.com/iFixRobots/remarkable-mirror/security/advisories/new).
Include the affected version, impact, reproduction steps, and a minimal proof.
Remove passwords, tokens, private keys, document contents, and unnecessary
personal network details.

The maintainer will acknowledge actionable reports, investigate privately, and
coordinate publication after a fix is available.

## Security boundaries

- Mirror assumes Developer Mode is already enabled by the device owner.
- First trust is established over the direct physical USB link.
- Wi-Fi use is intended for a trusted personal LAN.
- Setup enables the tablet's root SSH-over-WLAN feature. Mirror uses a dedicated
  passphrase-free key because its SSH processes run with `BatchMode=yes`. Anyone
  who obtains that private key can authenticate as root to the paired tablet.
- Files travels through authenticated SSH and is not exposed directly on Wi-Fi.
- The wake HTTP endpoint binds only to tablet loopback and the direct USB
  interface. It never listens on the tablet's Wi-Fi address. Before SSH is
  available, Windows sends wake bearer traffic only on a verified direct USB
  route.
- Private signing keys and tablet credentials are never repository assets.

An Authenticode publisher common name such as `CN=iFixRobots` is not sufficient
proof of origin by itself. When public binaries begin, verify the GitHub release
origin and its published hashes and certificate fingerprint before trusting the
included certificate.

Developer Mode and third-party tablet software change the device's supported
security posture. Users are responsible for understanding reMarkable's current
Developer Mode and warranty terms.
