# Third-party notices

reMarkable Mirror depends on and redistributes third-party software. Their names
do not imply endorsement of this project.

## Xovi and rm-xovi-extensions

Planned binary release packages redistribute the pinned `rm-xovi-extensions`
`v19-23052026` ARM64 archive and its unmodified Xovi `v0.3.3` runtime.

- rm-xovi-extensions source:
  <https://github.com/asivery/rm-xovi-extensions/tree/7874154dba6793cc68a15fae0fb9dd272c4ed20a>
- Xovi source:
  <https://github.com/asivery/xovi/tree/0c8d5269b55c851901d4e4a754dc2d7deab40b17>
- License: GNU General Public License version 3
- Packaged notice and license:
  `mirror/third-party/xovi/NOTICE.txt` and
  `mirror/third-party/xovi/LICENSE-GPL-3.0.txt`

Mirror selects upstream `framebuffer-spy` and `xovi-message-broker`. The separate
`rmmirror-files-loopback` extension is built from source in this repository. It
is derived from the native interface-selection hooks in upstream
`webserver-remote` and is licensed `GPL-3.0-only`.

## Microsoft Windows components

The installed package restores these pinned NuGet packages:

- `Microsoft.Windows.SDK.BuildTools` `10.0.26100.7705`, under the Microsoft
  Windows SDK license terms;
- `Microsoft.WindowsAppSDK` `1.8.260317003`, under the Microsoft Windows App SDK
  license terms included in that package; and
- `Microsoft.Windows.SDK.BuildTools.WinApp` `0.3.1`, MIT.

The portable build stays on the same Windows App SDK 1.8 line but references
only these runtime components directly: Base `1.8.251216001`, DWrite
`1.8.25122902`, Foundation `1.8.260222000`, Interactive Experiences
`1.8.260125001`, and WinUI `1.8.260224000`.

The installed package's full dependency graph also includes Microsoft WebView2
and `System.Numerics.Tensors`. The smaller portable graph still includes
WebView2 through WinUI, but it does not include Tensors, AI, machine learning,
or Widgets. Their package license files remain authoritative.
An official release ZIP will carry the matching Microsoft Windows App Runtime x64
dependency beside the application. Microsoft license files supplied with those
packages and runtimes remain authoritative.

The packaging workflow includes the exact restored license and notice texts under
`ThirdParty/Microsoft` for Windows App SDK, WebView2,
`System.Numerics.Tensors`, the WinUI component package, and the .NET runtime.

## Corresponding source for binary releases

There is no public binary release yet. Every future binary release must attach a
versioned corresponding-source archive beside the binaries. That archive must
contain:

- the exact tagged reMarkable Mirror source, including build and installation
  scripts and the `rmmirror-files-loopback` extension source;
- source snapshots at the exact pinned commits for every redistributed Xovi and
  `rm-xovi-extensions` binary;
- the notices and GPL license texts; and
- the build instructions and exact toolchain references needed to reproduce the
  GPL-covered components.

The repository tag and upstream links remain useful for review, but links alone
are not the binary-release corresponding-source plan. A binary release is not
ready to publish until its source archive has been assembled and inspected.

## Build-only tools

The Files extension build uses the pinned
`eeems/remarkable-toolchain` container and Xovi extension generator. These tools
are not redistributed as part of the Mirror application package. Their source
and license information remain at their respective upstream repositories.
