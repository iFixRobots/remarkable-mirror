# Bundled Microsoft notices

These files are copied from the exact restored packages used by the
current Windows build. The release packager includes this directory under
`ThirdParty/Microsoft` so the distributed MSIX and runtime dependency travel
with their applicable license and notice texts.

| Directory | Package | Version |
|---|---|---:|
| `WebView2` | `Microsoft.Web.WebView2` | `1.0.3179.45` |
| `System.Numerics.Tensors` | `System.Numerics.Tensors` in the installed-package graph | `9.0.0` |
| `WindowsAppSDK` | `Microsoft.WindowsAppSDK` used by the installed package, plus Base, DWrite, Foundation, and Interactive Experiences used by portable | `1.8.260317003` and matching 1.8 components |
| `WindowsAppSDK-WinUI` | `Microsoft.WindowsAppSDK.WinUI` used by portable | `1.8.260224000` |
| `DotNetRuntime` | `Microsoft.NETCore.App.Runtime.win-x64` | `10.0.10` |

The corresponding packages are restored from NuGet according to
`mirror/windows/ReMarkableMirror/packages.lock.json` and
`packages.portable.lock.json`. The license and notice files remain
authoritative for their respective components.
