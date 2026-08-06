using System.ComponentModel;
using System.Diagnostics;
using System.Net.Sockets;

namespace ReMarkableMirror;

/// <summary>
/// Proves that a route speaks SSH and authenticates as the already-pinned tablet.
/// The remote command is read-only and never starts Xovi, input, Files, or wake work.
/// </summary>
internal sealed class PassiveRouteProbe
{
    private const int SshPort = 22;
    private const int MaximumBannerBytes = 4096;
    private const int MaximumBannerLineBytes = 1024;
    private const int MaximumBannerLines = 16;
    private const int PrerequisiteMismatchExitCode = 42;

    private const string ExpectedProbeVersion = "0.4.9";
    private const string ExpectedTransportVersion = "0.6.0";
    private const string ExpectedTransportSchema = "rmmirror.transport-wake/v1";
    private const string ExpectedXoviVersion = "v19-23052026";

    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan BannerTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan AuthenticationTimeout = TimeSpan.FromSeconds(7);

    private const string CapabilityCommand = """
        printf '%s\n' 'RMMIRROR_ROUTE_AUTHENTICATED=1'

        probe=/home/root/.local/bin/rmmirror-probe
        transport=/usr/libexec/rmmirror-transport-wake
        transport_status=/run/rmmirror-transport-wake.json
        xovi_version_file=/home/root/xovi/.rmmirror-version

        boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        active_root="$(findmnt -n -o SOURCE / 2>/dev/null | head -n 1 || true)"
        if test -z "$active_root"; then
          active_root="$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null || true)"
        fi
        os_version="$(sed -n 's/^IMG_VERSION=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
        os_build="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
        kernel_release="$(uname -r 2>/dev/null || true)"
        probe_version="$($probe version 2>/dev/null || true)"
        transport_version="$($transport --version 2>/dev/null || true)"
        transport_active="$(systemctl is-active rmmirror-transport-wake.service 2>/dev/null || true)"
        transport_schema="$(sed -n 's/.*"schema":"\([^"]*\)".*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        wake_endpoint_healthy="$(sed -n 's/.*"wake_endpoint_healthy":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        xovi_version="$(cat "$xovi_version_file" 2>/dev/null | head -n 1 || true)"

        printf '%s\n' "RMMIRROR_CAP_BOOT_ID=$boot_id"
        printf '%s\n' "RMMIRROR_CAP_ACTIVE_ROOT=$active_root"
        printf '%s\n' "RMMIRROR_CAP_OS_VERSION=$os_version"
        printf '%s\n' "RMMIRROR_CAP_OS_BUILD=$os_build"
        printf '%s\n' "RMMIRROR_CAP_KERNEL=$kernel_release"
        printf '%s\n' "RMMIRROR_CAP_PROBE_VERSION=$probe_version"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_VERSION=$transport_version"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_SCHEMA=$transport_schema"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_ACTIVE=$transport_active"
        printf '%s\n' "RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY=$wake_endpoint_healthy"
        printf '%s\n' "RMMIRROR_CAP_XOVI_VERSION=$xovi_version"

        mismatch=0
        test -n "$boot_id" || mismatch=1
        test -n "$active_root" || mismatch=1
        test -n "$os_version" || mismatch=1
        test -n "$os_build" || mismatch=1
        test -n "$kernel_release" || mismatch=1
        test "$probe_version" = '0.4.9' || mismatch=1
        test "$transport_version" = '0.6.0' || mismatch=1
        test "$transport_schema" = 'rmmirror.transport-wake/v1' || mismatch=1
        test "$transport_active" = 'active' || mismatch=1
        test "$wake_endpoint_healthy" = 'true' || mismatch=1
        test "$xovi_version" = 'v19-23052026' || mismatch=1

        if test "$mismatch" -ne 0; then
          printf '%s\n' 'RMMIRROR_ROUTE_PREREQUISITE_MISMATCH=1'
          exit 42
        fi

        printf '%s\n' 'RMMIRROR_ROUTE_READY=1'
        exit 0
        """;

    private readonly SshRoute _route;

    public PassiveRouteProbe(SshRoute route)
    {
        _route = route ?? throw new ArgumentNullException(nameof(route));
    }

