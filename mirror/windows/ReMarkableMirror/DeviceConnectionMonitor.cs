using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Security;

namespace ReMarkableMirror;

internal sealed class DeviceConnectionMonitor : IDisposable
{
    private static readonly TimeSpan DisconnectedPollInterval = TimeSpan.FromSeconds(3);
    // A bannerless USB endpoint is what this tablet exposes while waiting for
    // its post-reboot passcode unlock. It can also occur during unprovisioned
    // full-system sleep, so poll quietly and continue as soon as Dropbear is
    // available instead of asking the user to retry.
    private static readonly TimeSpan PortOpenPollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan WakeStatePollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan WakingPollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan WakeAttemptInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan WakeGraceInterval = TimeSpan.FromSeconds(10);
    private readonly SemaphoreSlim _probeRequested = new(0, 1);
    private readonly WifiRepairConfirmationPolicy _wifiRepairConfirmationPolicy = new();
    private readonly DeviceRouteKind _kind;
    private readonly SshRoute _route;
    private readonly PassiveRouteProbe _probe;
    private DeviceProfile? _wifiProfile;
    private DeviceProfileVerification? _wifiVerification;
    private string? _wifiInterfaceId;
    private string? _wifiNetworkIdentity;
    private readonly string? _wakeTokenFileReference;
    private TabletWakeClient? _wakeClient;
    private TabletWakeClientCreationStatus _wakeClientCreationStatus;
    private long _lastWakeAttemptTimestamp;
    private bool _hasWakeAttempt;
    private long _lastSuccessfulWakeTimestamp;
    private bool _hasSuccessfulWake;
    private int _disposed;

    private DeviceConnectionMonitor(
        DeviceRouteKind kind,
        SshRoute route,
        DeviceProfile? profile)
    {
        _kind = kind;
        _route = route ?? throw new ArgumentNullException(nameof(route));
        _probe = new PassiveRouteProbe(route);
        _wakeTokenFileReference = profile?.TokenFileReference;
        if (kind is DeviceRouteKind.Wifi)
        {
            _wifiProfile = profile;
            _wifiVerification = profile?.LastVerified;
            _wifiInterfaceId = profile?.PairedWindowsInterfaceId;
            _wifiNetworkIdentity = profile?.PairedWindowsNetworkIdentity;
        }
        else
        {
            RefreshWakeClient();
        }
    }

    public static DeviceConnectionMonitor ForUsb(SshRoute route, DeviceProfile? profile) =>
        new(DeviceRouteKind.Usb, route, profile);

    public static DeviceConnectionMonitor ForWifi(SshRoute route, DeviceProfile? profile) =>
        new(DeviceRouteKind.Wifi, route, profile);

