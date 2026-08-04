# Privacy

reMarkable Mirror talks directly to your tablet.

## Data flow

The app connects to the tablet over USB or Wi-Fi. There is no iFixRobots account,
relay, analytics service, document index, or screenshot upload service.

Mirror handles these categories locally:

- live framebuffer pixels;
- pointer and keyboard input;
- document metadata needed to render the Files drawer;
- files explicitly imported or exported by the user;
- screenshots explicitly copied or saved;
- a protected device profile; and
- SSH and wake credentials stored outside the repository.

## Local storage

The device profile is stored for the current Windows user. It contains connection
settings and paths to Mirror's credential files. It never stores the Wi-Fi
password. The tablet and Windows manage that password themselves.

Clipboard screenshots use a temporary PNG file so they remain valid after the
app closes. Mirror does not automatically remove those files yet. You can delete
old Mirror PNGs from the Windows temporary directory.

## Logs

Application logs are designed to omit document contents, tokens, private keys,
and Wi-Fi passwords. A diagnostic report can still reveal software versions,
route state, timestamps, and local network characteristics. Review diagnostics
before posting them publicly.

## Network boundary

Setup enables Developer Mode root SSH over WLAN and creates a dedicated SSH key
so Mirror can reconnect without prompting. The key lives under the current
Windows user's `.ssh` directory. Windows limits the device profile and wake token
to that user. Anyone who obtains the SSH key can access the paired tablet as
root, so keep it private.

Files and wake services use bearer credentials on the tablet. Mirror does not
expose them directly to the LAN. Files travels through authenticated SSH. The
wake HTTP endpoint binds only to tablet loopback and the direct USB interface;
the pre-SSH Windows request uses only a verified USB route. Use Wi-Fi Mirror
only on a private network you control. Avoid public and guest Wi-Fi.
