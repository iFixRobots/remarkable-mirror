# Privacy

reMarkable Mirror is local-first software.

## Data flow

The app connects directly to the tablet over its USB network or a trusted local
Wi-Fi network. There is no iFixRobots account, relay, analytics service, document
index, or screenshot upload service.

Mirror handles these categories locally:

- live framebuffer pixels;
- pointer and keyboard input;
- document metadata needed to render the Files drawer;
- files explicitly imported or exported by the user;
- screenshots explicitly copied or saved;
- a protected device profile; and
- SSH and wake credentials stored outside the repository.

## Local storage

The device profile is stored for the current Windows user. It contains route and
capability metadata plus references to credential files, not the Wi-Fi password.
The Wi-Fi password remains managed by the tablet and Windows.

Clipboard screenshots use a temporary PNG backing file so they remain valid
after the app closes. Bounded automatic cleanup of those files is still open;
users can remove old Mirror PNGs from their Windows temporary directory.

## Logs

Application logs are designed to omit document contents, tokens, private keys,
and Wi-Fi passwords. A diagnostic report can still reveal software versions,
route state, timestamps, and local network characteristics. Review diagnostics
before posting them publicly.

## Network boundary

Setup enables Developer Mode root SSH over WLAN and stores a dedicated
passphrase-free SSH key for non-interactive `BatchMode` connections. The key
lives under the current Windows user's `.ssh` directory. The device profile and
wake token are ACL-restricted to that user. All three remain outside the
repository. Review and protect the key's Windows ACL because anyone who obtains
it can authenticate as root to the paired tablet.

Files and wake services use bearer credentials on the tablet. Mirror does not
expose them directly to the LAN. Files travels through authenticated SSH. The
wake HTTP endpoint binds only to tablet loopback and the direct USB interface;
the pre-SSH Windows request uses only a verified USB route. Use Wi-Fi Mirror
only on a network you trust.
