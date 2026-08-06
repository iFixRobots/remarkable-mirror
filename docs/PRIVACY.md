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

Application logs are designed to omit document contents, document filenames,
tokens, private keys, and Wi-Fi passwords. Upload failures record a result
category and numeric HTTP status instead of the local filename. A diagnostic
report can still reveal software versions, route state, timestamps, and local
network characteristics. Review diagnostics before posting them publicly.

## Release artifacts

Release builds disable Mirror-owned PDB/CodeView output. Before signing, the
package builder inspects the app DLL and EXE and stops if either embeds a rooted
application CodeView path or the current repository or Windows user-profile
root. The SDK-provided native apphost may retain its own framework build
provenance; it is not a path produced from this checkout. Debug builds keep
their symbols and should not be distributed as release packages.

## Network boundary

Setup enables Developer Mode root SSH over WLAN and creates a dedicated SSH key
so Mirror can reconnect without prompting. The key lives under the current
Windows user's `.ssh` directory. Windows limits the device profile and wake token
to that user. Anyone who obtains the SSH key can access the paired tablet as
root, so keep it private.

Files and wake services use bearer credentials on the tablet. Mirror does not
expose them directly to the LAN. Files travels through authenticated SSH. The
wake HTTP endpoint binds only to tablet loopback and the direct USB interface;
the pre-SSH Windows request uses only a verified USB route. Use Wi-Fi Mirror on
your home Wi-Fi, not on public or guest Wi-Fi. If you do not control who can
join the network, use USB-C instead.
