using System.Net;

namespace ReMarkableMirror;

/// <summary>
/// One owner-selected connection target. Creating a request never contacts the tablet.
/// </summary>
internal sealed record ManualConnectionRequest(DeviceRouteKind Kind, SshRoute Route)
{
    public const string FilesLoopbackHost = "127.0.0.1";

    public static ManualConnectionRequest ForUsb(SshRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (!string.Equals(route.Host, SshRoute.TabletHostKeyAlias, StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "The USB-C request must use the direct tablet address.",
                nameof(route));
        }

        return new ManualConnectionRequest(DeviceRouteKind.Usb, route);
    }

    public static bool TryCreateWifi(
        string? addressText,
        int filesTargetPort,
        out ManualConnectionRequest? request,
        out ManualWifiAddressError error)
    {
        request = null;
        var normalized = addressText?.Trim();
        if (string.IsNullOrEmpty(normalized))
        {
            error = ManualWifiAddressError.AddressRequired;
            return false;
        }

        if (!TryParseCanonicalIpv4(normalized, out var address))
        {
            error = ManualWifiAddressError.InvalidAddress;
            return false;
        }

        var bytes = address.GetAddressBytes();
        var isMulticast = bytes[0] is >= 224 and <= 239;
        var isReserved = bytes[0] == 0 || bytes[0] >= 240;
        if (IPAddress.IsLoopback(address) ||
            isMulticast ||
            isReserved ||
            string.Equals(address.ToString(), SshRoute.TabletHostKeyAlias, StringComparison.Ordinal))
        {
            error = ManualWifiAddressError.UnsupportedAddress;
            return false;
        }

        var route = new SshRoute(
            address.ToString(),
            filesTargetHost: FilesLoopbackHost,
            filesTargetPort: filesTargetPort);
        request = new ManualConnectionRequest(DeviceRouteKind.Wifi, route);
        error = ManualWifiAddressError.None;
        return true;
    }

    private static bool TryParseCanonicalIpv4(
        string value,
        out IPAddress address)
    {
        address = IPAddress.None;
        var parts = value.Split('.');
        if (parts.Length != 4)
        {
            return false;
        }

        var bytes = new byte[4];
        for (var index = 0; index < parts.Length; index++)
        {
            var part = parts[index];
            if (part.Length == 0 ||
                (part.Length > 1 && part[0] == '0'))
            {
                return false;
            }
            foreach (var character in part)
            {
                if (character is < '0' or > '9')
                {
                    return false;
                }
            }
            if (!byte.TryParse(part, out bytes[index]))
            {
                return false;
            }
        }

        address = new IPAddress(bytes);
        return true;
    }
}

internal enum ManualWifiAddressError
{
    None,
    AddressRequired,
    InvalidAddress,
    UnsupportedAddress,
}
