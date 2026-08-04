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
Include the affected version, impact, reproduction steps, and the smallest
example needed to show the problem.
Remove passwords, tokens, private keys, document contents, and unnecessary
personal network details.

The maintainer will acknowledge actionable reports, investigate privately, and
coordinate publication after a fix is available.

## Security boundaries

- Mirror assumes Developer Mode is already enabled by the device owner.
- First trust is established over the direct physical USB link.
- Use Wi-Fi control only on a private network you control, not public or guest
  Wi-Fi.
- Setup enables the tablet's root SSH-over-WLAN feature. Mirror uses a dedicated
  passphrase-free key because its SSH processes run with `BatchMode=yes`. Anyone
  who obtains that private key can authenticate as root to the paired tablet.
- Files travels through authenticated SSH and is not exposed directly on Wi-Fi.
- The wake HTTP endpoint binds only to tablet loopback and the direct USB
  interface. It never listens on the tablet's Wi-Fi address. Before SSH is
  available, Windows sends wake bearer traffic only on a verified direct USB
  route.
- Private signing keys and tablet credentials are never repository assets.

A publisher name such as `CN=iFixRobots` does not show where a file came from.
When public binaries begin, download them from this repository's GitHub Releases
page and compare the published hashes and certificate fingerprint before
trusting the included certificate.

Developer Mode and third-party tablet software reduce some of the tablet's
built-in protections. Read reMarkable's current Developer Mode and warranty
terms before installing.