    public async Task<PassiveRouteProbeResult> ProbeAsync(CancellationToken cancellationToken)
    {
        var bannerResult = await ProbeBannerAsync(cancellationToken).ConfigureAwait(false);
        if (bannerResult is not null)
        {
            return bannerResult;
        }

        if (!_route.CredentialFilesExist)
        {
            return Result(
                PassiveRouteProbeState.PrerequisiteMismatch,
                PassiveRouteProbeDetail.LocalCredentialFilesMissing);
        }

        return await ProbeAuthenticationAndCapabilitiesAsync(cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<PassiveRouteProbeResult?> ProbeBannerAsync(
        CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        using (var connectCancellation =
               CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            connectCancellation.CancelAfter(ConnectTimeout);
            try
            {
                await client.ConnectAsync(_route.Host, SshPort, connectCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return Result(
                    PassiveRouteProbeState.NoRoute,
                    PassiveRouteProbeDetail.TcpConnectTimedOut);
            }
            catch (Exception exception) when (exception is SocketException or IOException)
            {
                return Result(
                    PassiveRouteProbeState.NoRoute,
                    PassiveRouteProbeDetail.TcpUnavailable);
            }
        }

        try
        {
            using var bannerCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            bannerCancellation.CancelAfter(BannerTimeout);
            try
            {
                return await ContainsRealSshBannerAsync(
                        client.GetStream(),
                        bannerCancellation.Token)
                    .ConfigureAwait(false)
                    ? null
                    : Result(
                        PassiveRouteProbeState.PortOpenNoBanner,
                        PassiveRouteProbeDetail.SshBannerMissing);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return Result(
                    PassiveRouteProbeState.PortOpenNoBanner,
                    PassiveRouteProbeDetail.SshBannerTimedOut);
            }
            catch (Exception exception) when (exception is SocketException or IOException)
            {
                return Result(
                    PassiveRouteProbeState.PortOpenNoBanner,
                    PassiveRouteProbeDetail.SshBannerMissing);
            }
        }
        finally
        {
            UseAbortiveClose(client);
        }
    }

    private static void UseAbortiveClose(TcpClient client)
    {
        try
        {
            var socket = client.Client;
            socket.LingerState = new LingerOption(enable: true, seconds: 0);
            socket.Close(timeout: 0);
        }
        catch (Exception exception) when (exception is SocketException or ObjectDisposedException)
        {
        }
    }

    private async Task<PassiveRouteProbeResult> ProbeAuthenticationAndCapabilitiesAsync(
        CancellationToken cancellationToken)
    {
        using var process = new Process
        {
            StartInfo = _route.CreateProcessStartInfo(
                remoteCommand: CapabilityCommand,
                disablePseudoTerminal: true,
                redirectStandardOutput: true,
                redirectStandardError: true),
        };

        Task<string>? outputDrain = null;
        Task<string>? errorDrain = null;
        var started = false;
        try
        {
            try
            {
                if (!process.Start())
                {
                    return Result(
                        PassiveRouteProbeState.PrerequisiteMismatch,
                        PassiveRouteProbeDetail.OpenSshUnavailable);
                }

                started = true;
                try
                {
                    SshChildProcessJob.AssignOrTerminate(process);
                }
                catch (Win32Exception)
                {
                    started = false;
                    return Result(
                        PassiveRouteProbeState.PrerequisiteMismatch,
                        PassiveRouteProbeDetail.SshProcessOwnershipUnavailable);
                }
            }
            catch (Win32Exception)
            {
                return Result(
                    PassiveRouteProbeState.PrerequisiteMismatch,
                    PassiveRouteProbeDetail.OpenSshUnavailable);
            }

            outputDrain = process.StandardOutput.ReadToEndAsync();
            errorDrain = process.StandardError.ReadToEndAsync();

            using var probeCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            probeCancellation.CancelAfter(AuthenticationTimeout);
            try
            {
                await process.WaitForExitAsync(probeCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return Result(
                    PassiveRouteProbeState.NoRoute,
                    PassiveRouteProbeDetail.AuthenticationTimedOut);
            }

            var standardOutput = await outputDrain.ConfigureAwait(false);
            var standardError = await errorDrain.ConfigureAwait(false);
            return ClassifyAuthenticationResult(
                process.ExitCode,
                standardOutput,
                standardError);
        }
        finally
        {
            if (started)
            {
                if (!process.HasExited)
                {
                    TryTerminate(process);
                }

                await DrainAfterTerminationAsync(process, outputDrain, errorDrain)
                    .ConfigureAwait(false);
            }
        }
    }

    private static async Task<bool> ContainsRealSshBannerAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        var readBuffer = new byte[256];
        var lineBuffer = new byte[MaximumBannerLineBytes];
        var lineBytes = 0;
        var totalBytes = 0;
        var totalLines = 0;

        while (totalBytes < MaximumBannerBytes && totalLines < MaximumBannerLines)
        {
            var remaining = Math.Min(readBuffer.Length, MaximumBannerBytes - totalBytes);
            var read = await stream.ReadAsync(
                    readBuffer.AsMemory(0, remaining),
                    cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                return false;
            }

            totalBytes += read;
            for (var index = 0; index < read; index++)
            {
                var value = readBuffer[index];
                if (value == (byte)'\n')
                {
                    var length = lineBytes;
                    if (length > 0 && lineBuffer[length - 1] == (byte)'\r')
                    {
                        length--;
                    }

                    if (IsRealSshIdentification(lineBuffer.AsSpan(0, length)))
                    {
                        return true;
                    }

                    totalLines++;
                    lineBytes = 0;
                    continue;
                }

                if (lineBytes == lineBuffer.Length)
                {
                    return false;
                }

                lineBuffer[lineBytes++] = value;
            }
        }

        return false;
    }

    private static bool IsRealSshIdentification(ReadOnlySpan<byte> line) =>
        (line.Length > "SSH-2.0-"u8.Length && line.StartsWith("SSH-2.0-"u8)) ||
        (line.Length > "SSH-1.99-"u8.Length && line.StartsWith("SSH-1.99-"u8));

    private static PassiveRouteProbeResult ClassifyAuthenticationResult(
        int exitCode,
        string standardOutput,
        string standardError)
    {
        if (ContainsAny(
                standardError,
                "REMOTE HOST IDENTIFICATION HAS CHANGED",
                "Host key verification failed"))
        {
            return Result(
                PassiveRouteProbeState.IdentityRejected,
                PassiveRouteProbeDetail.HostKeyRejected);
        }

        if (ContainsAny(
                standardError,
                "Permission denied",
                "no supported authentication methods available",
                "Too many authentication failures"))
        {
            return Result(
                PassiveRouteProbeState.IdentityRejected,
                PassiveRouteProbeDetail.AuthenticationRejected);
        }

        if (exitCode == 255)
        {
            return Result(
                PassiveRouteProbeState.NoRoute,
                PassiveRouteProbeDetail.SshConnectionLost);
        }

        var capability = TryParseCapability(standardOutput);
        if (exitCode == 0 &&
            standardOutput.Contains("RMMIRROR_ROUTE_READY=1", StringComparison.Ordinal) &&
            capability is not null)
        {
            return new PassiveRouteProbeResult(
                PassiveRouteProbeState.Authenticated,
                PassiveRouteProbeDetail.None,
                capability);
        }

        if (exitCode == PrerequisiteMismatchExitCode ||
            standardOutput.Contains(
                "RMMIRROR_ROUTE_AUTHENTICATED=1",
                StringComparison.Ordinal))
        {
            return new PassiveRouteProbeResult(
                PassiveRouteProbeState.PrerequisiteMismatch,
                PassiveRouteProbeDetail.TabletPrerequisiteMismatch,
                capability);
        }

        return Result(
            PassiveRouteProbeState.PrerequisiteMismatch,
            PassiveRouteProbeDetail.CapabilityResponseInvalid);
    }

    private static PassiveRouteCapability? TryParseCapability(string output)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = line.IndexOf('=');
            if (separator <= 0 || separator == line.Length - 1)
            {
                continue;
            }

            var key = line[..separator];
            if (!key.StartsWith("RMMIRROR_CAP_", StringComparison.Ordinal))
            {
                continue;
            }
            if (!values.TryAdd(key, line[(separator + 1)..]))
            {
                return null;
            }
        }

        if (!TryGetSafeValue(values, "RMMIRROR_CAP_BOOT_ID", out var bootId) ||
            !Guid.TryParseExact(bootId, "D", out _) ||
            !TryGetSafeUnixPath(values, "RMMIRROR_CAP_ACTIVE_ROOT", out var activeRoot) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_OS_VERSION", out var osVersion) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_OS_BUILD", out var osBuild) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_KERNEL", out var kernelRelease) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_PROBE_VERSION", out var probeVersion) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_TRANSPORT_VERSION", out var transportVersion) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_TRANSPORT_SCHEMA", out var transportSchema) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_TRANSPORT_ACTIVE", out var transportActive) ||
            !TryGetSafeValue(
                values,
                "RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY",
                out var wakeEndpointHealthy) ||
            !TryGetSafeValue(values, "RMMIRROR_CAP_XOVI_VERSION", out var xoviVersion))
        {
            return null;
        }

        return new PassiveRouteCapability(
            bootId,
            activeRoot,
            osVersion,
            osBuild,
            kernelRelease,
            probeVersion,
            transportVersion,
            transportSchema,
            string.Equals(transportActive, "active", StringComparison.Ordinal),
            string.Equals(wakeEndpointHealthy, "true", StringComparison.Ordinal),
            xoviVersion,
            string.Equals(probeVersion, ExpectedProbeVersion, StringComparison.Ordinal) &&
            string.Equals(transportVersion, ExpectedTransportVersion, StringComparison.Ordinal) &&
            string.Equals(transportSchema, ExpectedTransportSchema, StringComparison.Ordinal) &&
            string.Equals(transportActive, "active", StringComparison.Ordinal) &&
            string.Equals(wakeEndpointHealthy, "true", StringComparison.Ordinal) &&
            string.Equals(xoviVersion, ExpectedXoviVersion, StringComparison.Ordinal));
    }

    private static bool TryGetSafeValue(
        IReadOnlyDictionary<string, string> values,
        string key,
        out string value)
    {
        if (!values.TryGetValue(key, out value!) ||
            string.IsNullOrWhiteSpace(value) ||
            value.Length > 256 ||
            value.Any(character => char.IsControl(character)))
        {
            value = string.Empty;
            return false;
        }

        return true;
    }

    private static bool TryGetSafeUnixPath(
        IReadOnlyDictionary<string, string> values,
        string key,
        out string value)
    {
        return TryGetSafeValue(values, key, out value) &&
            value[0] == '/' &&
            !value.Any(char.IsWhiteSpace);
    }

    private static bool ContainsAny(string value, params string[] candidates) =>
        candidates.Any(candidate =>
            value.Contains(candidate, StringComparison.OrdinalIgnoreCase));

    private static PassiveRouteProbeResult Result(
        PassiveRouteProbeState state,
        PassiveRouteProbeDetail detail) =>
        new(state, detail, null);

    private static async Task DrainAfterTerminationAsync(
        Process process,
        Task<string>? outputDrain,
        Task<string>? errorDrain)
    {
        if (!process.HasExited)
        {
            TryTerminate(process);
        }

        using var drainCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        try
        {
            await process.WaitForExitAsync(drainCancellation.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is
            InvalidOperationException or OperationCanceledException)
        {
        }

        if (outputDrain is not null)
        {
            await AwaitDrainAsync(outputDrain).ConfigureAwait(false);
        }
        if (errorDrain is not null)
        {
            await AwaitDrainAsync(errorDrain).ConfigureAwait(false);
        }
    }

    private static async Task AwaitDrainAsync(Task<string> drain)
    {
        try
        {
            await drain.WaitAsync(TimeSpan.FromSeconds(1)).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is
            IOException or InvalidOperationException or TimeoutException)
        {
        }
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception exception) when (exception is
            InvalidOperationException or Win32Exception)
        {
        }
    }
}

