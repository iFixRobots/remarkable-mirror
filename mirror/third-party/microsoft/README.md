# Bundled Microsoft notices

These files are copied verbatim from the exact restored packages used by the
current Windows build. The release packager includes this directory under
`ThirdParty/Microsoft` so the distributed MSIX and runtime dependency travel
with their applicable license and notice texts.

| Directory | Package | Version |
|---|---|---:|
| `WebView2` | `Microsoft.Web.WebView2` | `1.0.3179.45` |
| `System.Numerics.Tensors` | `System.Numerics.Tensors` | `9.0.0` |
| `WindowsAppSDK` | `Microsoft.WindowsAppSDK` | `1.8.260317003` |
| `DotNetRuntime` | `Microsoft.NETCore.App.Runtime.win-x64` | `10.0.10` |
| `WindowsDesktopRuntime` | `Microsoft.WindowsDesktop.App.Runtime.win-x64` | `10.0.10` |

The corresponding packages are restored from NuGet according to
`mirror/windows/ReMarkableMirror/packages.lock.json`. The license and notice
files remain authoritative for their respective components.
