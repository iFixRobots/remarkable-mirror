using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReMarkableMirror;

internal sealed class TabletWakeClient : IDisposable
{
    private const string DefaultTokenFileName = "remarkable_chiappa_wake_token";
    private const string ExpectedSchema = "rmmirror.wake/v1";
    private const int TokenLength = 64;
    private const int MaximumResponseBytes = 4096;
    private const int UsbPrefixLength = 27;
    // Winsock IP_UNICAST_IF. The net10 SocketOptionName enum does not expose
    // the Windows constant, but SetSocketOption accepts its native value.
    private const SocketOptionName IpUnicastInterface = (SocketOptionName)31;
    private static readonly IPAddress UsbTabletAddress = IPAddress.Parse("10.11.99.1");
    private static readonly IPAddress UsbWindowsAddress = IPAddress.Parse("10.11.99.11");
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromMilliseconds(750);
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(2);

    private readonly HttpClient _httpClient;
    private readonly Uri _statusUri;
    private readonly Uri _wakeUri;
    private readonly AuthenticationHeaderValue _authorization;
    private readonly SemaphoreSlim _requestGate = new(1, 1);

    private TabletWakeClient(int port, string token)
    {
        var endpoint = new UriBuilder(Uri.UriSchemeHttp, UsbTabletAddress.ToString(), port).Uri;
        _statusUri = new Uri(endpoint, "/v1/status");
        _wakeUri = new Uri(endpoint, "/v1/wake");
        _authorization = new AuthenticationHeaderValue("Bearer", token);

        _httpClient = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = ConnectTimeout,
            MaxConnectionsPerServer = 1,
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(15),
            UseCookies = false,
            UseProxy = false,
            ConnectCallback = ConnectUsbAsync,
        })
        {
            Timeout = RequestTimeout,
        };
    }

    public static TabletWakeClientCreationResult TryCreateUsb(
        string? tokenFileReference = null,
        int port = 51337)
    {
        if (!HasDirectUsbInterface())
        {
            return new TabletWakeClientCreationResult(
                null,
                TabletWakeClientCreationStatus.UsbUnavailable);
        }

        var token = ReadToken(tokenFileReference);
        if (token.Status is not TabletWakeClientCreationStatus.Ready)
        {
            return new TabletWakeClientCreationResult(null, token.Status);
        }

        try
        {
            return new TabletWakeClientCreationResult(
                new TabletWakeClient(port, token.Value!),
                TabletWakeClientCreationStatus.Ready);
        }
        catch (UriFormatException)
        {
            return new TabletWakeClientCreationResult(
                null,
                TabletWakeClientCreationStatus.InvalidConfiguration);
        }
    }

    public Task<TabletWakeResponse?> GetStatusAsync(CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Get, _statusUri, cancellationToken);

    public Task<TabletWakeResponse?> WakeAsync(CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Post, _wakeUri, cancellationToken);

    internal static bool HasDirectUsbInterface() => TryGetDirectUsbInterfaceIndex(out _);

    private static async ValueTask<Stream> ConnectUsbAsync(
        SocketsHttpConnectionContext context,
        CancellationToken cancellationToken)
    {
        if (!IPAddress.TryParse(context.DnsEndPoint.Host, out var destination) ||
            !destination.Equals(UsbTabletAddress) ||
            !TryGetDirectUsbInterfaceIndex(out var interfaceIndex))
        {
            throw new HttpRequestException("The direct USB route is unavailable.");
        }

        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            // IP_UNICAST_IF prevents a more-specific VPN route from receiving
            // the bearer even if Windows still owns 10.11.99.11 locally.
            socket.SetSocketOption(
                SocketOptionLevel.IP,
                IpUnicastInterface,
                IPAddress.HostToNetworkOrder(interfaceIndex));
            socket.Bind(new IPEndPoint(UsbWindowsAddress, 0));
            await socket.ConnectAsync(
                    new IPEndPoint(UsbTabletAddress, context.DnsEndPoint.Port),
                    cancellationToken)
                .ConfigureAwait(false);
            if (socket.LocalEndPoint is not IPEndPoint localEndpoint ||
                !localEndpoint.Address.Equals(UsbWindowsAddress) ||
                socket.RemoteEndPoint is not IPEndPoint remoteEndpoint ||
                !remoteEndpoint.Address.Equals(UsbTabletAddress))
            {
                throw new HttpRequestException("The direct USB route could not be verified.");
            }

            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    private static bool TryGetDirectUsbInterfaceIndex(out int interfaceIndex)
    {
        interfaceIndex = 0;
        try
        {
            var matches = NetworkInterface.GetAllNetworkInterfaces()
                .Where(networkInterface =>
                    networkInterface.OperationalStatus is OperationalStatus.Up &&
                    networkInterface.GetIPProperties().UnicastAddresses.Any(address =>
                        address.Address.Equals(UsbWindowsAddress) &&
                        address.PrefixLength == UsbPrefixLength))
                .Select(networkInterface =>
                    networkInterface.GetIPProperties().GetIPv4Properties()?.Index ?? 0)
                .Where(index => index > 0)
                .Distinct()
                .Take(2)
                .ToArray();
            if (matches.Length != 1)
            {
                return false;
            }

            interfaceIndex = matches[0];
            return true;
        }
        catch (NetworkInformationException)
        {
            return false;
        }
    }

    private async Task<TabletWakeResponse?> SendAsync(
        HttpMethod method,
        Uri uri,
        CancellationToken cancellationToken)
    {
        await _requestGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            using var request = new HttpRequestMessage(method, uri);
            request.Headers.Authorization = _authorization;
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            using var response = await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                cancellationToken)
                .ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw new TabletWakeAuthenticationException();
            }
            if (response.StatusCode is not HttpStatusCode.OK ||
                response.Content.Headers.ContentLength is > MaximumResponseBytes)
            {
                return null;
            }

            var payload = await ReadBoundedResponseAsync(response.Content, cancellationToken)
                .ConfigureAwait(false);
            if (payload is null)
            {
                return null;
            }

            var wireResponse = JsonSerializer.Deserialize<WakeWireResponse>(payload);
            if (wireResponse is null ||
                !string.Equals(wireResponse.Schema, ExpectedSchema, StringComparison.Ordinal) ||
                !TryParseState(wireResponse.State, out var state))
            {
                return null;
            }

            return new TabletWakeResponse(state, wireResponse.WakeSent);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or JsonException)
        {
            return null;
        }
        finally
        {
            _requestGate.Release();
        }
    }

    private static async Task<byte[]?> ReadBoundedResponseAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var payload = new byte[MaximumResponseBytes + 1];
        var total = 0;
        while (total < payload.Length)
        {
            var read = await stream.ReadAsync(payload.AsMemory(total), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                return payload[..total];
            }
            total += read;
        }
        return null;
    }

    private static bool TryParseState(string? value, out TabletWakeState state)
    {
        state = value switch
        {
            "unlock_required" => TabletWakeState.UnlockRequired,
            "sleeping" => TabletWakeState.Sleeping,
            "ready" => TabletWakeState.Ready,
            "starting" => TabletWakeState.Starting,
            _ => TabletWakeState.Unknown,
        };
        return state is not TabletWakeState.Unknown;
    }

    private static WakeTokenReadResult ReadToken(string? tokenFileReference)
    {
        string tokenPath;
        if (string.IsNullOrWhiteSpace(tokenFileReference))
        {
            var userProfile = Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile,
                Environment.SpecialFolderOption.DoNotVerify);
            if (string.IsNullOrWhiteSpace(userProfile))
            {
                return new WakeTokenReadResult(
                    null,
                    TabletWakeClientCreationStatus.InvalidConfiguration);
            }
            tokenPath = Path.Combine(userProfile, ".ssh", DefaultTokenFileName);
        }
        else
        {
            if (!Path.IsPathFullyQualified(tokenFileReference))
            {
                return new WakeTokenReadResult(
                    null,
                    TabletWakeClientCreationStatus.InvalidConfiguration);
            }
            try
            {
                tokenPath = Path.GetFullPath(tokenFileReference);
            }
            catch (Exception exception) when (exception is
                ArgumentException or NotSupportedException or PathTooLongException)
            {
                return new WakeTokenReadResult(
                    null,
                    TabletWakeClientCreationStatus.InvalidConfiguration);
            }
        }

        try
        {
            using var stream = new FileStream(
                tokenPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                TokenLength,
                FileOptions.SequentialScan);
            var tokenFile = new FileInfo(tokenPath);
            if ((tokenFile.Attributes & FileAttributes.ReparsePoint) != 0 ||
                !HasCurrentUserOnlyAcl(tokenFile))
            {
                return new WakeTokenReadResult(
                    null,
                    TabletWakeClientCreationStatus.AccessDenied);
            }
            if (stream.Length != TokenLength)
            {
                return new WakeTokenReadResult(
                    null,
                    TabletWakeClientCreationStatus.InvalidToken);
            }

            Span<byte> payload = stackalloc byte[TokenLength];
            stream.ReadExactly(payload);
            foreach (var value in payload)
            {
                if (value is not (>= (byte)'0' and <= (byte)'9') and
                    not (>= (byte)'a' and <= (byte)'f') and
                    not (>= (byte)'A' and <= (byte)'F'))
                {
                    return new WakeTokenReadResult(
                        null,
                        TabletWakeClientCreationStatus.InvalidToken);
                }
            }
            return new WakeTokenReadResult(
                Encoding.ASCII.GetString(payload),
                TabletWakeClientCreationStatus.Ready);
        }
        catch (FileNotFoundException)
        {
            return new WakeTokenReadResult(null, TabletWakeClientCreationStatus.MissingToken);
        }
        catch (DirectoryNotFoundException)
        {
            return new WakeTokenReadResult(null, TabletWakeClientCreationStatus.MissingToken);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or SecurityException)
        {
            return new WakeTokenReadResult(null, TabletWakeClientCreationStatus.AccessDenied);
        }
        catch (Exception exception) when (exception is
            IOException or
            ArgumentException or
            NotSupportedException)
        {
            return new WakeTokenReadResult(null, TabletWakeClientCreationStatus.InvalidToken);
        }
    }

    private static bool HasCurrentUserOnlyAcl(FileInfo file)
    {
        var sid = WindowsIdentity.GetCurrent().User;
        if (sid is null)
        {
            return false;
        }

        var security = FileSystemAclExtensions.GetAccessControl(file);
        if (!security.AreAccessRulesProtected ||
            !sid.Equals(security.GetOwner(typeof(SecurityIdentifier))))
        {
            return false;
        }

        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            targetType: typeof(SecurityIdentifier));
        var matchingRules = 0;
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                !sid.Equals(rule.IdentityReference) ||
                (rule.FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl)
            {
                return false;
            }
            matchingRules++;
        }

        return matchingRules == 1;
    }

    public void Dispose()
    {
        _httpClient.Dispose();
        _requestGate.Dispose();
    }

    private sealed class WakeWireResponse
    {
        [JsonPropertyName("schema")]
        public string? Schema { get; init; }

        [JsonPropertyName("state")]
        public string? State { get; init; }

        [JsonPropertyName("wake_sent")]
        public bool WakeSent { get; init; }
    }

    private sealed record WakeTokenReadResult(
        string? Value,
        TabletWakeClientCreationStatus Status);
}

internal enum TabletWakeClientCreationStatus
{
    Ready,
    UsbUnavailable,
    MissingToken,
    InvalidToken,
    AccessDenied,
    InvalidConfiguration,
}

internal sealed record TabletWakeClientCreationResult(
    TabletWakeClient? Client,
    TabletWakeClientCreationStatus Status);

internal sealed class TabletWakeAuthenticationException : Exception
{
}

internal enum TabletWakeState
{
    Unknown,
    UnlockRequired,
    Sleeping,
    Ready,
    Starting,
}

internal sealed record TabletWakeResponse(TabletWakeState State, bool WakeSent);