internal enum PassiveRouteProbeState
{
    NoRoute,
    PortOpenNoBanner,
    Authenticated,
    IdentityRejected,
    PrerequisiteMismatch,
}

internal enum PassiveRouteProbeDetail
{
    None,
    TcpUnavailable,
    TcpConnectTimedOut,
    SshBannerMissing,
    SshBannerTimedOut,
    LocalCredentialFilesMissing,
    OpenSshUnavailable,
    SshProcessOwnershipUnavailable,
    AuthenticationTimedOut,
    HostKeyRejected,
    AuthenticationRejected,
    SshConnectionLost,
    TabletPrerequisiteMismatch,
    CapabilityResponseInvalid,
}

internal sealed record PassiveRouteProbeResult(
    PassiveRouteProbeState State,
    PassiveRouteProbeDetail Detail,
    PassiveRouteCapability? Capability)
{
    public bool IdentityAuthenticated =>
        State is PassiveRouteProbeState.Authenticated ||
        (State is PassiveRouteProbeState.PrerequisiteMismatch && Capability is not null);
}

internal sealed record PassiveRouteCapability(
    string BootId,
    string ActiveRoot,
    string OsVersion,
    string OsBuild,
    string KernelRelease,
    string ProbeVersion,
    string TransportVersion,
    string TransportSchema,
    bool TransportActive,
    bool WakeEndpointHealthy,
    string XoviVersion,
    bool IsCurrent);
