using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security;

namespace ReMarkableMirror;

public sealed class DeviceConnectionMonitor : IDisposable
{
    private static readonly TimeSpan DisconnectedPollInterval = TimeSpan.FromSeconds(3);
    // A bannerless USB endpoint is what this tablet exposes while waiting for
    // its post-reboot passcode unlock. It can also occur during unprovisioned
    // full-system sleep, so poll quietly and continue as soon as Dropbear is
    // available instead of asking the user to retry.
    private static readonly TimeSpan PortOpenPollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan WakeStatePollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan WakingPollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan SshReadyPollInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan WakeAttemptInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan WakeGraceInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan UsbPromotionCooldown = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan ActiveRouteTransientFailureLimit = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan UsbPromotionHealthyMinimum = TimeSpan.FromSeconds(2);
    private const int ActiveRouteTransientFailureThreshold = 3;
    private const int UsbPromotionHealthyProbeThreshold = 2;
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan BannerTimeout = TimeSpan.FromSeconds(2);
    private const int MaximumBannerBytes = 1024;
    private readonly SemaphoreSlim _probeRequested = new(0, 1);
    private readonly object _wakeClientGate = new();
    private readonly WifiRepairConfirmationPolicy _wifiRepairConfirmationPolicy = new();
    private readonly SshRoute _usbRoute;
    private readonly SshRoute? _wifiRoute;
    private DeviceProfile? _wifiProfile;
    private DeviceProfileVerification? _wifiVerification;
    private readonly bool _wifiRequiresProfileMatch;
    private readonly string? _wifiInterfaceId;
    private readonly string? _wifiNetworkIdentity;
    private readonly string? _wakeTokenFileReference;
    private readonly PassiveRouteProbe _usbProbe;
    private readonly PassiveRouteProbe? _wifiProbe;
    private readonly int _port;
    private TabletWakeClient? _wakeClient;
    private TabletWakeClientCreationStatus _wakeClientCreationStatus;
    private int _wakeClientRefreshRequested;
    private long _lastWakeAttemptTimestamp;
    private bool _hasWakeAttempt;
    private long _lastSuccessfulWakeTimestamp;
    private bool _hasSuccessfulWake;
    private int _activeRouteKind = -1;
    private int _activeWifiTransientFailureCount;
    private long _activeWifiTransientFailureStartedTimestamp;
    private int _activeUsbTransientFailureCount;
    private long _activeUsbTransientFailureStartedTimestamp;
    private int _healthyUsbCandidateProbeCount;
    private long _healthyUsbCandidateStartedTimestamp;
    private long _usbPromotionSuppressedUntilTimestamp;
    private int _disposed;

    public DeviceConnectionMonitor(string host, int port) :
        this(new SshRoute(host), port)
    {
    }

    public DeviceConnectionMonitor(SshRoute route, int port)
        : this(route, null, null, false, port)
    {
    }

    public DeviceConnectionMonitor(
        SshRoute usbRoute,
        SshRoute? wifiRoute,
        DeviceProfile? wifiProfile,
        bool wifiRequiresProfileMatch,
        int port)
    {
        _usbRoute = usbRoute ?? throw new ArgumentNullException(nameof(usbRoute));
        _wifiRoute = wifiRoute;
        _wifiProfile = wifiProfile;
        _wifiVerification = wifiProfile?.LastVerified;
        _wifiRequiresProfileMatch = wifiRequiresProfileMatch;
        _wifiInterfaceId = wifiProfile?.PairedWindowsInterfaceId;
        _wifiNetworkIdentity = wifiProfile?.PairedWindowsNetworkIdentity;
        _wakeTokenFileReference = wifiProfile?.TokenFileReference;
        _usbProbe = new PassiveRouteProbe(_usbRoute);
        _wifiProbe = wifiRoute is null ? null : new PassiveRouteProbe(wifiRoute);
        _port = port;
        RefreshWakeClient();
    }

