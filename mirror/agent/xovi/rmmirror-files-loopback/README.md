# rmmirror-files-loopback

This Xovi extension lets stock Xochitl bind its existing Files web interface to
the tablet loopback interface. reMarkable Mirror reaches that listener only
through its authenticated SSH port forward.

The implementation is derived from the two native address-selection hooks in
`asivery/rm-xovi-extensions` `webserver-remote`. It intentionally omits that
extension's QML notification, Qt resource rebuilding, message-broker approval,
LAN-wide proxy, and port remapping.

License: GPL-3.0-only. See `mirror/third-party/xovi/LICENSE-GPL-3.0.txt`.