    private Task<DeviceConnectionState> ProbeAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref _disposed) != 0,
            this);

        return _kind switch
        {
            DeviceRouteKind.Usb => ProbeUsbAsync(cancellationToken),
            DeviceRouteKind.Wifi => ProbeWifiAsync(cancellationToken),
            _ => throw new ArgumentOutOfRangeException(nameof(_kind)),
        };
    }

    public async IAsyncEnumerable<DeviceConnectionState> WatchAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var state = await ProbeAsync(cancellationToken)
                .ConfigureAwait(false);
            yield return state;
            if (state.Status is DeviceConnectionStatus.SshReady)
            {
                yield break;
            }

            if (!await WaitForNextProbeAsync(
                    PollIntervalFor(state.Status),
                    cancellationToken)
                .ConfigureAwait(false))
            {
                yield break;
            }
        }
    }

    public void RequestProbe()
    {
        try
        {
            _probeRequested.Release();
        }
        catch (SemaphoreFullException)
        {
            // One pending request is enough to interrupt the current wait.
        }
    }

    private static TimeSpan PollIntervalFor(DeviceConnectionStatus status) => status switch
    {
        DeviceConnectionStatus.Disconnected => DisconnectedPollInterval,
        DeviceConnectionStatus.PortOpenWithoutSshBanner => PortOpenPollInterval,
        DeviceConnectionStatus.UnlockRequired or
            DeviceConnectionStatus.Sleeping or
            DeviceConnectionStatus.Starting or
            DeviceConnectionStatus.WakeSetupRequired or
            DeviceConnectionStatus.WifiNetworkMismatch => WakeStatePollInterval,
        DeviceConnectionStatus.Waking => WakingPollInterval,
        _ => throw new ArgumentOutOfRangeException(nameof(status)),
    };

    private async Task<DeviceConnectionState> ProbeWifiAsync(CancellationToken cancellationToken)
    {
        if (_wifiProfile is { HasWifiPairing: false })
        {
            // A USB-only profile carries no paired Windows network. The owner
            // typed this address, so probe it against the pinned identity and
            // pair the Windows network that carried the authenticated session.
            var state = await ProbeAuthenticatedRouteAsync(cancellationToken)
                .ConfigureAwait(false);
            if (state.Status is DeviceConnectionStatus.SshReady)
            {
                var currentReading = await WindowsNetworkIdentityMatcher.ReadCurrentAsync(
                        _route.Host,
                        cancellationToken)
                    .ConfigureAwait(false);
                if (currentReading is not null)
                {
                    TryRecordWifiPairing(currentReading);
                }
            }
            return state;
        }

        var networkMatch = _wifiInterfaceId is null ||
            _wifiNetworkIdentity is null
                ? WindowsNetworkMatchResult.Mismatch
                : await WindowsNetworkIdentityMatcher.EvaluateAsync(
                        _route.Host,
                        _wifiInterfaceId,
                        _wifiNetworkIdentity,
                        cancellationToken)
                    .ConfigureAwait(false);
        if (networkMatch is not WindowsNetworkMatchResult.Match)
        {
            _wifiRepairConfirmationPolicy.Reset();
            // This check is deliberately before the banner scan: a route or
            // Windows network mismatch must produce zero tablet LAN traffic.
            return new DeviceConnectionState(
                networkMatch is WindowsNetworkMatchResult.Mismatch
                    ? DeviceConnectionStatus.WifiNetworkMismatch
                    : DeviceConnectionStatus.Disconnected);
        }

        return await ProbeAuthenticatedRouteAsync(cancellationToken).ConfigureAwait(false);
    }

    private void TryRecordWifiPairing(WindowsNetworkIdentityReading reading)
    {
        var profile = _wifiProfile;
        if (profile is null)
        {
            return;
        }

        var paired = profile with
        {
            LastVerifiedWifiHost = _route.Host,
            PairedWindowsInterfaceId = reading.InterfaceId,
            PairedWindowsNetworkIdentity = reading.NetworkIdentity,
        };
        if (!TrySaveProfile(paired))
        {
            return;
        }

        _wifiProfile = paired;
        _wifiInterfaceId = reading.InterfaceId;
        _wifiNetworkIdentity = reading.NetworkIdentity;
    }

    private static bool TrySaveProfile(DeviceProfile profile)
    {
        try
        {
            new DeviceProfileStore().Save(profile);
            return true;
        }
        catch (Exception exception) when (exception is
            ArgumentException or
            InvalidOperationException or
            IOException or
            NotSupportedException or
            SecurityException or
            UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task<DeviceConnectionState> ProbeUsbAsync(CancellationToken cancellationToken)
    {
        var usbInterfacePresent = TabletWakeClient.HasDirectUsbInterface();
        if ((_wakeClientCreationStatus is TabletWakeClientCreationStatus.UsbUnavailable &&
             usbInterfacePresent) ||
            (_wakeClient is not null && !usbInterfacePresent))
        {
            RefreshWakeClient(force: true);
        }
        if (!usbInterfacePresent)
        {
            return UsbState(DeviceConnectionStatus.Disconnected);
        }

        var sshState = await ProbeAuthenticatedRouteAsync(cancellationToken).ConfigureAwait(false);
        if (sshState.Status is
            DeviceConnectionStatus.SshReady or
            DeviceConnectionStatus.WakeSetupRequired)
        {
            _hasSuccessfulWake = false;
            return sshState;
        }
        var sshStatus = sshState.Status;

        var wakeClient = _wakeClient;
        var wakeClientCreationStatus = _wakeClientCreationStatus;
        if (wakeClient is null)
        {
            var status = wakeClientCreationStatus is
                TabletWakeClientCreationStatus.MissingToken or
                TabletWakeClientCreationStatus.InvalidToken or
                TabletWakeClientCreationStatus.AccessDenied or
                TabletWakeClientCreationStatus.InvalidConfiguration
                    ? DeviceConnectionStatus.WakeSetupRequired
                    : sshStatus;
            return UsbState(status);
        }

        TabletWakeResponse? wakeStatus;
        try
        {
            wakeStatus = await wakeClient.GetStatusAsync(cancellationToken).ConfigureAwait(false);
            if (wakeStatus is null)
            {
                return UsbState(sshStatus);
            }

            if (wakeStatus.State is TabletWakeState.Sleeping &&
                TryBeginWakeAttempt())
            {
                var wakeResponse = await wakeClient.WakeAsync(cancellationToken).ConfigureAwait(false);
                if (wakeResponse is not null)
                {
                    wakeStatus = wakeResponse;
                    if (wakeResponse.WakeSent)
                    {
                        _lastSuccessfulWakeTimestamp = Stopwatch.GetTimestamp();
                        _hasSuccessfulWake = true;
                    }
                }
            }
        }
        catch (TabletWakeAuthenticationException)
        {
            return UsbState(DeviceConnectionStatus.WakeSetupRequired);
        }

        if (wakeStatus.State is TabletWakeState.Sleeping && IsWakeGraceActive())
        {
            return UsbState(DeviceConnectionStatus.Waking);
        }

        if (wakeStatus.State is not TabletWakeState.Sleeping)
        {
            _hasSuccessfulWake = false;
        }

        var resolvedStatus = wakeStatus.State switch
        {
            TabletWakeState.UnlockRequired => DeviceConnectionStatus.UnlockRequired,
            TabletWakeState.Sleeping => DeviceConnectionStatus.Sleeping,
            TabletWakeState.Ready or TabletWakeState.Starting => DeviceConnectionStatus.Starting,
            _ => sshStatus,
        };
        return UsbState(resolvedStatus);
    }

    private async Task<DeviceConnectionState> ProbeAuthenticatedRouteAsync(
        CancellationToken cancellationToken)
    {
        var result = await _probe.ProbeAsync(cancellationToken).ConfigureAwait(false);
        if (result.State is PassiveRouteProbeState.Authenticated &&
            result.Capability is { MeetsRuntimeContract: true } capability)
        {
            if (_kind is DeviceRouteKind.Wifi)
            {
                _wifiRepairConfirmationPolicy.Reset();
            }
            var profileMatches = _kind is DeviceRouteKind.Usb || MatchesWifiProfile(capability);
            if (!profileMatches &&
                _kind is DeviceRouteKind.Wifi)
            {
                profileMatches = TryRefreshWifiVerification(capability);
            }
            if (profileMatches)
            {
                return new DeviceConnectionState(
                    DeviceConnectionStatus.SshReady,
                    _route,
                    _kind);
            }
        }

        if (_kind is DeviceRouteKind.Wifi &&
            result.State is not PassiveRouteProbeState.IdentityRejected and
                not PassiveRouteProbeState.PrerequisiteMismatch)
        {
            _wifiRepairConfirmationPolicy.Reset();
        }

        var status = result.State is PassiveRouteProbeState.IdentityRejected or
                PassiveRouteProbeState.PrerequisiteMismatch
            ? ResolveSetupFailureStatus(result)
            : result.State is PassiveRouteProbeState.PortOpenNoBanner
                ? DeviceConnectionStatus.PortOpenWithoutSshBanner
                : DeviceConnectionStatus.Disconnected;
        return new DeviceConnectionState(
            status,
            ProbeDetail: result.Detail);
    }

    private DeviceConnectionStatus ResolveSetupFailureStatus(
        PassiveRouteProbeResult result)
    {
        if (_kind is DeviceRouteKind.Usb)
        {
            return DeviceConnectionStatus.WakeSetupRequired;
        }

        var confirmedTabletMismatch = _wifiRepairConfirmationPolicy.Record(
            result.IdentityAuthenticated,
            result.Detail is PassiveRouteProbeDetail.TabletPrerequisiteMismatch);
        return confirmedTabletMismatch
            ? DeviceConnectionStatus.WakeSetupRequired
            : DeviceConnectionStatus.Disconnected;
    }

    private bool MatchesWifiProfile(PassiveRouteCapability capability)
    {
        var verification = _wifiVerification;
        return verification is not null &&
            string.Equals(capability.ActiveRoot, verification.ActiveRoot, StringComparison.Ordinal) &&
            string.Equals(capability.KernelRelease, verification.KernelRelease, StringComparison.Ordinal) &&
            string.Equals(
                $"IMG_VERSION={capability.OsVersion};VERSION_ID={capability.OsBuild}",
                verification.OsVersion,
                StringComparison.Ordinal) &&
            string.Equals(
                capability.TransportVersion,
                verification.CompanionVersion,
                StringComparison.Ordinal) &&
            string.Equals(
                verification.WakeCapabilitySchema,
                "rmmirror.wake/v1",
                StringComparison.Ordinal);
    }

    private bool TryRefreshWifiVerification(PassiveRouteCapability capability)
    {
        var profile = _wifiProfile;
        var previous = _wifiVerification;
        if (profile is null ||
            previous is null ||
            !string.Equals(
                previous.WakeCapabilitySchema,
                "rmmirror.wake/v1",
                StringComparison.Ordinal))
        {
            return false;
        }

        var verification = new DeviceProfileVerification(
            DateTimeOffset.UtcNow,
            capability.BootId,
            capability.ActiveRoot,
            $"IMG_VERSION={capability.OsVersion};VERSION_ID={capability.OsBuild}",
            capability.KernelRelease,
            previous.WakeCapabilitySchema,
            capability.TransportVersion);
        var refreshed = profile with { LastVerified = verification };
        if (!TrySaveProfile(refreshed))
        {
            return false;
        }

        _wifiProfile = refreshed;
        _wifiVerification = verification;
        return MatchesWifiProfile(capability);
    }

    private DeviceConnectionState UsbState(DeviceConnectionStatus status) =>
        new(status);

    private void RefreshWakeClient(bool force = false)
    {
        if (!force && _wakeClient is not null)
        {
            return;
        }

        // Never let the bearer follow a generic route to 10.11.99.1. It is
        // available only while Windows owns the observed USB /27 address.
        var creation = TabletWakeClient.HasDirectUsbInterface()
            ? TabletWakeClient.TryCreateUsb(_wakeTokenFileReference)
            : new TabletWakeClientCreationResult(
                null,
                TabletWakeClientCreationStatus.UsbUnavailable);
        var previousClient = _wakeClient;
        _wakeClient = creation.Client;
        _wakeClientCreationStatus = creation.Status;
        previousClient?.Dispose();
    }

    private bool TryBeginWakeAttempt()
    {
        var now = Stopwatch.GetTimestamp();
        if (_hasWakeAttempt &&
            Stopwatch.GetElapsedTime(_lastWakeAttemptTimestamp, now) < WakeAttemptInterval)
        {
            return false;
        }

        _lastWakeAttemptTimestamp = now;
        _hasWakeAttempt = true;
        return true;
    }

    private bool IsWakeGraceActive() =>
        _hasSuccessfulWake &&
        Stopwatch.GetElapsedTime(_lastSuccessfulWakeTimestamp) < WakeGraceInterval;

    private async Task<bool> WaitForNextProbeAsync(
        TimeSpan interval,
        CancellationToken cancellationToken)
    {
        using var waitCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var delay = Task.Delay(interval, waitCancellation.Token);
        var requested = _probeRequested.WaitAsync(waitCancellation.Token);
        try
        {
            await Task.WhenAny(delay, requested).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        finally
        {
            waitCancellation.Cancel();
            await IgnoreCancellationAsync(delay).ConfigureAwait(false);
            await IgnoreCancellationAsync(requested).ConfigureAwait(false);
        }
    }

    private static async Task IgnoreCancellationAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        var wakeClient = _wakeClient;
        _wakeClient = null;
        wakeClient?.Dispose();
        _probeRequested.Dispose();
    }

}

internal enum DeviceConnectionStatus
{
    Disconnected,
    PortOpenWithoutSshBanner,
    UnlockRequired,
    Sleeping,
    Waking,
    Starting,
    WakeSetupRequired,
    WifiNetworkMismatch,
    SshReady,
}

internal enum DeviceRouteKind
{
    Usb,
    Wifi,
}

internal sealed record DeviceConnectionState(
    DeviceConnectionStatus Status,
    SshRoute? SelectedRoute = null,
    DeviceRouteKind? RouteKind = null,
    PassiveRouteProbeDetail ProbeDetail = PassiveRouteProbeDetail.None)
{
    public bool IsSshReady =>
        Status is DeviceConnectionStatus.SshReady &&
        SelectedRoute is not null &&
        RouteKind is not null;
}