    public void SetActiveRouteKind(DeviceRouteKind? routeKind)
    {
        var next = routeKind is null ? -1 : (int)routeKind.Value;
        if (Interlocked.Exchange(ref _activeRouteKind, next) != next)
        {
            _wifiRepairConfirmationPolicy.Reset();
            ResetActiveWifiTransientFailures();
            ResetActiveUsbTransientFailures();
            ResetHealthyUsbCandidate();
        }
    }

    public async Task<DeviceConnectionState> ProbeSelectedRouteAsync(
        DeviceRouteKind routeKind,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref _disposed) != 0,
            this);

        return routeKind switch
        {
            DeviceRouteKind.Usb =>
                await ProbeUsbAsync(cancellationToken).ConfigureAwait(false),
            DeviceRouteKind.Wifi when _wifiRoute is not null =>
                (await ProbeWifiAsync(cancellationToken).ConfigureAwait(false)).State,
            DeviceRouteKind.Wifi => new DeviceConnectionState(
                DeviceConnectionStatus.Disconnected,
                string.Empty,
                _port),
            _ => throw new ArgumentOutOfRangeException(nameof(routeKind)),
        };
    }

    public async IAsyncEnumerable<DeviceConnectionState> WatchSelectedAsync(
        DeviceRouteKind routeKind,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var state = await ProbeSelectedRouteAsync(routeKind, cancellationToken)
                .ConfigureAwait(false);
            yield return state;

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
        Interlocked.Exchange(ref _wakeClientRefreshRequested, 1);
        try
        {
            _probeRequested.Release();
        }
        catch (SemaphoreFullException)
        {
            // One pending request is enough to interrupt the current wait.
        }
    }

    public void ReportUsbPromotionFailed()
    {
        ResetHealthyUsbCandidate();
        var cooldownTicks = (long)(UsbPromotionCooldown.TotalSeconds * Stopwatch.Frequency);
        Interlocked.Exchange(
            ref _usbPromotionSuppressedUntilTimestamp,
            Stopwatch.GetTimestamp() + cooldownTicks);
        RequestProbe();
    }

    public void ConfirmUsbPromotionSucceeded() =>
        Interlocked.Exchange(ref _usbPromotionSuppressedUntilTimestamp, 0);

    public async IAsyncEnumerable<DeviceConnectionState> WatchAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var state = await ProbeAsync(cancellationToken).ConfigureAwait(false);
            yield return state;

            if (!await WaitForNextProbeAsync(
                    PollIntervalFor(state.Status),
                    cancellationToken)
                .ConfigureAwait(false))
            {
                yield break;
            }
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
        DeviceConnectionStatus.SshReady => SshReadyPollInterval,
        _ => throw new ArgumentOutOfRangeException(nameof(status)),
    };

    private async Task<DeviceConnectionState> ProbeAsync(CancellationToken cancellationToken)
    {
        var activeKindValue = Volatile.Read(ref _activeRouteKind);
        if (activeKindValue == (int)DeviceRouteKind.Usb &&
            IsUsbPromotionSuppressed() &&
            _wifiRoute is not null)
        {
            var rollbackWifi = (await ProbeWifiAsync(cancellationToken).ConfigureAwait(false)).State;
            if (rollbackWifi.IsSshReady)
            {
                return rollbackWifi;
            }
        }

        if (activeKindValue == (int)DeviceRouteKind.Usb)
        {
            var activeUsb = await ProbeUsbAsync(cancellationToken).ConfigureAwait(false);
            if (activeUsb.IsSshReady)
            {
                ResetActiveUsbTransientFailures();
                return activeUsb;
            }

            var isTransient = activeUsb.Status is (
                DeviceConnectionStatus.Disconnected or
                DeviceConnectionStatus.PortOpenWithoutSshBanner);
            if (isTransient && ShouldRetainActiveUsbAfterTransientFailure())
            {
                return new DeviceConnectionState(
                    DeviceConnectionStatus.SshReady,
                    _usbRoute.Host,
                    _port,
                    _usbRoute,
                    DeviceRouteKind.Usb);
            }

            ResetActiveUsbTransientFailures();
            if (_wifiRoute is not null)
            {
                var fallbackWifi = (await ProbeWifiAsync(cancellationToken).ConfigureAwait(false)).State;
                if (fallbackWifi.IsSshReady)
                {
                    return fallbackWifi;
                }
            }
            return activeUsb;
        }

        if (activeKindValue == (int)DeviceRouteKind.Wifi && _wifiRoute is not null)
        {
            var activeWifiOutcome = await ProbeWifiAsync(cancellationToken)
                .ConfigureAwait(false);
            var activeWifi = activeWifiOutcome.State;
            if (!activeWifi.IsSshReady)
            {
                var isTransient = activeWifiOutcome.NetworkMatch is not
                        WindowsNetworkMatchResult.Mismatch &&
                    activeWifi.Status is (
                        DeviceConnectionStatus.Disconnected or
                        DeviceConnectionStatus.PortOpenWithoutSshBanner);
                if (isTransient && ShouldRetainActiveWifiAfterTransientFailure())
                {
                    return new DeviceConnectionState(
                        DeviceConnectionStatus.SshReady,
                        _wifiRoute.Host,
                        _port,
                        _wifiRoute,
                        DeviceRouteKind.Wifi);
                }

                ResetActiveWifiTransientFailures();
                ResetHealthyUsbCandidate();
                var usbAfterWifiLoss = await ProbePassiveUsbCandidateAsync(cancellationToken)
                    .ConfigureAwait(false);
                return usbAfterWifiLoss.IsSshReady ? usbAfterWifiLoss : activeWifi;
            }

            ResetActiveWifiTransientFailures();
            if (IsUsbPromotionSuppressed())
            {
                ResetHealthyUsbCandidate();
                return activeWifi;
            }
            var preferredUsb = await ProbePassiveUsbCandidateAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!preferredUsb.IsSshReady)
            {
                ResetHealthyUsbCandidate();
                return activeWifi;
            }
            return IsHealthyUsbCandidateReadyForPromotion()
                ? preferredUsb
                : activeWifi;
        }

        ResetActiveWifiTransientFailures();
        ResetActiveUsbTransientFailures();
        ResetHealthyUsbCandidate();

        if (IsUsbPromotionSuppressed() && _wifiRoute is not null)
        {
            var preferredWifi = (await ProbeWifiAsync(cancellationToken).ConfigureAwait(false)).State;
            if (preferredWifi.IsSshReady)
            {
                return preferredWifi;
            }
        }

        var usb = await ProbeUsbAsync(cancellationToken).ConfigureAwait(false);
        if (usb.IsSshReady || _wifiRoute is null)
        {
            return usb;
        }

        var wifi = (await ProbeWifiAsync(cancellationToken).ConfigureAwait(false)).State;
        var wifiHasUsefulFailureDetail =
            usb.Status is DeviceConnectionStatus.Disconnected &&
            wifi.Status is DeviceConnectionStatus.Disconnected &&
            wifi.ProbeDetail is not PassiveRouteProbeDetail.None;
        return wifi.IsSshReady || wifiHasUsefulFailureDetail || wifi.Status is
                DeviceConnectionStatus.WakeSetupRequired or
                DeviceConnectionStatus.WifiNetworkMismatch
            ? wifi
            : usb;
    }

    private bool IsUsbPromotionSuppressed()
    {
        var until = Interlocked.Read(ref _usbPromotionSuppressedUntilTimestamp);
        return until != 0 && Stopwatch.GetTimestamp() < until;
    }

    private bool ShouldRetainActiveWifiAfterTransientFailure() =>
        ShouldRetainAfterTransientFailure(
            ref _activeWifiTransientFailureCount,
            ref _activeWifiTransientFailureStartedTimestamp);

    private bool ShouldRetainActiveUsbAfterTransientFailure() =>
        ShouldRetainAfterTransientFailure(
            ref _activeUsbTransientFailureCount,
            ref _activeUsbTransientFailureStartedTimestamp);

    private static bool ShouldRetainAfterTransientFailure(
        ref int failureCount,
        ref long startedTimestamp)
    {
        var now = Stopwatch.GetTimestamp();
        var count = Interlocked.Increment(ref failureCount);
        if (count == 1)
        {
            Interlocked.CompareExchange(ref startedTimestamp, now, 0);
        }
        var started = Interlocked.Read(ref startedTimestamp);
        return count < ActiveRouteTransientFailureThreshold &&
            Stopwatch.GetElapsedTime(started, now) < ActiveRouteTransientFailureLimit;
    }

    private bool IsHealthyUsbCandidateReadyForPromotion()
    {
        var now = Stopwatch.GetTimestamp();
        var count = Interlocked.Increment(ref _healthyUsbCandidateProbeCount);
        if (count == 1)
        {
            Interlocked.CompareExchange(ref _healthyUsbCandidateStartedTimestamp, now, 0);
        }
        var started = Interlocked.Read(ref _healthyUsbCandidateStartedTimestamp);
        return count >= UsbPromotionHealthyProbeThreshold &&
            Stopwatch.GetElapsedTime(started, now) >= UsbPromotionHealthyMinimum;
    }

    private void ResetActiveWifiTransientFailures()
    {
        Interlocked.Exchange(ref _activeWifiTransientFailureCount, 0);
        Interlocked.Exchange(ref _activeWifiTransientFailureStartedTimestamp, 0);
    }

    private void ResetActiveUsbTransientFailures()
    {
        Interlocked.Exchange(ref _activeUsbTransientFailureCount, 0);
        Interlocked.Exchange(ref _activeUsbTransientFailureStartedTimestamp, 0);
    }

    private void ResetHealthyUsbCandidate()
    {
        Interlocked.Exchange(ref _healthyUsbCandidateProbeCount, 0);
        Interlocked.Exchange(ref _healthyUsbCandidateStartedTimestamp, 0);
    }

    private async Task<WifiProbeOutcome> ProbeWifiAsync(CancellationToken cancellationToken)
    {
        if (_wifiRoute is null || _wifiProbe is null)
        {
            return new WifiProbeOutcome(
                new DeviceConnectionState(
                    DeviceConnectionStatus.Disconnected,
                    string.Empty,
                    _port),
                WindowsNetworkMatchResult.Unavailable);
        }

        if (_wifiRequiresProfileMatch)
        {
            var networkMatch = _wifiInterfaceId is null ||
                _wifiNetworkIdentity is null
                    ? WindowsNetworkMatchResult.Mismatch
                    : await WindowsNetworkIdentityMatcher.EvaluateAsync(
                            _wifiRoute.Host,
                            _wifiInterfaceId,
                            _wifiNetworkIdentity,
                            cancellationToken)
                        .ConfigureAwait(false);
            if (networkMatch is not WindowsNetworkMatchResult.Match)
            {
                _wifiRepairConfirmationPolicy.Reset();
                // This check is deliberately before the banner scan: a route or
                // Windows network mismatch must produce zero tablet LAN traffic.
                return new WifiProbeOutcome(
                    new DeviceConnectionState(
                        networkMatch is WindowsNetworkMatchResult.Mismatch
                            ? DeviceConnectionStatus.WifiNetworkMismatch
                            : DeviceConnectionStatus.Disconnected,
                        _wifiRoute.Host,
                        _port),
                    networkMatch);
            }
        }

        var state = await ProbeAuthenticatedRouteAsync(
                _wifiRoute,
                _wifiProbe,
                DeviceRouteKind.Wifi,
                requireProfileMatch: _wifiRequiresProfileMatch,
                cancellationToken)
            .ConfigureAwait(false);
        return new WifiProbeOutcome(state, WindowsNetworkMatchResult.Match);
    }

    private async Task<DeviceConnectionState> ProbeUsbAsync(CancellationToken cancellationToken)
    {
        var usbInterfacePresent = TabletWakeClient.HasDirectUsbInterface();
        if (Interlocked.Exchange(ref _wakeClientRefreshRequested, 0) != 0 ||
            (_wakeClientCreationStatus is TabletWakeClientCreationStatus.UsbUnavailable &&
             usbInterfacePresent) ||
            (_wakeClient is not null && !usbInterfacePresent))
        {
            RefreshWakeClient(force: true);
        }
        if (!usbInterfacePresent)
        {
            return UsbState(DeviceConnectionStatus.Disconnected);
        }

        var sshStatus = await ProbeUsbSshAsync(cancellationToken).ConfigureAwait(false);
        if (sshStatus is DeviceConnectionStatus.SshReady)
        {
            _hasSuccessfulWake = false;
            return await AuthenticateUsbAsync(cancellationToken).ConfigureAwait(false);
        }

        TabletWakeClient? wakeClient;
        TabletWakeClientCreationStatus wakeClientCreationStatus;
        lock (_wakeClientGate)
        {
            wakeClient = _wakeClient;
            wakeClientCreationStatus = _wakeClientCreationStatus;
        }
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

    private Task<DeviceConnectionState> ProbePassiveUsbCandidateAsync(
        CancellationToken cancellationToken) =>
        TabletWakeClient.HasDirectUsbInterface()
            ? AuthenticateUsbAsync(cancellationToken)
            : Task.FromResult(UsbState(DeviceConnectionStatus.Disconnected));

    private Task<DeviceConnectionState> AuthenticateUsbAsync(CancellationToken cancellationToken) =>
        ProbeAuthenticatedRouteAsync(
            _usbRoute,
            _usbProbe,
            DeviceRouteKind.Usb,
            requireProfileMatch: false,
            cancellationToken);

    private async Task<DeviceConnectionState> ProbeAuthenticatedRouteAsync(
        SshRoute route,
        PassiveRouteProbe probe,
        DeviceRouteKind kind,
        bool requireProfileMatch,
        CancellationToken cancellationToken)
    {
        var result = await probe.ProbeAsync(cancellationToken).ConfigureAwait(false);
        if (result.State is PassiveRouteProbeState.Authenticated &&
            result.Capability is { IsCurrent: true } capability)
        {
            if (kind is DeviceRouteKind.Wifi)
            {
                _wifiRepairConfirmationPolicy.Reset();
            }
            var profileMatches = !requireProfileMatch || MatchesWifiProfile(capability);
            if (!profileMatches &&
                requireProfileMatch &&
                kind is DeviceRouteKind.Wifi)
            {
                profileMatches = TryRefreshWifiVerification(capability);
            }
            if (profileMatches)
            {
                return new DeviceConnectionState(
                    DeviceConnectionStatus.SshReady,
                    route.Host,
                    _port,
                    route,
                    kind);
            }
        }

        if (kind is DeviceRouteKind.Wifi &&
            result.State is not PassiveRouteProbeState.IdentityRejected and
                not PassiveRouteProbeState.PrerequisiteMismatch)
        {
            _wifiRepairConfirmationPolicy.Reset();
        }

        var status = result.State is PassiveRouteProbeState.IdentityRejected or
                PassiveRouteProbeState.PrerequisiteMismatch
            ? ResolveSetupFailureStatus(kind, result)
            : result.State is PassiveRouteProbeState.PortOpenNoBanner
                ? DeviceConnectionStatus.PortOpenWithoutSshBanner
                : DeviceConnectionStatus.Disconnected;
        return new DeviceConnectionState(
            status,
            route.Host,
            _port,
            null,
            null,
            result.Detail);
    }

    private DeviceConnectionStatus ResolveSetupFailureStatus(
        DeviceRouteKind kind,
        PassiveRouteProbeResult result)
    {
        if (kind is DeviceRouteKind.Usb)
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
        try
        {
            new DeviceProfileStore().Save(refreshed);
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

        _wifiProfile = refreshed;
        _wifiVerification = verification;
        return MatchesWifiProfile(capability);
    }

    private DeviceConnectionState UsbState(DeviceConnectionStatus status) =>
        new(status, _usbRoute.Host, _port, null, null);

    private void RefreshWakeClient(bool force = false)
    {
        TabletWakeClient? previousClient;
        lock (_wakeClientGate)
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
            previousClient = _wakeClient;
            _wakeClient = creation.Client;
            _wakeClientCreationStatus = creation.Status;
        }
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

    private async Task<DeviceConnectionStatus> ProbeUsbSshAsync(CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        connectTimeout.CancelAfter(ConnectTimeout);

        try
        {
            await client.ConnectAsync(_usbRoute.Host, _port, connectTimeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return DeviceConnectionStatus.Disconnected;
        }
        catch (SocketException)
        {
            return DeviceConnectionStatus.Disconnected;
        }

        try
        {
            using var bannerTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            bannerTimeout.CancelAfter(BannerTimeout);
            try
            {
                return await HasValidSshBannerAsync(client.GetStream(), bannerTimeout.Token)
                        .ConfigureAwait(false)
                    ? DeviceConnectionStatus.SshReady
                    : DeviceConnectionStatus.PortOpenWithoutSshBanner;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return DeviceConnectionStatus.PortOpenWithoutSshBanner;
            }
            catch (IOException)
            {
                return DeviceConnectionStatus.PortOpenWithoutSshBanner;
            }
            catch (SocketException)
            {
                return DeviceConnectionStatus.PortOpenWithoutSshBanner;
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

    private static async Task<bool> HasValidSshBannerAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[MaximumBannerBytes];
        var buffered = 0;
        var lineStart = 0;

        while (buffered < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(buffered), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                return false;
            }
            buffered += read;

            for (var index = lineStart; index < buffered; index++)
            {
                if (buffer[index] != (byte)'\n')
                {
                    continue;
                }

                var line = buffer.AsSpan(lineStart, index - lineStart);
                if (!line.IsEmpty && line[^1] == (byte)'\r')
                {
                    line = line[..^1];
                }
                if (IsValidSshBanner(line))
                {
                    return true;
                }

                lineStart = index + 1;
            }
        }

        return false;
    }

    private static bool IsValidSshBanner(ReadOnlySpan<byte> line)
    {
        ReadOnlySpan<byte> ssh2Prefix = "SSH-2.0-"u8;
        ReadOnlySpan<byte> compatibilityPrefix = "SSH-1.99-"u8;
        var prefixLength = line.StartsWith(ssh2Prefix)
            ? ssh2Prefix.Length
            : line.StartsWith(compatibilityPrefix)
                ? compatibilityPrefix.Length
                : 0;
        if (prefixLength == 0 || line.Length == prefixLength)
        {
            return false;
        }

        // RFC 4253 identification strings are printable US-ASCII. Rejecting
        // control/non-ASCII bytes keeps an unrelated listener from looking ready.
        foreach (var value in line[prefixLength..])
        {
            if (value is < 0x20 or > 0x7e)
            {
                return false;
            }
        }
        return true;
    }

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

        TabletWakeClient? wakeClient;
        lock (_wakeClientGate)
        {
            wakeClient = _wakeClient;
            _wakeClient = null;
        }
        wakeClient?.Dispose();
        _probeRequested.Dispose();
    }

    private sealed record WifiProbeOutcome(
        DeviceConnectionState State,
        WindowsNetworkMatchResult NetworkMatch);
}

public enum DeviceConnectionStatus
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

public enum DeviceRouteKind
{
    Usb,
    Wifi,
}

public sealed record DeviceConnectionState(
    DeviceConnectionStatus Status,
    string Host,
    int Port,
    SshRoute? SelectedRoute = null,
    DeviceRouteKind? RouteKind = null,
    PassiveRouteProbeDetail ProbeDetail = PassiveRouteProbeDetail.None)
{
    public bool IsPortOpen => Status is DeviceConnectionStatus.PortOpenWithoutSshBanner or
        DeviceConnectionStatus.SshReady;

    public bool IsSshReady =>
        Status is DeviceConnectionStatus.SshReady &&
        SelectedRoute is not null &&
        RouteKind is not null;

    // Compatibility alias for callers that only need to know whether opening
    // a real SSH session is appropriate.
    public bool IsConnected => IsSshReady;
}
