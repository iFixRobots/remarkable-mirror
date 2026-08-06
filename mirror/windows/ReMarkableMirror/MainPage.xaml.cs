using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Composition;
using Microsoft.UI.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using ReMarkableMirror.Files;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace ReMarkableMirror;

public sealed partial class MainPage : Page
{
    private static readonly TimeSpan WifiInputActivityInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan UsbInputActivityInterval = TimeSpan.FromSeconds(45);

    private const int FilesPaneWidth = 320;
    private const double FilesPaneOpenDurationSeconds = 0.250;
    private const double FilesPaneCloseDurationSeconds = 0.167;
    private const float StageCornerRadius = 24;
    private const int AutomaticFrameRetryLimit = 4;
    private static readonly TimeSpan UsbPromotionReadyTimeout = TimeSpan.FromSeconds(35);
    private static readonly TimeSpan CoupledInputRecoveryWindow = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan InputStopObservationWindow = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan CompletedDocumentDragRetention = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan StaleDocumentDragRetention = TimeSpan.FromDays(1);
    private const int ClipboardCannotOpenHResult = unchecked((int)0x800401D0);
    private static readonly StartupRouteConfiguration StartupRoutes = ResolveStartupRoutes();
    private readonly DeviceConnectionMonitor _connectionMonitor = new(
        StartupRoutes.UsbRoute,
        StartupRoutes.WifiRoute,
        StartupRoutes.Profile,
        StartupRoutes.WifiRequiresProfileMatch,
        22);
    private readonly MirrorInputRecoveryPolicy _inputRecoveryPolicy = new();
    private readonly MirrorDiagnostics _diagnostics = new();
    private readonly WriteableBitmap _displayBitmap = new(
        SshFrameSource.FrameWidth,
        SshFrameSource.FrameHeight);
    private readonly byte[] _latestFrame = new byte[SshFrameSource.FrameBytes];
    private readonly Stream _displayPixelStream;
    private readonly DispatcherQueueTimer _toastTimer;
    private readonly SemaphoreSlim _frameRetrySignal = new(0, 1);
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _routeLifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _inputLifecycleGate = new(1, 1);
    private readonly object _routeAdmissionGate = new();
    private TaskCompletionSource<bool> _displayPreparation = CreatePreparation();
    private TaskCompletionSource<bool> _inputPreparation = CreatePreparation();
    private CancellationTokenSource? _connectionCancellation;
    private Task? _connectionMonitorTask;
    private Task? _frameDisplayTask;
    private Task? _inputSessionTask;
    private volatile DeviceConnectionStatus _deviceConnectionStatus = DeviceConnectionStatus.Disconnected;
    private int _disconnectedProbeStreak;
    private volatile bool _tabletReachable;
    private volatile SshInputSession? _inputSession;
    private MirrorRouteGeneration? _routeGeneration;
    private long _nextRouteGeneration;
    private long _inputSessionGeneration;
    private long _usbPromotionCandidateGeneration;
    private bool _usbPromotionCandidateHasFrame;
    private bool _usbPromotionCandidateHasInput;
    private bool _haveFrame;
    private volatile MirrorConnectionState _mirrorState = MirrorConnectionState.Waiting;
    private string _connectionDetail = string.Empty;
    private FrameStreamFailureKind? _lastFrameFailure;
    private volatile bool _actionRequiredFailure;
    private bool _inputAvailable;
    private volatile bool _pageIsLoaded;
    private RemoteInputMode _inputMode = RemoteInputMode.Touch;
    private uint? _activePointerId;
    private int _activePointerOperation;
    private bool _activePenEraser;
    private long _lastPointerMoveTimestamp;
    private long _lastInputActivityTimestamp = Stopwatch.GetTimestamp();
    private long _lastInputHeartbeatTimestamp = Stopwatch.GetTimestamp();
    private volatile bool _inputRetryLatched;
    private volatile bool _inputRestoreUncertain;
    private int _inputRetryAttempt;
    private readonly Stack<(string? Id, string Name)> _folderHistory = new();
    private string? _currentFolderId;
    private string _currentFolderName = "My files";
    private int _libraryRefreshGeneration;
    private readonly SemaphoreSlim _exportGate = new(1, 1);
    private int _activeFilesOperations;
    private long _filesReadyGeneration;
    private long _filesProbeGeneration;
    private CompositionRoundedRectangleGeometry? _stageClipGeometry;
    private CompositionRoundedRectangleGeometry? _stageOutlineGeometry;
    private ShapeVisual? _stageOutlineVisual;
    private TaskCompletionSource? _filesPaneTransitionCompletion;
    private double _filesPaneProgress;
    private bool _filesPaneRenderingSubscribed;
    private bool _filesPaneOpen;
    private bool _filesPaneDesiredOpen;
    private bool _filesPaneTransitioning;
    private bool _filesPaneDisposed;
    private bool _filesPaneInitialized;
    private double _filesPaneLinearProgress;
    private int _filesPaneDirection;
    private long _filesPaneLastFrameTimestamp;
    private double _compactStageWidth;
    private double _compactWorkspaceWidth;

    public ObservableCollection<TransferItem> Transfers { get; } = [];
    public ObservableCollection<RemarkableLibraryItem> LibraryItems { get; } = [];
    private readonly FilesPaneState _filesPaneState;

    public MainPage()
    {
        InitializeComponent();
        _filesPaneState = new FilesPaneState(LibraryItems, Transfers);
        ConfigureFilesPaneView(MainFilesPane);
        _displayPixelStream = _displayBitmap.PixelBuffer.AsStream();
        LiveFrameImage.Source = _displayBitmap;
        DeviceScreen.PointerPressed += DeviceScreen_PointerPressed;
        DeviceScreen.PointerMoved += DeviceScreen_PointerMoved;
        DeviceScreen.PointerReleased += DeviceScreen_PointerReleased;
        DeviceScreen.PointerCanceled += DeviceScreen_PointerCanceled;
        DeviceScreen.PointerCaptureLost += DeviceScreen_PointerCaptureLost;
        KeyDown += MainPage_KeyDown;
        KeyUp += MainPage_KeyUp;
        _toastTimer = DispatcherQueue.CreateTimer();
        _toastTimer.IsRepeating = false;
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            ActionToast.Visibility = Visibility.Collapsed;
        };
        SetMirrorState(MirrorConnectionState.Waiting);
        SetInputAvailability(false);
    }

    private void ConfigureFilesPaneView(FilesPaneView view)
    {
        view.State = _filesPaneState;
        view.IsTransitionCopy = false;
        view.SurfaceBorderThickness = new Thickness(0);
        view.SurfaceCornerRadius = new CornerRadius(0);
        view.CloseRequested += FilesPane_CloseRequested;
        view.BackRequested += FilesPane_BackRequested;
        view.RefreshRequested += FilesPane_RefreshRequested;
        view.LibraryItemInvoked += FilesPane_LibraryItemInvoked;
        view.SavePdfRequested += FilesPane_SavePdfRequested;
        view.SaveNativeRequested += FilesPane_SaveNativeRequested;
        view.FilesDropped += FilesPane_FilesDropped;
        view.BeginDocumentDrag = BeginLibraryDocumentDrag;
    }

    private static StartupRouteConfiguration ResolveStartupRoutes()
    {
        const string usbHost = "10.11.99.1";
        const string filesLoopbackHost = "127.0.0.1";
        var usbRoute = new SshRoute(usbHost, filesTargetHost: filesLoopbackHost);

        DeviceProfileLoadResult loadResult;
        try
        {
            loadResult = new DeviceProfileStore().Load();
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return new StartupRouteConfiguration(
                usbRoute,
                null,
                null,
                DeviceProfileLoadStatus.Unavailable,
                WifiRequiresProfileMatch: false);
        }

        var profile = loadResult.Status is DeviceProfileLoadStatus.Ready
            ? loadResult.Profile
            : null;
        if (profile is null ||
            !string.Equals(
                profile.SshHostKeyAlias,
                SshRoute.TabletHostKeyAlias,
                StringComparison.Ordinal) ||
            !string.Equals(
                profile.LastVerified.WakeCapabilitySchema,
                "rmmirror.wake/v1",
                StringComparison.Ordinal))
        {
            return new StartupRouteConfiguration(
                usbRoute,
                null,
                null,
                loadResult.Status,
                WifiRequiresProfileMatch: false);
        }

        try
        {
            var wifiRoute = new SshRoute(
                profile.LastVerifiedWifiHost,
                filesTargetHost: filesLoopbackHost,
                filesTargetPort: profile.FilesTarget.Port);
            return new StartupRouteConfiguration(
                usbRoute,
                wifiRoute,
                profile,
                loadResult.Status,
                WifiRequiresProfileMatch: true);
        }
        catch (ArgumentException)
        {
            return new StartupRouteConfiguration(
                usbRoute,
                null,
                null,
                DeviceProfileLoadStatus.Corrupt,
                WifiRequiresProfileMatch: false);
        }
    }

    private static TaskCompletionSource<bool> CreatePreparation() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private void ResetDisplayPreparation()
    {
        var previous = Interlocked.Exchange(ref _displayPreparation, CreatePreparation());
        previous.TrySetResult(false);
    }

    private static void CompleteDisplayPreparation(TaskCompletionSource<bool> preparation) =>
        preparation.TrySetResult(true);

    private void ResetInputPreparation()
    {
        var previous = Interlocked.Exchange(ref _inputPreparation, CreatePreparation());
        previous.TrySetResult(false);
    }

    private static void CompleteInputPreparation(TaskCompletionSource<bool> preparation) =>
        preparation.TrySetResult(true);

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        _pageIsLoaded = true;
        _filesPaneDisposed = false;
        _ = Task.Run(CleanupStaleDocumentDragExports);
        InitializeFilesPaneLayout();
        await _lifecycleGate.WaitAsync();
        try
        {
            if (!_pageIsLoaded || _connectionCancellation is not null)
            {
                return;
            }

            DrainFrameRetrySignal();
            ResetDisplayPreparation();
            ResetInputPreparation();
            _connectionMonitor.SetActiveRouteKind(null);
            _deviceConnectionStatus = DeviceConnectionStatus.Disconnected;
            _disconnectedProbeStreak = 0;
            _tabletReachable = false;
            _actionRequiredFailure = false;
            _lastFrameFailure = null;
            _haveFrame = false;
            _inputRecoveryPolicy.Reset();
            ResetInputRetryPolicy();
            SetMirrorState(MirrorConnectionState.Waiting);

            var cancellation = new CancellationTokenSource();
            _connectionCancellation = cancellation;
            _diagnostics.Record("lifecycle", "Mirror window opened");
            _diagnostics.Record(
                "wifi profile",
                StartupRoutes.WifiRoute is null
                    ? $"Unavailable ({StartupRoutes.ProfileStatus})"
                    : "Ready");
            _connectionMonitorTask = MonitorConnectionAsync(cancellation.Token);
            _frameDisplayTask = DisplayFramesAsync(cancellation.Token);
            _inputSessionTask = MaintainInputSessionAsync(cancellation.Token);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        await ShutdownAsync();
    }

    internal async Task ShutdownAsync()
    {
        _pageIsLoaded = false;
        _toastTimer.Stop();
        DisposeFilesPaneAnimation();
        await _lifecycleGate.WaitAsync();
        try
        {
            var cancellation = _connectionCancellation;
            if (cancellation is null)
            {
                return;
            }

            var monitorTask = _connectionMonitorTask;
            var frameTask = _frameDisplayTask;
            var inputTask = _inputSessionTask;
            var generation = Interlocked.Exchange(ref _routeGeneration, null);
            _tabletReachable = false;
            _connectionMonitor.SetActiveRouteKind(null);
            generation?.Cancel();
            cancellation.Cancel();
            _connectionMonitor.RequestProbe();
            SignalFrameRetry();
            try
            {
                await AwaitWorkerShutdownAsync(monitorTask, frameTask, inputTask);
            }
            finally
            {
                try
                {
                    await CloseInputSessionAsync();
                }
                catch (Exception exception)
                {
                    _diagnostics.Record("shutdown", $"Input cleanup: {exception.GetType().Name}");
                }

                var lateGeneration = Interlocked.Exchange(ref _routeGeneration, null);
                if (generation is not null)
                {
                    try
                    {
                        await generation.DisposeAsync();
                    }
                    catch (Exception exception)
                    {
                        _diagnostics.Record("shutdown", $"Route cleanup: {exception.GetType().Name}");
                    }
                }
                if (lateGeneration is not null && !ReferenceEquals(lateGeneration, generation))
                {
                    lateGeneration.Cancel();
                    try
                    {
                        await lateGeneration.DisposeAsync();
                    }
                    catch (Exception exception)
                    {
                        _diagnostics.Record("shutdown", $"Late route cleanup: {exception.GetType().Name}");
                    }
                }

                cancellation.Dispose();
                _connectionCancellation = null;
                _connectionMonitorTask = null;
                _frameDisplayTask = null;
                _inputSessionTask = null;
                _diagnostics.Record("lifecycle", "Mirror window closed");
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private bool IsCurrentGeneration(MirrorRouteGeneration generation) =>
        ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) &&
        !generation.CancellationToken.IsCancellationRequested;

    private async Task<RouteTransitionResult> TransitionRouteAsync(
        SshRoute? nextRoute,
        DeviceRouteKind? nextKind,
        CancellationToken applicationCancellationToken)
    {
        await _routeLifecycleGate.WaitAsync(applicationCancellationToken).ConfigureAwait(false);
        try
        {
            MirrorRouteGeneration? current;
            var beginsUsbPromotion = false;
            lock (_routeAdmissionGate)
            {
                current = Volatile.Read(ref _routeGeneration);
                if (current is not null &&
                    nextRoute is not null &&
                    nextKind == current.Kind &&
                    ReferenceEquals(nextRoute, current.Route) &&
                    !current.CancellationToken.IsCancellationRequested)
                {
                    _tabletReachable = true;
                    return RouteTransitionResult.Unchanged;
                }
                if (current is null && nextRoute is null)
                {
                    _tabletReachable = false;
                    return RouteTransitionResult.Unchanged;
                }

                // USB preference is deliberately idle-only. Admission and the
                // break step share this lock, so no pointer/files operation can
                // enter after the check but before the Wi-Fi generation closes.
                if (current?.Kind is DeviceRouteKind.Wifi &&
                    nextKind is DeviceRouteKind.Usb &&
                    (_activePointerOperation != 0 || _activeFilesOperations != 0))
                {
                    return RouteTransitionResult.Deferred;
                }

                _tabletReachable = false;
                _inputRetryLatched = true;
                beginsUsbPromotion = current?.Kind is DeviceRouteKind.Wifi &&
                    nextKind is DeviceRouteKind.Usb;
                current = Interlocked.Exchange(ref _routeGeneration, null);
                if (current is not null)
                {
                    _inputRecoveryPolicy.AbandonGeneration(current.Id);
                }
                _filesReadyGeneration = 0;
                if (current?.Id == _usbPromotionCandidateGeneration)
                {
                    _usbPromotionCandidateGeneration = 0;
                    _usbPromotionCandidateHasFrame = false;
                    _usbPromotionCandidateHasInput = false;
                }
                _connectionMonitor.SetActiveRouteKind(null);
                current?.Cancel();
            }
            Interlocked.Increment(ref _libraryRefreshGeneration);
            SignalFrameRetry();

            var inputRemoval = InputSessionRemovalResult.NotRemoved(
                restoreConfirmed: !_inputRestoreUncertain);
            await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
            try
            {
                _activePointerId = null;
                lock (_routeAdmissionGate)
                {
                    _activePointerOperation = 0;
                }
                inputRemoval = await RemoveInputSessionUnderGateAsync(
                    expected: null,
                    requireExpected: false,
                    latchForRetry: false).ConfigureAwait(false);
                _inputSessionGeneration = 0;
                ResetDisplayPreparation();
                ResetInputPreparation();
                if (inputRemoval.RestoreConfirmed)
                {
                    ResetInputRetryPolicy();
                }
            }
            finally
            {
                _inputLifecycleGate.Release();
            }

            var currentDisposed = false;
            try
            {
                if (current is not null)
                {
                    await DisposeRouteGenerationAsync(current).ConfigureAwait(false);
                    currentDisposed = true;
                }

                if (!applicationCancellationToken.IsCancellationRequested)
                {
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            DeviceScreen.ReleasePointerCaptures();
                            foreach (var transfer in Transfers.Where(
                                         item => string.Equals(
                                             item.State,
                                             "Sending…",
                                             StringComparison.Ordinal)))
                            {
                                transfer.State = "Canceled";
                            }
                            UpdateTransferCount();
                        },
                        applicationCancellationToken).ConfigureAwait(false);
                }

                applicationCancellationToken.ThrowIfCancellationRequested();
                if (nextRoute is null || nextKind is null)
                {
                    return RouteTransitionResult.Changed;
                }

                var next = new MirrorRouteGeneration(
                    Interlocked.Increment(ref _nextRouteGeneration),
                    nextKind.Value,
                    nextRoute,
                    applicationCancellationToken);
                _inputRecoveryPolicy.BeginGeneration(next.Id);
                lock (_routeAdmissionGate)
                {
                    Volatile.Write(ref _routeGeneration, next);
                    _connectionMonitor.SetActiveRouteKind(next.Kind);
                    _tabletReachable = true;
                }
                if (beginsUsbPromotion)
                {
                    BeginUsbPromotionCandidate(next);
                }
                if (next.Kind is DeviceRouteKind.Usb)
                {
                    _ = ProbeFilesRouteAsync(next);
                }
                _haveFrame = false;
                _diagnostics.Record(
                    "route",
                    next.Kind is DeviceRouteKind.Usb ? "USB selected" : "Wi-Fi selected");
                SignalFrameRetry();
                return RouteTransitionResult.Changed;
            }
            finally
            {
                if (!currentDisposed && current is not null)
                {
                    await DisposeRouteGenerationAsync(current).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            _routeLifecycleGate.Release();
        }
    }

    private async Task DisposeRouteGenerationAsync(MirrorRouteGeneration generation)
    {
        try
        {
            await generation.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is
            FileTransferException or ObjectDisposedException)
        {
            _diagnostics.Record("route cleanup", exception.GetType().Name);
        }
    }

    private void BeginUsbPromotionCandidate(MirrorRouteGeneration generation)
    {
        lock (_routeAdmissionGate)
        {
            if (!ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) ||
                generation.Kind is not DeviceRouteKind.Usb)
            {
                return;
            }
            _usbPromotionCandidateGeneration = generation.Id;
            _usbPromotionCandidateHasFrame = false;
            _usbPromotionCandidateHasInput = false;
        }
        _ = MonitorUsbPromotionCandidateAsync(generation);
    }

    private async Task MonitorUsbPromotionCandidateAsync(MirrorRouteGeneration generation)
    {
        try
        {
            await Task.Delay(UsbPromotionReadyTimeout, generation.CancellationToken)
                .ConfigureAwait(false);
            FailUsbPromotionCandidate(generation, "readiness timeout");
        }
        catch (OperationCanceledException) when (generation.CancellationToken.IsCancellationRequested)
        {
        }
    }

    private void MarkUsbPromotionFrameReady(MirrorRouteGeneration generation) =>
        MarkUsbPromotionReady(generation, frameReady: true);

    private void MarkUsbPromotionInputReady(MirrorRouteGeneration generation) =>
        MarkUsbPromotionReady(generation, frameReady: false);

    private void MarkUsbPromotionReady(
        MirrorRouteGeneration generation,
        bool frameReady)
    {
        var confirmed = false;
        lock (_routeAdmissionGate)
        {
            if (_usbPromotionCandidateGeneration != generation.Id ||
                !ReferenceEquals(Volatile.Read(ref _routeGeneration), generation))
            {
                return;
            }
            if (frameReady)
            {
                _usbPromotionCandidateHasFrame = true;
            }
            else
            {
                _usbPromotionCandidateHasInput = true;
            }
            if (_usbPromotionCandidateHasFrame && _usbPromotionCandidateHasInput)
            {
                _usbPromotionCandidateGeneration = 0;
                _usbPromotionCandidateHasFrame = false;
                _usbPromotionCandidateHasInput = false;
                confirmed = true;
            }
        }
        if (confirmed)
        {
            _connectionMonitor.ConfirmUsbPromotionSucceeded();
            _diagnostics.Record("route", "USB promotion confirmed");
        }
    }

    private void FailUsbPromotionCandidate(
        MirrorRouteGeneration generation,
        string safeReason)
    {
        var failed = false;
        lock (_routeAdmissionGate)
        {
            if (_usbPromotionCandidateGeneration == generation.Id &&
                ReferenceEquals(Volatile.Read(ref _routeGeneration), generation))
            {
                _usbPromotionCandidateGeneration = 0;
                _usbPromotionCandidateHasFrame = false;
                _usbPromotionCandidateHasInput = false;
                failed = true;
            }
        }
        if (failed)
        {
            _diagnostics.Record("route", $"USB promotion failed: {safeReason}");
            _connectionMonitor.ReportUsbPromotionFailed();
        }
    }

    private async Task MonitorConnectionAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var state in _connectionMonitor.WatchAsync(cancellationToken))
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                var hadActiveGeneration = Volatile.Read(ref _routeGeneration) is not null;
                if (!hadActiveGeneration &&
                    state.Status is DeviceConnectionStatus.Disconnected &&
                    _deviceConnectionStatus is DeviceConnectionStatus.PortOpenWithoutSshBanner or
                        DeviceConnectionStatus.UnlockRequired or
                        DeviceConnectionStatus.Sleeping or
                        DeviceConnectionStatus.Waking or
                        DeviceConnectionStatus.Starting or
                        DeviceConnectionStatus.WakeSetupRequired)
                {
                    _disconnectedProbeStreak++;
                    if (_disconnectedProbeStreak < 3)
                    {
                        continue;
                    }
                }
                else if (state.Status is not DeviceConnectionStatus.Disconnected)
                {
                    _disconnectedProbeStreak = 0;
                }

                var previousStatus = _deviceConnectionStatus;
                var routeChanged = false;
                if (state.IsSshReady &&
                    state.SelectedRoute is not null &&
                    state.RouteKind is not null)
                {
                    var transition = await TransitionRouteAsync(
                            state.SelectedRoute,
                            state.RouteKind,
                            cancellationToken)
                        .ConfigureAwait(false);
                    if (transition is RouteTransitionResult.Deferred)
                    {
                        continue;
                    }
                    routeChanged = transition is RouteTransitionResult.Changed;
                }
                else if (hadActiveGeneration)
                {
                    routeChanged = await TransitionRouteAsync(
                            null,
                            null,
                            cancellationToken)
                        .ConfigureAwait(false) is RouteTransitionResult.Changed;
                }

                _deviceConnectionStatus = state.Status;
                if (previousStatus != state.Status)
                {
                    _diagnostics.Record("connection", state.Status.ToString());
                }

                if (_actionRequiredFailure && _mirrorState is MirrorConnectionState.Error)
                {
                    if (state.Status is not DeviceConnectionStatus.UnlockRequired and
                        not DeviceConnectionStatus.WakeSetupRequired)
                    {
                        continue;
                    }
                    _actionRequiredFailure = false;
                }

                await RunOnUIThreadAsync(
                    () =>
                    {
                        if (_inputRestoreUncertain)
                        {
                            SetMirrorState(
                                MirrorConnectionState.Error,
                                "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again.");
                            SignalFrameRetry();
                            return;
                        }
                        switch (state.Status)
                        {
                            case DeviceConnectionStatus.Disconnected:
                                SetMirrorState(MirrorConnectionState.Waiting);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.PortOpenWithoutSshBanner:
                                SetMirrorState(MirrorConnectionState.WakeAndUnlock);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.UnlockRequired:
                                SetMirrorState(MirrorConnectionState.AwaitingUnlock);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.Sleeping:
                                SetMirrorState(MirrorConnectionState.Sleeping);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.Waking:
                                SetMirrorState(MirrorConnectionState.Waking);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.Starting:
                                SetMirrorState(MirrorConnectionState.Starting);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.WakeSetupRequired:
                                SetMirrorState(MirrorConnectionState.WakeSetupRequired);
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.WifiNetworkMismatch:
                                SetMirrorState(
                                    MirrorConnectionState.Error,
                                    "Connect this PC to the Wi-Fi network paired with this reMarkable, or connect the tablet by USB-C to repair Wi-Fi pairing, then choose Retry.");
                                SignalFrameRetry();
                                break;
                            case DeviceConnectionStatus.SshReady:
                                if (routeChanged ||
                                    previousStatus is not DeviceConnectionStatus.SshReady ||
                                    _mirrorState is MirrorConnectionState.Waiting or
                                        MirrorConnectionState.WakeAndUnlock or
                                        MirrorConnectionState.AwaitingUnlock or
                                        MirrorConnectionState.Sleeping or
                                        MirrorConnectionState.Waking or
                                        MirrorConnectionState.Starting or
                                        MirrorConnectionState.WakeSetupRequired or
                                        MirrorConnectionState.Preparing)
                                {
                                    SetMirrorState(MirrorConnectionState.Preparing);
                                }
                                if (routeChanged ||
                                    previousStatus is not DeviceConnectionStatus.SshReady)
                                {
                                    SignalFrameRetry();
                                }
                                break;
                        }
                    },
                    cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task DisplayFramesAsync(CancellationToken cancellationToken)
    {
        var retryAttempt = 0;
        await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);

        while (!cancellationToken.IsCancellationRequested)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            if (!_tabletReachable || generation is null)
            {
                retryAttempt = 0;
                await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }
            var routeToken = generation.CancellationToken;
            try
            {

            var displayPreparation = Volatile.Read(ref _displayPreparation);
            if (!displayPreparation.Task.IsCompleted)
            {
                try
                {
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (IsCurrentGeneration(generation))
                            {
                                SetMirrorState(
                                    MirrorConnectionState.Preparing,
                                    "Starting the tablet display for this connection.");
                            }
                        },
                        routeToken).ConfigureAwait(false);
                    var result = await generation.FrameSource
                        .EnsureDisplayReadyAsync(
                            allowStart: _inputSession is null,
                            routeToken)
                        .ConfigureAwait(false);
                    if (!IsCurrentGeneration(generation))
                    {
                        continue;
                    }
                    _diagnostics.Record(
                        "mirror preparation",
                        result.StartedXovi
                            ? "Tablet display service started for this connection"
                            : "Tablet display service already ready");
                    CompleteDisplayPreparation(displayPreparation);
                }
                catch (FrameStreamException exception)
                {
                    if (!IsCurrentGeneration(generation) ||
                        !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)))
                    {
                        continue;
                    }
                    retryAttempt = await HandleFrameFailureAsync(
                            exception,
                            retryAttempt,
                            generation,
                            routeToken)
                        .ConfigureAwait(false);
                    continue;
                }
                catch (OperationCanceledException) when (
                    routeToken.IsCancellationRequested &&
                    !cancellationToken.IsCancellationRequested)
                {
                    continue;
                }
            }

            if (!await displayPreparation.Task.WaitAsync(routeToken).ConfigureAwait(false))
            {
                continue;
            }
            if (!IsCurrentGeneration(generation) ||
                !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)))
            {
                continue;
            }

            // Input preparation deliberately restarts Xochitl once so it can select the
            // session-owned virtual devices. Do not open the framebuffer stream until
            // that handoff finishes; the preparation is completed even when input fails,
            // so a screen-only connection still proceeds.
            var inputPreparation = Volatile.Read(ref _inputPreparation);
            if (!await inputPreparation.Task.WaitAsync(routeToken).ConfigureAwait(false))
            {
                continue;
            }
            if (!IsCurrentGeneration(generation) ||
                !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) ||
                !ReferenceEquals(inputPreparation, Volatile.Read(ref _inputPreparation)))
            {
                continue;
            }

            try
            {
                await RunOnUIThreadAsync(
                    () =>
                    {
                        if (IsCurrentGeneration(generation))
                        {
                            SetMirrorState(
                                MirrorConnectionState.Preparing,
                                "Finishing the tablet display after control setup.");
                        }
                    },
                    routeToken).ConfigureAwait(false);
                await generation.FrameSource
                    .EnsureDisplayReadyAsync(allowStart: false, routeToken)
                    .ConfigureAwait(false);
                if (!IsCurrentGeneration(generation))
                {
                    continue;
                }
                _diagnostics.Record(
                    "mirror preparation",
                    "Tablet display revalidated after control setup");
            }
            catch (FrameStreamException exception)
            {
                if (!IsCurrentGeneration(generation) ||
                    !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) ||
                    !ReferenceEquals(inputPreparation, Volatile.Read(ref _inputPreparation)))
                {
                    continue;
                }
                var preparationRecoveryStarted = await BeginDisplayRecoveryAsync(
                    displayPreparation,
                    inputPreparation,
                    generation,
                    allowScreenOnlyFallback:
                        exception.Kind is FrameStreamFailureKind.CompanionNotReady).ConfigureAwait(false);
                if (exception.Kind is FrameStreamFailureKind.CompanionNotReady &&
                    !preparationRecoveryStarted)
                {
                    continue;
                }
                retryAttempt = await HandleFrameFailureAsync(
                        exception,
                        retryAttempt,
                        generation,
                        routeToken)
                    .ConfigureAwait(false);
                continue;
            }
            catch (OperationCanceledException) when (
                routeToken.IsCancellationRequested &&
                !cancellationToken.IsCancellationRequested)
            {
                continue;
            }

            FrameStreamException? failure = null;
            using var attemptCancellation = CancellationTokenSource.CreateLinkedTokenSource(routeToken);
            attemptCancellation.CancelAfter(TimeSpan.FromSeconds(10));
            var receivedFirstFrame = false;
            try
            {
                await foreach (var update in generation.FrameSource
                                   .WatchUpdatesAsync(attemptCancellation.Token)
                                   .ConfigureAwait(false))
                {
                    if (!IsCurrentGeneration(generation) ||
                        cancellationToken.IsCancellationRequested ||
                        !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) ||
                        !ReferenceEquals(inputPreparation, Volatile.Read(ref _inputPreparation)))
                    {
                        break;
                    }

                    if (!receivedFirstFrame)
                    {
                        receivedFirstFrame = true;
                        attemptCancellation.CancelAfter(Timeout.InfiniteTimeSpan);
                        DrainFrameRetrySignal();
                        MarkUsbPromotionFrameReady(generation);
                    }
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (!IsCurrentGeneration(generation))
                            {
                                return;
                            }
                            ApplyFrameUpdate(update);
                            _actionRequiredFailure = false;
                            _lastFrameFailure = null;
                            SetLiveState(generation);
                            retryAttempt = 0;
                        },
                        routeToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException) when (routeToken.IsCancellationRequested)
            {
                continue;
            }
            catch (OperationCanceledException) when (attemptCancellation.IsCancellationRequested)
            {
                failure = new FrameStreamException(
                    FrameStreamFailureKind.CompanionNotReady,
                    "The secure connection opened, but the tablet display did not start. Mirror will reconnect automatically.",
                    canAutoRetry: true);
            }
            catch (FrameStreamException exception)
            {
                failure = exception;
            }

            if (failure is null)
            {
                if (!IsCurrentGeneration(generation))
                {
                    retryAttempt = 0;
                    await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken)
                        .ConfigureAwait(false);
                    continue;
                }

                failure = new FrameStreamException(
                    FrameStreamFailureKind.StreamInterrupted,
                    "The tablet display connection stopped. Mirror will reconnect automatically.",
                    canAutoRetry: true);
            }

            if (!IsCurrentGeneration(generation) ||
                !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) ||
                !ReferenceEquals(inputPreparation, Volatile.Read(ref _inputPreparation)))
            {
                continue;
            }

            var streamRecoveryStarted = await BeginDisplayRecoveryAsync(
                displayPreparation,
                inputPreparation,
                generation,
                allowScreenOnlyFallback:
                    failure.Kind is FrameStreamFailureKind.CompanionNotReady).ConfigureAwait(false);
            if (failure.Kind is FrameStreamFailureKind.CompanionNotReady &&
                !streamRecoveryStarted)
            {
                continue;
            }

            retryAttempt = await HandleFrameFailureAsync(
                    failure,
                    retryAttempt,
                    generation,
                    routeToken)
                .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (
                routeToken.IsCancellationRequested &&
                !cancellationToken.IsCancellationRequested)
            {
                retryAttempt = 0;
            }
        }
    }

    private async Task<bool> BeginDisplayRecoveryAsync(
        TaskCompletionSource<bool> expectedDisplayPreparation,
        TaskCompletionSource<bool> expectedInputPreparation,
        MirrorRouteGeneration generation,
        bool allowScreenOnlyFallback)
    {
        await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!IsCurrentGeneration(generation) ||
                !ReferenceEquals(expectedDisplayPreparation, Volatile.Read(ref _displayPreparation)) ||
                !ReferenceEquals(expectedInputPreparation, Volatile.Read(ref _inputPreparation)))
            {
                return false;
            }

            var session = _inputSession;
            var interruptionTimestamp = Stopwatch.GetTimestamp();
            _inputRecoveryPolicy.RecordFrameInterruption(
                generation.Id,
                interruptionTimestamp);
            var automaticInputRecovery = _inputRecoveryPolicy.TryConsumeScheduled(
                generation.Id,
                interruptionTimestamp,
                CoupledInputRecoveryWindow);

            // The frame worker can observe the Xochitl restart before the input
            // heartbeat observes the dead SSH process. Classify that stopped,
            // previously published session here so either observer can reserve
            // the same one-shot recovery budget.
            if (!automaticInputRecovery &&
                session is not null &&
                Interlocked.Read(ref _inputSessionGeneration) == generation.Id &&
                _haveFrame &&
                !_inputRestoreUncertain)
            {
                var stopped = await session
                    .InspectStoppedAsync(
                        InputStopObservationWindow,
                        generation.CancellationToken)
                    .ConfigureAwait(false);
                if (stopped is { IsPersistent: false } &&
                    IsCurrentGeneration(generation) &&
                    ReferenceEquals(session, _inputSession) &&
                    ReferenceEquals(expectedDisplayPreparation, Volatile.Read(ref _displayPreparation)) &&
                    ReferenceEquals(expectedInputPreparation, Volatile.Read(ref _inputPreparation)))
                {
                    automaticInputRecovery =
                        _inputRecoveryPolicy.TryReserveStoppedSessionRecovery(generation.Id);
                    if (automaticInputRecovery)
                    {
                        _diagnostics.Record(
                            "input recovery",
                            "Reserved one automatic control handoff after the coupled display interruption");
                    }
                }
            }

            if (!automaticInputRecovery && !allowScreenOnlyFallback)
            {
                return false;
            }

            // An ordinary display failure remains screen-only. Input owns a
            // deliberate Xochitl restart, so never clear its latch unless this
            // exact coupled recovery consumed the generation's one-shot budget.
            if (session is not null && !automaticInputRecovery && !_inputRetryLatched)
            {
                _inputRecoveryPolicy.RecordPublishedSessionLoss(
                    generation.Id,
                    Stopwatch.GetTimestamp(),
                    CoupledInputRecoveryWindow,
                    allowAutomaticRecovery: false);
                RegisterInputFailure();
            }
            var removal = await RemoveInputSessionUnderGateAsync(
                expected: null,
                requireExpected: false,
                latchForRetry: false).ConfigureAwait(false);
            if (automaticInputRecovery)
            {
                if (removal.RestoreConfirmed && (session is null || removal.Removed))
                {
                    RearmCoupledInputRecoveryUnderGate(generation);
                    _diagnostics.Record(
                        "input recovery",
                        "Rearmed one control handoff behind the fresh display preparation barrier");
                    return true;
                }
                else
                {
                    _inputRecoveryPolicy.AbandonGeneration(generation.Id);
                }
            }
            ResetDisplayPreparation();
            if (session is not null)
            {
                SetControlRecoveryStateFromAnyThread(MirrorInputRecoveryDisposition.None);
            }
            return true;
        }
        finally
        {
            _inputLifecycleGate.Release();
        }
    }

    private void RearmCoupledInputRecoveryUnderGate(MirrorRouteGeneration generation)
    {
        _activePointerId = null;
        _activePenEraser = false;
        lock (_routeAdmissionGate)
        {
            _activePointerOperation = 0;
        }
        ResetInputPreparation();
        ResetInputRetryPolicy();
        ResetDisplayPreparation();
        SetControlRecoveryStateFromAnyThread(MirrorInputRecoveryDisposition.BeginNow);
        SignalFrameRetry();
    }

    private async Task<int> HandleFrameFailureAsync(
        FrameStreamException failure,
        int retryAttempt,
        MirrorRouteGeneration generation,
        CancellationToken cancellationToken)
    {
        if (!IsCurrentGeneration(generation))
        {
            return 0;
        }
        var diagnostic = string.IsNullOrWhiteSpace(failure.TechnicalDetail)
            ? $"{failure.Kind}: {failure.Message}"
            : $"{failure.Kind}: {failure.TechnicalDetail}";
        _lastFrameFailure = failure.Kind;
        _diagnostics.Record("mirror failure", diagnostic);
        FailUsbPromotionCandidate(generation, "display setup failed");

        if (failure.Kind is FrameStreamFailureKind.SecureConnectionUnavailable)
        {
            _connectionMonitor.RequestProbe();
        }

        var nextAttempt = failure.CanAutoRetry ? retryAttempt + 1 : 0;
        var automaticRetryExhausted = nextAttempt >= AutomaticFrameRetryLimit;
        _actionRequiredFailure = !failure.CanAutoRetry || automaticRetryExhausted;
        var state = _actionRequiredFailure
            ? MirrorConnectionState.Error
            : MirrorConnectionState.Preparing;
        var message = automaticRetryExhausted
            ? "Mirror couldn’t keep the tablet display connected. Copy the connection details, then choose Retry."
            : failure.Message;
        await RunOnUIThreadAsync(
            () =>
            {
                if (IsCurrentGeneration(generation))
                {
                    SetMirrorState(state, message);
                }
            },
            cancellationToken).ConfigureAwait(false);

        if (_actionRequiredFailure)
        {
            await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken)
                .ConfigureAwait(false);
            return 0;
        }

        await WaitForFrameRetryAsync(RetryDelayFor(nextAttempt), cancellationToken)
            .ConfigureAwait(false);
        return nextAttempt;
    }

    private void ApplyFrameUpdate(FrameUpdate update)
    {
        var rowBytes = update.Width * 4;
        for (var row = 0; row < update.Height; row++)
        {
            var source = update.Payload.Slice(row * rowBytes, rowBytes);
            var destinationOffset = ((update.Y + row) * SshFrameSource.FrameWidth + update.X) * 4;
            source.CopyTo(_latestFrame.AsSpan(destinationOffset, rowBytes));
            _displayPixelStream.Position = destinationOffset;
            _displayPixelStream.Write(source);
        }

        _displayBitmap.Invalidate();
        _haveFrame = true;
    }

    private void SetMirrorState(MirrorConnectionState state, string? detail = null)
    {
        var previousState = _mirrorState;
        var previousDetail = _connectionDetail;
        var (connection, title, body, color, showProgress, showAction, actionText, showDetails) = state switch
        {
            MirrorConnectionState.Preparing => (
                "Connecting",
                "Preparing your reMarkable",
                detail ?? "Starting the tablet display and controls for this connection.",
                Windows.UI.Color.FromArgb(255, 226, 163, 58),
                true,
                false,
                string.Empty,
                false),
            MirrorConnectionState.Live => (
                "Live",
                string.Empty,
                string.Empty,
                Windows.UI.Color.FromArgb(255, 59, 186, 118),
                false,
                false,
                string.Empty,
                false),
            MirrorConnectionState.Error => (
                "Attention",
                "Couldn’t open mirror",
                detail ?? "Keep the tablet awake and connected, then choose Retry.",
                Windows.UI.Color.FromArgb(255, 224, 92, 92),
                false,
                true,
                "Retry",
                true),
            MirrorConnectionState.AwaitingUnlock => (
                "Unlock",
                "Unlock your reMarkable",
                "Wake it if needed, then enter your passcode on the tablet. Mirror will connect automatically.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                false,
                false,
                string.Empty,
                false),
            MirrorConnectionState.WakeAndUnlock => (
                "Waiting",
                "Wake and unlock your reMarkable",
                "Press the power button once and enter your passcode. Mirror will connect automatically.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                false,
                false,
                string.Empty,
                false),
            MirrorConnectionState.Sleeping => (
                "Sleeping",
                "Waking the display",
                "The tablet is still reachable. Mirror will wake its display and connect automatically.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                false,
                false,
                string.Empty,
                false),
            MirrorConnectionState.Waking => (
                "Waking",
                "Waking the display",
                "The tablet is still reachable. Mirror will connect automatically.",
                Windows.UI.Color.FromArgb(255, 226, 163, 58),
                true,
                false,
                string.Empty,
                false),
            MirrorConnectionState.Starting => (
                "Starting",
                "Your reMarkable is finishing startup",
                "Mirror will connect automatically.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                true,
                false,
                string.Empty,
                false),
            MirrorConnectionState.WakeSetupRequired => (
                "Repair",
                "Repair tablet wake setup",
                "Mirror cannot use its tablet wake setup. Re-run Install.cmd with the tablet connected and past its first post-boot unlock, then choose Retry.",
                Windows.UI.Color.FromArgb(255, 224, 92, 92),
                false,
                true,
                "Retry",
                true),
            _ => (
                "Offline",
                "Connect or wake your reMarkable",
                "Press the power button once. Mirror reconnects over Wi-Fi when the tablet wakes. If Wi-Fi does not return, connect USB-C.",
                Windows.UI.Color.FromArgb(255, 137, 145, 158),
                false,
                false,
                string.Empty,
                false),
        };

        if (previousState == state && string.Equals(previousDetail, body, StringComparison.Ordinal))
        {
            LiveFrameImage.Visibility = _haveFrame ? Visibility.Visible : Visibility.Collapsed;
            return;
        }

        _mirrorState = state;
        _connectionDetail = body;
        if (previousState != state || !string.Equals(previousDetail, body, StringComparison.Ordinal))
        {
            _diagnostics.Record("ui state", $"{state}: {body}");
        }
        ConnectionText.Text = connection;
        ConnectionDot.Fill = new SolidColorBrush(color);
        ConnectionPanelTitle.Text = title;
        ConnectionPanelDetail.Text = body;
        ConnectionProgressRing.IsActive = showProgress;
        ConnectionProgressRing.Visibility = showProgress ? Visibility.Visible : Visibility.Collapsed;
        ConnectionActionButton.Content = actionText;
        ConnectionActionButton.Visibility = showAction ? Visibility.Visible : Visibility.Collapsed;
        CopyConnectionDetailsButton.Visibility = showDetails ? Visibility.Visible : Visibility.Collapsed;
        ConnectionPanel.Visibility = state is MirrorConnectionState.Live
            ? Visibility.Collapsed
            : Visibility.Visible;
        LiveFrameImage.Visibility = _haveFrame ? Visibility.Visible : Visibility.Collapsed;
        SetFileAvailability(IsFilesRouteReady());
        if (state is MirrorConnectionState.Live &&
            previousState is not MirrorConnectionState.Live &&
            !_filesPaneTransitioning &&
            _filesPaneOpen)
        {
            _ = RefreshLibraryAsync();
        }
    }

    private void SetLiveState(MirrorRouteGeneration generation)
    {
        if (_inputRestoreUncertain)
        {
            SetMirrorState(
                MirrorConnectionState.Error,
                "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again.");
            return;
        }
        if (_inputRecoveryPolicy.RequiresInputPublication(generation.Id))
        {
            var session = _inputSession;
            if (session is null ||
                Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
                !session.IsRunning)
            {
                _actionRequiredFailure = true;
                SetMirrorState(
                    MirrorConnectionState.Error,
                    "The tablet display reconnected, but controls did not. Choose Retry to restore them.");
                return;
            }
            _inputRecoveryPolicy.MarkRecoveryComplete(generation.Id);
        }
        SetMirrorState(MirrorConnectionState.Live);
        ConnectionText.Text = generation.Kind is DeviceRouteKind.Usb
            ? "Live over USB"
            : "Live over Wi-Fi";
    }

    private void SetFileAvailability(bool available)
    {
        _filesPaneState.SetAvailability(available, _folderHistory.Count > 0);
    }

    private bool IsFilesRouteReady()
    {
        lock (_routeAdmissionGate)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            return generation is not null &&
                !generation.CancellationToken.IsCancellationRequested &&
                _filesReadyGeneration == generation.Id;
        }
    }

    private async Task ProbeFilesRouteAsync(MirrorRouteGeneration generation)
    {
        lock (_routeAdmissionGate)
        {
            if (!ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) ||
                generation.CancellationToken.IsCancellationRequested ||
                _filesProbeGeneration == generation.Id)
            {
                return;
            }
            _filesProbeGeneration = generation.Id;
        }

        FileTransferFailure? recordedFailure = null;
        string? recordedUnexpectedFailure = null;
        var refreshOpenFilesAfterProbe = false;
        try
        {
            while (IsCurrentGeneration(generation))
            {
                try
                {
                    await generation.FileTransport.ListRootAsync(generation.CancellationToken)
                        .ConfigureAwait(false);
                    lock (_routeAdmissionGate)
                    {
                        if (!ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) ||
                            generation.CancellationToken.IsCancellationRequested)
                        {
                            return;
                        }
                        _filesReadyGeneration = generation.Id;
                    }
                    _diagnostics.Record("files route", "Stock Files API ready");
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (!IsCurrentGeneration(generation))
                            {
                                return;
                            }
                            SetFileAvailability(true);
                        },
                        generation.CancellationToken).ConfigureAwait(false);
                    refreshOpenFilesAfterProbe = true;
                    break;
                }
                catch (OperationCanceledException) when (
                    generation.CancellationToken.IsCancellationRequested)
                {
                    return;
                }
                catch (FileTransferException exception)
                {
                    recordedUnexpectedFailure = null;
                    if (recordedFailure != exception.Failure)
                    {
                        recordedFailure = exception.Failure;
                        _diagnostics.Record(
                            "files route",
                            $"Stock Files API unavailable: {exception.Failure}");
                    }
                    await DelayWithoutThrowAsync(
                            TimeSpan.FromSeconds(3),
                            generation.CancellationToken)
                        .ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    if (!IsCurrentGeneration(generation))
                    {
                        return;
                    }
                    recordedFailure = null;
                    var failureType = exception.GetType().Name;
                    if (!string.Equals(
                            recordedUnexpectedFailure,
                            failureType,
                            StringComparison.Ordinal))
                    {
                        recordedUnexpectedFailure = failureType;
                        _diagnostics.Record(
                            "files route",
                            $"Stock Files API probe failed unexpectedly: {failureType}");
                    }
                    await DelayWithoutThrowAsync(
                            TimeSpan.FromSeconds(3),
                            generation.CancellationToken)
                        .ConfigureAwait(false);
                }
            }
        }
        finally
        {
            lock (_routeAdmissionGate)
            {
                if (_filesProbeGeneration == generation.Id)
                {
                    _filesProbeGeneration = 0;
                }
            }
        }
        if (refreshOpenFilesAfterProbe)
        {
            DispatcherQueue.TryEnqueue(
                DispatcherQueuePriority.High,
                () =>
                {
                    if (IsCurrentGeneration(generation) && _filesPaneOpen)
                    {
                        _ = RefreshLibraryAsync();
                    }
                });
        }
    }

    private void MarkFilesRouteUnhealthy(MirrorRouteGeneration generation)
    {
        var restartProbe = false;
        lock (_routeAdmissionGate)
        {
            if (ReferenceEquals(Volatile.Read(ref _routeGeneration), generation))
            {
                _filesReadyGeneration = 0;
                restartProbe = _filesProbeGeneration != generation.Id;
            }
        }
        if (!restartProbe)
        {
            return;
        }

        DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.High,
            () => SetFileAvailability(false));
        _ = ProbeFilesRouteAsync(generation);
    }

    private async Task MaintainInputSessionAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            if (!_tabletReachable || generation is null)
            {
                await CloseInputSessionAsync().ConfigureAwait(false);
                await DelayWithoutThrowAsync(TimeSpan.FromMilliseconds(500), cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }
            var routeToken = generation.CancellationToken;

            if (_inputRetryLatched || _inputRestoreUncertain)
            {
                await CloseInputSessionAsync().ConfigureAwait(false);
                await DelayWithoutThrowAsync(TimeSpan.FromMilliseconds(500), cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }

            var session = _inputSession;
            if (session is not null &&
                Interlocked.Read(ref _inputSessionGeneration) != generation.Id)
            {
                await DropInputSessionAsync(session, latchForRetry: false).ConfigureAwait(false);
                continue;
            }
            var retryDelay = TimeSpan.FromSeconds(1);
            if (session is null)
            {
                var displayPreparation = Volatile.Read(ref _displayPreparation);
                try
                {
                    if (!await displayPreparation.Task.WaitAsync(routeToken).ConfigureAwait(false) ||
                        !IsCurrentGeneration(generation))
                    {
                        continue;
                    }
                }
                catch (OperationCanceledException) when (
                    routeToken.IsCancellationRequested &&
                    !cancellationToken.IsCancellationRequested)
                {
                    continue;
                }

                var preparation = Volatile.Read(ref _inputPreparation);
                SshInputSession? candidate = null;
                SshInputSession? publishedSession = null;
                string? currentFailureMessage = null;
                var attemptOwned = false;
                var rearmSetupFailure = false;
                var setupCleanupConfirmed = true;
                try
                {
                    await _inputLifecycleGate.WaitAsync(routeToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (
                    routeToken.IsCancellationRequested &&
                    !cancellationToken.IsCancellationRequested)
                {
                    continue;
                }
                try
                {
                    if (IsCurrentGeneration(generation) &&
                        !_inputRetryLatched &&
                        !_inputRestoreUncertain &&
                        _inputSession is null &&
                        ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) &&
                        ReferenceEquals(preparation, Volatile.Read(ref _inputPreparation)))
                    {
                        attemptOwned = true;
                        try
                        {
                            candidate = await SshInputSession.ConnectAsync(
                                generation.Route,
                                enableFilesFallback: false,
                                routeToken).ConfigureAwait(false);
                            await candidate.WakeIfDeepSleepingAsync(routeToken).ConfigureAwait(false);
                            if (generation.Kind is DeviceRouteKind.Wifi)
                            {
                                _diagnostics.Record(
                                    "files bridge",
                                    "Using the Xovi loopback Files route");
                                await candidate.NotifyActivityAsync(routeToken).ConfigureAwait(false);
                            }
                            if (IsCurrentGeneration(generation) &&
                                !_inputRetryLatched &&
                                !_inputRestoreUncertain &&
                                _inputSession is null &&
                                ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) &&
                                ReferenceEquals(preparation, Volatile.Read(ref _inputPreparation)))
                            {
                                _inputSession = candidate;
                                Interlocked.Exchange(
                                    ref _inputSessionGeneration,
                                    generation.Id);
                                publishedSession = candidate;
                                candidate = null;
                                ResetInputRetryPolicy();
                                MarkInputActivity();
                                MarkUsbPromotionInputReady(generation);
                                _diagnostics.Record(
                                    "input",
                                    "Controls published for the current route");
                                if (generation.Kind is DeviceRouteKind.Wifi)
                                {
                                    _ = ProbeFilesRouteAsync(generation);
                                }
                            }
                        }
                        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                        {
                            return;
                        }
                        catch (OperationCanceledException) when (routeToken.IsCancellationRequested)
                        {
                        }
                        catch (InputSessionException exception)
                        {
                            if (IsCurrentGeneration(generation) &&
                                !_inputRetryLatched &&
                                ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) &&
                                ReferenceEquals(preparation, Volatile.Read(ref _inputPreparation)))
                            {
                                currentFailureMessage = exception.Message;
                                if (!exception.IsPersistent &&
                                    _inputRecoveryPolicy.TryReserveSetupFailureRecovery(generation.Id))
                                {
                                    retryDelay = TimeSpan.FromMilliseconds(500);
                                    rearmSetupFailure = true;
                                    _diagnostics.Record(
                                        "input recovery",
                                        "Reserved one automatic retry after transient control setup failure");
                                }
                                else
                                {
                                    retryDelay = RegisterInputFailure();
                                    FailUsbPromotionCandidate(
                                        generation,
                                        "input setup failed");
                                }
                            }
                        }
                    }
                }
                finally
                {
                    if (candidate is not null)
                    {
                        try
                        {
                            await candidate.DisposeAsync();
                        }
                        catch (InputSessionException exception)
                        {
                            setupCleanupConfirmed = false;
                            LatchInputRestoreUncertain(exception.Message);
                            FailUsbPromotionCandidate(
                                generation,
                                "input cleanup was not confirmed");
                        }
                        catch (Exception exception)
                        {
                            setupCleanupConfirmed = false;
                            LatchInputRestoreUncertain(
                                "Mirror could not confirm that physical tablet input was restored after control setup failed.");
                            _diagnostics.Record(
                                "input cleanup",
                                $"Unpublished session: {exception.GetType().Name}");
                        }
                    }
                    if (attemptOwned)
                    {
                        if (rearmSetupFailure &&
                            setupCleanupConfirmed &&
                            !_inputRestoreUncertain &&
                            IsCurrentGeneration(generation))
                        {
                            RearmCoupledInputRecoveryUnderGate(generation);
                            _diagnostics.Record(
                                "input recovery",
                                "Rearmed one control setup retry behind fresh display and restoration barriers");
                        }
                        CompleteInputPreparation(preparation);
                    }
                    _inputLifecycleGate.Release();
                }

                if (publishedSession is not null)
                {
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (IsCurrentGeneration(generation) &&
                                ReferenceEquals(publishedSession, _inputSession))
                            {
                                SetInputAvailability(true);
                            }
                        },
                        cancellationToken).ConfigureAwait(false);
                }
                if (currentFailureMessage is not null)
                {
                    _diagnostics.Record("input failure", currentFailureMessage);
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (IsCurrentGeneration(generation))
                            {
                                SetInputAvailability(false);
                            }
                        },
                        cancellationToken).ConfigureAwait(false);
                }
            }
            else
            {
                try
                {
                    var activityInterval = generation.Kind is DeviceRouteKind.Wifi
                        ? WifiInputActivityInterval
                        : UsbInputActivityInterval;
                    if (Stopwatch.GetElapsedTime(
                            Interlocked.Read(ref _lastInputActivityTimestamp)) >= activityInterval)
                    {
                        await session.NotifyActivityAsync(routeToken).ConfigureAwait(false);
                        MarkInputActivity();
                    }
                    else if (Stopwatch.GetElapsedTime(
                                 Interlocked.Read(ref _lastInputHeartbeatTimestamp)) >= TimeSpan.FromSeconds(3))
                    {
                        await session.PingAsync(routeToken).ConfigureAwait(false);
                        MarkInputHeartbeat();
                    }
                }
                catch (InputSessionException exception)
                {
                    var removal = await DropInputSessionAfterFailureAsync(
                        session,
                        generation,
                        exception).ConfigureAwait(false);
                    if (removal.Removed)
                    {
                        _diagnostics.Record("input failure", exception.Message);
                        retryDelay = TimeSpan.FromMilliseconds(500);
                    }
                }
                catch (ObjectDisposedException)
                {
                    // Retry and frame recovery intentionally remove and dispose the
                    // published session. If this loop held that stale reference,
                    // keep running without re-latching the newly requested attempt.
                    var removal = await DropInputSessionAfterFailureAsync(
                        session,
                        generation,
                        new ObjectDisposedException(nameof(SshInputSession))).ConfigureAwait(false);
                    if (removal.Removed)
                    {
                        _diagnostics.Record("input failure", "The tablet input session closed unexpectedly.");
                        retryDelay = TimeSpan.FromMilliseconds(500);
                    }
                }
                catch (OperationCanceledException) when (
                    routeToken.IsCancellationRequested &&
                    !cancellationToken.IsCancellationRequested)
                {
                }
            }

            await DelayWithoutThrowAsync(retryDelay, cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private void ResetInputRetryPolicy()
    {
        _inputRetryLatched = false;
        Interlocked.Exchange(ref _inputRetryAttempt, 0);
    }

    private TimeSpan RegisterInputFailure()
    {
        Interlocked.Increment(ref _inputRetryAttempt);
        // Every managed input attempt can restart Xochitl. Do not run another
        // handoff after the generation's one automatic recovery is spent;
        // publication remains gated until explicit Retry or a new route.
        _inputRetryLatched = true;
        return TimeSpan.FromMilliseconds(500);
    }

    private void SetInputAvailability(bool available)
    {
        _inputAvailable = available;
        ToolTipService.SetToolTip(
            ModeSelector,
            available
                ? "Choose Touch or Pen for the pointer. Keyboard typing is automatic."
                : "Your pointer choice and automatic keyboard will activate when Mirror connects");
    }

    private void SetControlRecoveryStateFromAnyThread(
        MirrorInputRecoveryDisposition disposition)
    {
        DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.High,
            () =>
            {
                DeviceScreen.ReleasePointerCaptures();
                SetInputAvailability(false);
                if (_inputRestoreUncertain)
                {
                    return;
                }
                if (disposition is MirrorInputRecoveryDisposition.BeginNow)
                {
                    SetMirrorState(
                        MirrorConnectionState.Preparing,
                        "Reconnecting the tablet display and controls.");
                    return;
                }
                SetMirrorState(
                    MirrorConnectionState.Error,
                    disposition is MirrorInputRecoveryDisposition.AwaitingFrameInterruption
                        ? "Tablet controls disconnected. Mirror will reconnect them with the display, or choose Retry now."
                        : "Tablet controls stopped. Choose Retry to restore them.");
            });
    }

    private void MarkInputActivity()
    {
        var timestamp = Stopwatch.GetTimestamp();
        Interlocked.Exchange(ref _lastInputActivityTimestamp, timestamp);
        Interlocked.Exchange(ref _lastInputHeartbeatTimestamp, timestamp);
    }

    private void MarkInputHeartbeat() =>
        Interlocked.Exchange(ref _lastInputHeartbeatTimestamp, Stopwatch.GetTimestamp());

    private async Task CloseInputSessionAsync()
    {
        await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await RemoveInputSessionUnderGateAsync(
                expected: null,
                requireExpected: false,
                latchForRetry: false).ConfigureAwait(false);
        }
        finally
        {
            _inputLifecycleGate.Release();
        }
    }

    private async Task<bool> DropInputSessionAsync(
        SshInputSession session,
        bool latchForRetry)
    {
        await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var removal = await RemoveInputSessionUnderGateAsync(
                session,
                requireExpected: true,
                latchForRetry).ConfigureAwait(false);
            return removal.Removed;
        }
        finally
        {
            _inputLifecycleGate.Release();
        }
    }

    private async Task<InputFailureRemovalResult> DropInputSessionAfterFailureAsync(
        SshInputSession session,
        MirrorRouteGeneration generation,
        Exception failure)
    {
        await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var belongsToGeneration =
                IsCurrentGeneration(generation) &&
                ReferenceEquals(session, _inputSession) &&
                Interlocked.Read(ref _inputSessionGeneration) == generation.Id;
            var removal = await RemoveInputSessionUnderGateAsync(
                session,
                requireExpected: true,
                latchForRetry: true).ConfigureAwait(false);
            var disposition = MirrorInputRecoveryDisposition.None;
            if (belongsToGeneration && removal.Removed)
            {
                disposition = _inputRecoveryPolicy.RecordPublishedSessionLoss(
                    generation.Id,
                    Stopwatch.GetTimestamp(),
                    CoupledInputRecoveryWindow,
                    allowAutomaticRecovery:
                        removal.RestoreConfirmed &&
                        failure is InputSessionException { IsPersistent: false });
                if (disposition is MirrorInputRecoveryDisposition.BeginNow)
                {
                    RearmCoupledInputRecoveryUnderGate(generation);
                    _diagnostics.Record(
                        "input recovery",
                        "Rearmed one control handoff after input joined the recent display interruption");
                }
                else if (disposition is MirrorInputRecoveryDisposition.AwaitingFrameInterruption)
                {
                    _diagnostics.Record(
                        "input recovery",
                        "Scheduled one control handoff if the display fails in the same interruption");
                }
                SetControlRecoveryStateFromAnyThread(disposition);
            }

            return new InputFailureRemovalResult(removal.Removed, disposition);
        }
        finally
        {
            _inputLifecycleGate.Release();
        }
    }

    private async Task<InputSessionRemovalResult> RemoveInputSessionUnderGateAsync(
        SshInputSession? expected,
        bool requireExpected,
        bool latchForRetry)
    {
        var session = _inputSession;
        if (session is null || (requireExpected && !ReferenceEquals(session, expected)))
        {
            return InputSessionRemovalResult.NotRemoved(
                restoreConfirmed: !_inputRestoreUncertain);
        }

        if (latchForRetry)
        {
            RegisterInputFailure();
        }
        _inputSession = null;
        Interlocked.Exchange(ref _inputSessionGeneration, 0);
        try
        {
            await session.DisposeAsync();
        }
        catch (InputSessionException exception)
        {
            LatchInputRestoreUncertain(exception.Message);
            return new InputSessionRemovalResult(Removed: true, RestoreConfirmed: false);
        }
        finally
        {
            SetInputAvailabilityFromAnyThread(false);
        }
        return new InputSessionRemovalResult(
            Removed: true,
            RestoreConfirmed: !_inputRestoreUncertain);
    }

    private void LatchInputRestoreUncertain(string diagnostic)
    {
        _inputRestoreUncertain = true;
        _inputRetryLatched = true;
        _actionRequiredFailure = true;
        _diagnostics.Record("input cleanup", diagnostic);
        SetInputAvailabilityFromAnyThread(false);
        DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.High,
            () => SetMirrorState(
                MirrorConnectionState.Error,
                "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again."));
    }

    private void SetInputAvailabilityFromAnyThread(bool available)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            SetInputAvailability(available);
            return;
        }
        DispatcherQueue.TryEnqueue(
            DispatcherQueuePriority.High,
            () => SetInputAvailability(available));
    }

    private async Task RunOnUIThreadAsync(Action action, CancellationToken cancellationToken)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            action();
            return;
        }

        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
        if (!DispatcherQueue.TryEnqueue(
                DispatcherQueuePriority.High,
                () =>
                {
                    try
                    {
                        action();
                        completion.TrySetResult(true);
                    }
                    catch (Exception exception)
                    {
                        completion.TrySetException(exception);
                    }
                }))
        {
            completion.TrySetException(new InvalidOperationException("The mirror window is closing."));
        }
        await completion.Task.ConfigureAwait(false);
    }

    private static async Task DelayWithoutThrowAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void SignalFrameRetry()
    {
        try
        {
            _frameRetrySignal.Release();
        }
        catch (SemaphoreFullException)
        {
            // A pending retry already carries the newest connection state.
        }
    }

    private void DrainFrameRetrySignal()
    {
        while (_frameRetrySignal.Wait(0))
        {
        }
    }

    private async Task WaitForFrameRetryAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        if (delay == Timeout.InfiniteTimeSpan)
        {
            await _frameRetrySignal.WaitAsync(cancellationToken).ConfigureAwait(false);
            return;
        }

        using var waitCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var timer = Task.Delay(delay, waitCancellation.Token);
        var retry = _frameRetrySignal.WaitAsync(waitCancellation.Token);
        try
        {
            await Task.WhenAny(timer, retry).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
        finally
        {
            waitCancellation.Cancel();
            await IgnoreCancellationAsync(timer).ConfigureAwait(false);
            await IgnoreCancellationAsync(retry).ConfigureAwait(false);
        }
    }

    private static TimeSpan RetryDelayFor(int attempt) => attempt switch
    {
        <= 1 => TimeSpan.FromSeconds(2),
        2 => TimeSpan.FromSeconds(5),
        3 => TimeSpan.FromSeconds(10),
        4 => TimeSpan.FromSeconds(20),
        _ => TimeSpan.FromSeconds(30),
    };

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

    private async Task AwaitWorkerShutdownAsync(params Task?[] tasks)
    {
        foreach (var task in tasks)
        {
            if (task is null)
            {
                continue;
            }
            try
            {
                await task.ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception exception)
            {
                _diagnostics.Record("worker fault", exception.GetType().Name);
            }
        }
    }

    private async void ConnectionActionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_inputRestoreUncertain)
        {
            ShowInfo(
                "Restart the tablet and reopen Mirror before using controls again.",
                InfoBarSeverity.Warning);
            return;
        }
        _diagnostics.Record("action", "Connection retry requested");
        _actionRequiredFailure = false;
        SetMirrorState(MirrorConnectionState.Preparing, "Checking the tablet connection now.");
        // Block an unpublished input handoff before waiting for lifecycle ownership.
        _inputRetryLatched = true;
        await _routeLifecycleGate.WaitAsync();
        try
        {
            await _inputLifecycleGate.WaitAsync();
            try
            {
                // Fence the old frame/input generation and finish any in-flight
                // Xochitl restoration before the new attempt can begin. Route
                // ownership makes a null generation stable rather than a
                // transient gap during publication.
                await RemoveInputSessionUnderGateAsync(
                    expected: null,
                    requireExpected: false,
                    latchForRetry: false);
                var generation = Volatile.Read(ref _routeGeneration);
                if (generation is null)
                {
                    _inputRecoveryPolicy.Reset();
                }
                else
                {
                    _inputRecoveryPolicy.RearmGeneration(generation.Id);
                }
                ResetDisplayPreparation();
                ResetInputPreparation();
                ResetInputRetryPolicy();
            }
            finally
            {
                _inputLifecycleGate.Release();
            }
        }
        finally
        {
            _routeLifecycleGate.Release();
        }
        _connectionMonitor.RequestProbe();
        SignalFrameRetry();
    }

    private void CopyConnectionDetailsButton_Click(object sender, RoutedEventArgs e)
    {
        var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        data.SetText(_diagnostics.Export());
        Clipboard.SetContent(data);
        ShowInfo("Connection details copied.", InfoBarSeverity.Success);
    }

    private async void FilesButton_Click(object sender, RoutedEventArgs e)
    {
        var opening = !_filesPaneDesiredOpen;
        if (App.MainWindow is MainWindow window)
        {
            await window.SetFilesPaneOpenAsync(opening);
        }
        else
        {
            await SetFilesPaneOpenAsync(opening);
        }
    }

    private void InitializeFilesPaneLayout()
    {
        if (_filesPaneDisposed ||
            _filesPaneInitialized ||
            XamlRoot is null ||
            StageSurface.ActualWidth <= 0 ||
            StageSurface.ActualHeight <= 0 ||
            WorkspaceLayout.ActualWidth <= 0)
        {
            return;
        }

        // Lay out the approved compact tablet and the Files pane once. During
        // motion the native window clips this fixed tree; nothing reflows.
        _compactStageWidth = StageSurface.ActualWidth;
        _compactWorkspaceWidth = WorkspaceLayout.ActualWidth;
        TabletColumn.Width = new GridLength(_compactWorkspaceWidth);
        FilesColumn.Width = new GridLength(FilesPaneWidth);
        TabletCanvas.Width = _compactWorkspaceWidth;
        TabletCanvas.HorizontalAlignment = HorizontalAlignment.Left;
        HeaderMirrorRegion.Width = HeaderMirrorRegion.ActualWidth;
        HeaderMirrorRegion.HorizontalAlignment = HorizontalAlignment.Left;
        StageSurface.Width = _compactStageWidth + FilesPaneWidth;
        StageSurface.HorizontalAlignment = HorizontalAlignment.Left;
        MainFilesPane.Visibility = Visibility.Visible;
        MainFilesPane.Opacity = 1;
        MainFilesPane.IsHitTestVisible = false;
        MainFilesPane.IsDocumentDragEnabled = false;

        var stageVisual = ElementCompositionPreview.GetElementVisual(StageSurface);
        var compositor = stageVisual.Compositor;
        var stageHeight = Math.Max(1, (float)StageSurface.ActualHeight);

        _stageClipGeometry = compositor.CreateRoundedRectangleGeometry();
        _stageClipGeometry.CornerRadius = new Vector2(StageCornerRadius);
        _stageClipGeometry.Size = new Vector2((float)_compactStageWidth, stageHeight);
        stageVisual.Clip = compositor.CreateGeometricClip(_stageClipGeometry);

        // The geometric clip supplies the moving rounded edge. This shape keeps
        // the subtle stage outline attached to that same edge throughout.
        _stageOutlineGeometry = compositor.CreateRoundedRectangleGeometry();
        _stageOutlineGeometry.CornerRadius = new Vector2(StageCornerRadius - 0.5f);
        _stageOutlineGeometry.Offset = new Vector2(0.5f);
        _stageOutlineGeometry.Size = new Vector2(
            Math.Max(1, (float)_compactStageWidth - 1),
            Math.Max(1, stageHeight - 1));
        var outline = compositor.CreateSpriteShape(_stageOutlineGeometry);
        outline.StrokeBrush = compositor.CreateColorBrush(
            Windows.UI.Color.FromArgb(255, 207, 207, 201));
        outline.StrokeThickness = 1;
        outline.IsStrokeNonScaling = true;
        _stageOutlineVisual = compositor.CreateShapeVisual();
        _stageOutlineVisual.IsHitTestVisible = false;
        _stageOutlineVisual.Size = new Vector2(
            (float)(_compactStageWidth + FilesPaneWidth),
            stageHeight);
        _stageOutlineVisual.Shapes.Add(outline);
        ElementCompositionPreview.SetElementChildVisual(StageSurface, _stageOutlineVisual);

        _filesPaneInitialized = true;
        _filesPaneLinearProgress = 0;
        StageSurface.SizeChanged += StageSurface_SizeChanged;
        ApplyFilesPaneProgress(0);
    }

    internal Task SetFilesPaneOpenAsync(bool isOpen)
    {
        InitializeFilesPaneLayout();
        if (_filesPaneDisposed ||
            !_filesPaneInitialized ||
            App.MainWindow is not MainWindow window)
        {
            return Task.CompletedTask;
        }

        if (_filesPaneDesiredOpen == isOpen)
        {
            return _filesPaneTransitionCompletion?.Task ?? Task.CompletedTask;
        }

        _filesPaneDesiredOpen = isOpen;
        _filesPaneTransitionCompletion?.TrySetResult();
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _filesPaneTransitionCompletion = completion;
        _filesPaneTransitioning = true;
        MainFilesPane.IsHitTestVisible = isOpen;
        MainFilesPane.IsDocumentDragEnabled = false;

        // The fixed expanded tree is ready before the first width change. A
        // render-frame clock changes direction in place for immediate toggles;
        // unlike a completed compositor animation, it can always restart.
        window.BeginFilesPaneNativeResize();
        _filesPaneDirection = isOpen ? 1 : -1;
        _filesPaneLastFrameTimestamp = Stopwatch.GetTimestamp();
        if (!_filesPaneRenderingSubscribed)
        {
            CompositionTarget.Rendering += FilesPaneTransition_Rendering;
            _filesPaneRenderingSubscribed = true;
        }

        return completion.Task;
    }

    private void FilesPaneTransition_Rendering(object? sender, object args)
    {
        if (!_filesPaneTransitioning ||
            !_filesPaneInitialized ||
            App.MainWindow is not MainWindow window)
        {
            StopFilesPaneRendering();
            return;
        }

        var now = Stopwatch.GetTimestamp();
        var elapsedSeconds = _filesPaneLastFrameTimestamp == 0
            ? 0
            : Stopwatch.GetElapsedTime(_filesPaneLastFrameTimestamp, now).TotalSeconds;
        _filesPaneLastFrameTimestamp = now;
        var durationSeconds = _filesPaneDirection > 0
            ? FilesPaneOpenDurationSeconds
            : FilesPaneCloseDurationSeconds;
        _filesPaneLinearProgress = Math.Clamp(
            _filesPaneLinearProgress + ((_filesPaneDirection * elapsedSeconds) / durationSeconds),
            0,
            1);
        var progress = _filesPaneLinearProgress *
            _filesPaneLinearProgress *
            (3 - (2 * _filesPaneLinearProgress));
        ApplyFilesPaneProgress(progress);

        var reachedTarget = _filesPaneDesiredOpen
            ? _filesPaneLinearProgress >= 1
            : _filesPaneLinearProgress <= 0;
        if (!reachedTarget)
        {
            return;
        }

        var open = _filesPaneDesiredOpen;
        var endpoint = open ? 1f : 0f;
        _filesPaneLinearProgress = endpoint;
        ApplyFilesPaneProgress(endpoint);
        window.EndFilesPaneNativeResize(open);
        MainFilesPane.IsHitTestVisible = open;
        MainFilesPane.IsDocumentDragEnabled = open;
        _filesPaneOpen = open;
        _filesPaneTransitioning = false;
        _filesPaneDirection = 0;
        _filesPaneLastFrameTimestamp = 0;
        StopFilesPaneRendering();

        var completion = _filesPaneTransitionCompletion;
        _filesPaneTransitionCompletion = null;
        completion?.TrySetResult();
        if (open)
        {
            _ = RefreshLibraryAsync();
        }
    }

    private void ApplyFilesPaneProgress(double progress)
    {
        progress = Math.Clamp(progress, 0, 1);
        _filesPaneProgress = progress;
        var stageHeight = Math.Max(1, (float)StageSurface.ActualHeight);
        var revealedWidth = (float)(_compactStageWidth + (FilesPaneWidth * progress));
        if (_stageClipGeometry is not null)
        {
            _stageClipGeometry.Size = new Vector2(revealedWidth, stageHeight);
        }
        if (_stageOutlineGeometry is not null)
        {
            _stageOutlineGeometry.Size = new Vector2(
                Math.Max(1, revealedWidth - 1),
                Math.Max(1, stageHeight - 1));
        }
        if (_stageOutlineVisual is not null)
        {
            _stageOutlineVisual.Size = new Vector2(
                (float)(_compactStageWidth + FilesPaneWidth),
                stageHeight);
        }
        if (App.MainWindow is MainWindow window)
        {
            window.SetFilesPaneWindowProgress(progress);
        }
    }

    private void StageSurface_SizeChanged(object sender, SizeChangedEventArgs e) =>
        ApplyFilesPaneProgress(_filesPaneProgress);

    private void StopFilesPaneRendering()
    {
        if (!_filesPaneRenderingSubscribed)
        {
            return;
        }
        CompositionTarget.Rendering -= FilesPaneTransition_Rendering;
        _filesPaneRenderingSubscribed = false;
    }

    internal void DisposeFilesPaneAnimation()
    {
        if (_filesPaneDisposed)
        {
            return;
        }
        _filesPaneDisposed = true;
        MainFilesPane.IsDocumentDragEnabled = false;
        StageSurface.SizeChanged -= StageSurface_SizeChanged;
        StopFilesPaneRendering();
        _filesPaneTransitionCompletion?.TrySetResult();
        _filesPaneTransitionCompletion = null;
        ElementCompositionPreview.GetElementVisual(StageSurface).Clip = null;
        ElementCompositionPreview.SetElementChildVisual(StageSurface, null);
        _filesPaneInitialized = false;
        _filesPaneDirection = 0;
        _filesPaneLastFrameTimestamp = 0;
        _stageClipGeometry = null;
        _stageOutlineGeometry = null;
        _stageOutlineVisual = null;
    }

    private async void FilesPane_CloseRequested(object? sender, EventArgs e)
    {
        if (App.MainWindow is MainWindow window)
        {
            await window.SetFilesPaneOpenAsync(false);
        }
        else
        {
            await SetFilesPaneOpenAsync(false);
        }
    }

    private async void FilesPane_RefreshRequested(object? sender, EventArgs e) =>
        await RefreshLibraryAsync();

    private async void FilesPane_BackRequested(object? sender, EventArgs e)
    {
        if (_folderHistory.Count == 0)
        {
            return;
        }

        (_currentFolderId, _currentFolderName) = _folderHistory.Pop();
        await RefreshLibraryAsync();
    }

    private async void FilesPane_LibraryItemInvoked(
        object? sender,
        FilesPaneLibraryItemEventArgs e)
    {
        if (!_filesPaneState.IsLibraryEnabled)
        {
            return;
        }
        var item = e.Item;

        if (item.Kind is RemarkableLibraryItemKind.Collection)
        {
            _folderHistory.Push((_currentFolderId, _currentFolderName));
            _currentFolderId = item.Id;
            _currentFolderName = string.IsNullOrWhiteSpace(item.Name) ? "Folder" : item.Name;
            await RefreshLibraryAsync();
            return;
        }

        await SaveLibraryDocumentAsync(item, native: false);
    }

    private async void FilesPane_SavePdfRequested(
        object? sender,
        FilesPaneLibraryItemEventArgs e) =>
        await SaveLibraryDocumentAsync(e.Item, native: false);

    private async void FilesPane_SaveNativeRequested(
        object? sender,
        FilesPaneLibraryItemEventArgs e) =>
        await SaveLibraryDocumentAsync(e.Item, native: true);

    private LibraryDocumentDragSession BeginLibraryDocumentDrag(
        LibraryDocumentDragRequest request)
    {
        var displayName = SafeSuggestedName(request.DisplayName, ".pdf");
        return new LibraryDocumentDragSession(
            request,
            $"{displayName}.pdf",
            MaterializeLibraryDocumentDragAsync,
            CompleteLibraryDocumentDrag,
            ReportLibraryDocumentDragProviderFailure);
    }

    private void CompleteLibraryDocumentDrag(LibraryDocumentDragCompletion completion)
    {
        var preparedDrag = completion.PreparedDrag;
        _diagnostics.Record(
            "files drag-out",
            preparedDrag is null
                ? $"result={completion.DropResult} materialized=false"
                : $"result={completion.DropResult} bytes={preparedDrag.BytesWritten}");
        if (preparedDrag is null)
        {
            return;
        }

        if (completion.DropResult is DataPackageOperation.None)
        {
            _ = Task.Run(() => DeleteDocumentDragDirectory(preparedDrag.StagingDirectory));
            return;
        }

        _ = DeleteDocumentDragDirectoryAfterDelayAsync(preparedDrag.StagingDirectory);
    }

    private void ReportLibraryDocumentDragProviderFailure(Exception exception)
    {
        _diagnostics.Record(
            "files drag-out failure",
            $"provider={exception.GetType().Name} 0x{exception.HResult:X8}");
        DispatcherQueue.TryEnqueue(
            () => ShowInfo(
                "Windows couldn’t receive that PDF. Drag it out again.",
                InfoBarSeverity.Error));
    }

    private MirrorRouteGeneration? BeginFilesOperation()
    {
        lock (_routeAdmissionGate)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            if (generation is null ||
                generation.CancellationToken.IsCancellationRequested ||
                _filesReadyGeneration != generation.Id)
            {
                return null;
            }

            _activeFilesOperations++;
            return generation;
        }
    }

    private void EndFilesOperation(MirrorRouteGeneration generation)
    {
        var requestPreferredRouteProbe = false;
        lock (_routeAdmissionGate)
        {
            if (_activeFilesOperations > 0)
            {
                _activeFilesOperations--;
            }
            requestPreferredRouteProbe = _activeFilesOperations == 0 &&
                ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) &&
                !generation.CancellationToken.IsCancellationRequested &&
                generation.Kind is DeviceRouteKind.Wifi &&
                _activePointerOperation == 0;
        }
        if (requestPreferredRouteProbe)
        {
            _connectionMonitor.RequestProbe();
        }
    }

    private async Task RefreshLibraryAsync()
    {
        if (!IsFilesRouteReady())
        {
            _filesPaneState.CompleteLibraryRefresh(
                "Connect your reMarkable to browse files.",
                canGoBack: false);
            return;
        }

        var routeGeneration = BeginFilesOperation();
        if (routeGeneration is null)
        {
            _filesPaneState.CompleteLibraryRefresh(
                "Connect your reMarkable to browse files.",
                canGoBack: false);
            return;
        }

        var generation = ++_libraryRefreshGeneration;
        var token = routeGeneration.CancellationToken;
        _filesPaneState.BeginLibraryRefresh(_currentFolderName);

        try
        {
            var items = _currentFolderId is null
                ? await routeGeneration.FileTransport.ListRootAsync(token)
                : await routeGeneration.FileTransport.ListFolderAsync(_currentFolderId, token);
            if (generation != _libraryRefreshGeneration ||
                !IsCurrentGeneration(routeGeneration))
            {
                return;
            }

            LibraryItems.Clear();
            foreach (var item in items
                         .OrderBy(item => item.Kind is RemarkableLibraryItemKind.Collection ? 0 : 1)
                         .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                LibraryItems.Add(item);
            }

            _filesPaneState.LibraryStatusText = items.Count == 0
                ? "This folder is empty."
                : $"{items.Count} item{(items.Count == 1 ? string.Empty : "s")}";
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (FileTransferException exception)
        {
            if (generation != _libraryRefreshGeneration ||
                !IsCurrentGeneration(routeGeneration))
            {
                return;
            }

            LibraryItems.Clear();
            if (exception.Failure is FileTransferFailure.Connection)
            {
                MarkFilesRouteUnhealthy(routeGeneration);
            }
            _filesPaneState.LibraryStatusText = exception.Failure is FileTransferFailure.Connection
                ? routeGeneration.Kind is DeviceRouteKind.Wifi
                    ? "Wake or unlock your reMarkable. Files will reconnect automatically."
                    : "Unlock your reMarkable and turn on its USB web interface, then refresh."
                : exception.Message;
        }
        finally
        {
            if (generation == _libraryRefreshGeneration &&
                IsCurrentGeneration(routeGeneration))
            {
                _filesPaneState.IsAvailable = IsFilesRouteReady();
                _filesPaneState.CompleteLibraryRefresh(
                    _filesPaneState.LibraryStatusText,
                    _folderHistory.Count > 0);
            }
            EndFilesOperation(routeGeneration);
        }
    }

    private async Task SaveLibraryDocumentAsync(RemarkableLibraryItem item, bool native)
    {
        if (item.Kind is not RemarkableLibraryItemKind.Document)
        {
            return;
        }
        if (!_exportGate.Wait(0))
        {
            ShowInfo("Finish the current export first.");
            return;
        }

        var routeGeneration = BeginFilesOperation();
        if (routeGeneration is null)
        {
            _exportGate.Release();
            ShowInfo("Connect your reMarkable before exporting.");
            return;
        }

        var token = routeGeneration.CancellationToken;
        string? stagedPath = null;
        var cleanStagedFile = true;
        try
        {
            var extension = native ? ".rmdoc" : ".pdf";
            var exportDirectory = Path.Combine(
                MirrorApplicationData.TemporaryFolder.Path,
                "exports");
            stagedPath = Path.Combine(exportDirectory, $"{Guid.NewGuid():N}{extension}");
            Directory.CreateDirectory(exportDirectory);
            ShowInfo($"Preparing {item.Name}…");
            var result = native
                ? await routeGeneration.FileTransport.DownloadRmdocToFileAsync(
                    item.Id,
                    stagedPath,
                    cancellationToken: token)
                : await routeGeneration.FileTransport.DownloadPdfToFileAsync(
                    item.Id,
                    stagedPath,
                    cancellationToken: token);
            if (!IsCurrentGeneration(routeGeneration))
            {
                return;
            }

            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName = SafeSuggestedName(
                    result.SuggestedFileName ?? item.Name,
                    extension),
            };
            picker.FileTypeChoices.Add(native ? "reMarkable document" : "PDF document", [extension]);
            if (App.MainWindow is not null)
            {
                WinRT.Interop.InitializeWithWindow.Initialize(
                    picker,
                    WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
            }

            var file = await picker.PickSaveFileAsync();
            if (!IsCurrentGeneration(routeGeneration))
            {
                return;
            }
            if (file is null)
            {
                ShowInfo("Export canceled.");
                return;
            }

            var stagedFile = await StorageFile.GetFileFromPathAsync(stagedPath);
            await stagedFile.CopyAndReplaceAsync(file);
            ShowInfo($"Saved {file.Name} · {FormatByteCount(result.BytesWritten)}", InfoBarSeverity.Success);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (FileTransferException exception)
        {
            if (IsCurrentGeneration(routeGeneration))
            {
                ShowInfo(exception.Message, InfoBarSeverity.Error);
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or
            System.Runtime.InteropServices.COMException)
        {
            cleanStagedFile = false;
            if (IsCurrentGeneration(routeGeneration))
            {
                ShowInfo(
                    "Windows couldn’t save the prepared export. Try another location.",
                    InfoBarSeverity.Error);
            }
        }
        finally
        {
            if (cleanStagedFile && stagedPath is not null)
            {
                try
                {
                    File.Delete(stagedPath);
                }
                catch (Exception exception) when (
                    exception is IOException or UnauthorizedAccessException)
                {
                }
            }
            EndFilesOperation(routeGeneration);
            _exportGate.Release();
        }
    }

    private async Task<PreparedLibraryDocumentDrag?> MaterializeLibraryDocumentDragAsync(
        LibraryDocumentDragRequest request,
        CancellationToken cancellationToken)
    {
        MirrorRouteGeneration? routeGeneration = null;
        string? stagingDirectory = null;
        var materialized = false;
        var ownsExportGate = false;
        try
        {
            await _exportGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            ownsExportGate = true;

            routeGeneration = BeginFilesOperation();
            if (routeGeneration is null)
            {
                ShowLibraryDocumentDragError(
                    "Wake the tablet first. If Wi-Fi does not return, connect USB-C, then drag again.");
                return null;
            }

            using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                routeGeneration.CancellationToken);
            var token = linkedCancellation.Token;
            token.ThrowIfCancellationRequested();

            var exportRoot = GetDocumentDragExportRoot();
            stagingDirectory = Path.Combine(exportRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stagingDirectory);
            var displayName = SafeSuggestedName(request.DisplayName, ".pdf");
            var stagedPath = Path.Combine(stagingDirectory, $"{displayName}.pdf");

            _diagnostics.Record(
                "files drag-out",
                $"PDF requested over {routeGeneration.Kind}");
            var result = await routeGeneration.FileTransport.DownloadPdfToFileAsync(
                    request.DocumentId,
                    stagedPath,
                    cancellationToken: token)
                .ConfigureAwait(false);
            if (!IsCurrentGeneration(routeGeneration))
            {
                return null;
            }

            var storageFile = await StorageFile.GetFileFromPathAsync(stagedPath)
                .AsTask(token)
                .ConfigureAwait(false);
            if (!IsCurrentGeneration(routeGeneration))
            {
                return null;
            }

            _diagnostics.Record(
                "files drag-out",
                $"PDF supplied bytes={result.BytesWritten} route={routeGeneration.Kind}");
            var preparedDrag = new PreparedLibraryDocumentDrag(
                storageFile,
                stagingDirectory,
                result.BytesWritten);
            materialized = true;
            return preparedDrag;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (FileTransferException exception)
        {
            if (routeGeneration is not null &&
                exception.Failure is FileTransferFailure.Connection)
            {
                MarkFilesRouteUnhealthy(routeGeneration);
                ShowLibraryDocumentDragError(
                    routeGeneration.Kind is DeviceRouteKind.Wifi
                        ? "Wake or unlock your reMarkable, then drag again."
                        : "Unlock your reMarkable, then drag again.");
            }
            else
            {
                ShowLibraryDocumentDragError(exception.Message);
            }
            _diagnostics.Record(
                "files drag-out failure",
                routeGeneration is null
                    ? $"failure={exception.Failure} route=Unavailable"
                    : $"failure={exception.Failure} route={routeGeneration.Kind}");
            return null;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or
            System.Runtime.InteropServices.COMException)
        {
            _diagnostics.Record(
                "files drag-out failure",
                $"{exception.GetType().Name} 0x{exception.HResult:X8}");
            ShowLibraryDocumentDragError(
                "Windows couldn’t provide that PDF. Drag it out again.");
            return null;
        }
        finally
        {
            if (!materialized && stagingDirectory is not null)
            {
                DeleteDocumentDragDirectory(stagingDirectory);
            }
            if (routeGeneration is not null)
            {
                EndFilesOperation(routeGeneration);
            }
            if (ownsExportGate)
            {
                _exportGate.Release();
            }
        }
    }

    private void ShowLibraryDocumentDragError(string message) =>
        DispatcherQueue.TryEnqueue(
            () => ShowInfo(message, InfoBarSeverity.Error));

    private static string GetDocumentDragExportRoot() =>
        Path.Combine(MirrorApplicationData.LocalCacheFolder.Path, "drag-out");

    private static void CleanupStaleDocumentDragExports()
    {
        try
        {
            var exportRoot = GetDocumentDragExportRoot();
            if (!Directory.Exists(exportRoot))
            {
                return;
            }

            var oldestRetainedWrite = DateTime.UtcNow - StaleDocumentDragRetention;
            foreach (var directory in Directory.EnumerateDirectories(exportRoot))
            {
                try
                {
                    if (Directory.GetLastWriteTimeUtc(directory) < oldestRetainedWrite)
                    {
                        DeleteDocumentDragDirectory(directory);
                    }
                }
                catch (Exception exception) when (
                    exception is IOException or UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static async Task DeleteDocumentDragDirectoryAfterDelayAsync(string directory)
    {
        await Task.Delay(CompletedDocumentDragRetention);
        DeleteDocumentDragDirectory(directory);
    }

    private static void DeleteDocumentDragDirectory(string directory)
    {
        try
        {
            var exportRoot = Path.GetFullPath(GetDocumentDragExportRoot())
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            var resolvedDirectory = Path.GetFullPath(directory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            if (!resolvedDirectory.StartsWith(exportRoot, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            Directory.Delete(directory, recursive: true);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static string SafeSuggestedName(string name, string? extensionToStrip = null)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(name
            .Select(character => invalid.Contains(character) ? '-' : character)
            .ToArray())
            .Trim(' ', '.');
        if (!string.IsNullOrWhiteSpace(extensionToStrip) &&
            clean.EndsWith(extensionToStrip, StringComparison.OrdinalIgnoreCase))
        {
            clean = clean[..^extensionToStrip.Length].TrimEnd(' ', '.');
        }

        if (string.IsNullOrWhiteSpace(clean))
        {
            clean = "reMarkable document";
        }

        var reservedBaseName = clean.Split('.', 2)[0];
        if (reservedBaseName.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            reservedBaseName.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            reservedBaseName.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            reservedBaseName.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            (reservedBaseName.Length == 4 &&
                (reservedBaseName.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
                 reservedBaseName.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
                reservedBaseName[3] is >= '1' and <= '9'))
        {
            clean = $"{clean} document";
        }

        const int maximumBaseNameLength = 120;
        if (clean.Length > maximumBaseNameLength)
        {
            clean = clean[..maximumBaseNameLength].TrimEnd(' ', '.');
            if (clean.Length > 0 && char.IsHighSurrogate(clean[^1]))
            {
                clean = clean[..^1];
            }
        }

        return string.IsNullOrWhiteSpace(clean) ? "reMarkable document" : clean;
    }

    private static string FormatByteCount(long bytes) => bytes switch
    {
        >= 1_000_000 => $"{bytes / 1_000_000d:0.#} MB",
        >= 1_000 => $"{bytes / 1_000d:0.#} KB",
        _ => $"{bytes} B",
    };

    private async void ScreenshotButton_Click(object sender, RoutedEventArgs e)
    {
        _diagnostics.Record("action", "Screenshot copy requested");
        if (!_haveFrame)
        {
            ShowInfo("Screenshot will be available when the mirror is live.");
            return;
        }

        ScreenshotButton.IsEnabled = false;
        try
        {
            var frameAtClick = _latestFrame.ToArray();
            var screenshotFile = await MirrorApplicationData.TemporaryFolder.CreateFileAsync(
                $"reMarkable screenshot {DateTime.Now:yyyy-MM-dd HH-mm-ss}.png",
                CreationCollisionOption.GenerateUniqueName);
            using (var stream = await screenshotFile.OpenAsync(FileAccessMode.ReadWrite))
            {
                await EncodePngAsync(frameAtClick, stream);
            }

            var package = new DataPackage
            {
                RequestedOperation = DataPackageOperation.Copy,
            };
            package.SetBitmap(RandomAccessStreamReference.CreateFromFile(screenshotFile));
            await SetClipboardContentAsync(package);

            _diagnostics.Record(
                "screenshot",
                $"Clipboard bitmap ready {SshFrameSource.FrameWidth}x{SshFrameSource.FrameHeight}");
            ShowInfo("Screenshot copied.", InfoBarSeverity.Success);
        }
        catch (Exception exception)
        {
            _diagnostics.Record(
                "screenshot failure",
                $"{exception.GetType().Name} 0x{exception.HResult:X8}");
            ShowInfo("Couldn’t copy the screenshot. Try again.", InfoBarSeverity.Error);
        }
        finally
        {
            ScreenshotButton.IsEnabled = true;
        }
    }

    private static async Task SetClipboardContentAsync(DataPackage package)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                Clipboard.SetContent(package);
                Clipboard.Flush();
                return;
            }
            catch (System.Runtime.InteropServices.COMException exception) when (
                exception.HResult == ClipboardCannotOpenHResult && attempt < 6)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50 * attempt));
            }
        }
    }

    private async void ScreenshotSave_Click(object sender, RoutedEventArgs e)
    {
        _diagnostics.Record("action", "Screenshot save requested");
        if (!_haveFrame)
        {
            ShowInfo("Screenshot will be available when the mirror is live.");
            return;
        }

        ScreenshotButton.IsEnabled = false;
        try
        {
            var frameAtClick = _latestFrame.ToArray();
            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.PicturesLibrary,
                SuggestedFileName = $"reMarkable {DateTime.Now:yyyy-MM-dd HH-mm-ss}",
            };
            picker.FileTypeChoices.Add("PNG image", [".png"]);
            if (App.MainWindow is not null)
            {
                WinRT.Interop.InitializeWithWindow.Initialize(
                    picker,
                    WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
            }

            var file = await picker.PickSaveFileAsync();
            if (file is null)
            {
                _diagnostics.Record("screenshot", "Save picker canceled");
                return;
            }

            using (var stream = await file.OpenAsync(FileAccessMode.ReadWrite))
            {
                stream.Size = 0;
                await EncodePngAsync(frameAtClick, stream);
            }

            _diagnostics.Record(
                "screenshot",
                $"Saved bitmap {SshFrameSource.FrameWidth}x{SshFrameSource.FrameHeight}");
            ShowInfo("Screenshot saved.", InfoBarSeverity.Success);
        }
        catch (Exception exception)
        {
            _diagnostics.Record(
                "screenshot failure",
                $"Save {exception.GetType().Name} 0x{exception.HResult:X8}");
            ShowInfo("Couldn’t save the screenshot. Try again.", InfoBarSeverity.Error);
        }
        finally
        {
            ScreenshotButton.IsEnabled = true;
        }
    }

    private static async Task EncodePngAsync(byte[] frame, IRandomAccessStream stream)
    {
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied,
            SshFrameSource.FrameWidth,
            SshFrameSource.FrameHeight,
            96,
            96,
            frame);
        await encoder.FlushAsync();
    }

    private async void ModeButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton selected || selected.Tag is not string mode)
        {
            return;
        }

        var nextMode = mode switch
        {
            "Pen" => RemoteInputMode.Pen,
            _ => RemoteInputMode.Touch,
        };
        if (nextMode != _inputMode)
        {
            await ResetRemoteInputStateAsync();
        }
        TouchModeButton.IsChecked = ReferenceEquals(selected, TouchModeButton);
        PenModeButton.IsChecked = ReferenceEquals(selected, PenModeButton);
        _inputMode = nextMode;
        FocusRemoteKeyboard(FocusState.Programmatic);
    }

    private async void DeviceScreen_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        FocusRemoteKeyboard(FocusState.Pointer);
        var point = e.GetCurrentPoint(DeviceScreen);
        if (!point.IsInContact && !point.Properties.IsLeftButtonPressed &&
            !point.Properties.IsRightButtonPressed)
        {
            return;
        }

        if (!TryBeginPointerOperation(e.Pointer.PointerId))
        {
            return;
        }
        _activePenEraser = point.Properties.IsRightButtonPressed;
        DeviceScreen.CapturePointer(e.Pointer);
        e.Handled = true;
        await SendPointerAsync(RemotePointerAction.Down, point);
    }

    private async void DeviceScreen_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_activePointerId != e.Pointer.PointerId || _inputSession is null)
        {
            return;
        }
        var now = Stopwatch.GetTimestamp();
        if (Stopwatch.GetElapsedTime(
                Interlocked.Read(ref _lastPointerMoveTimestamp),
                now) < TimeSpan.FromMilliseconds(8))
        {
            return;
        }
        Interlocked.Exchange(ref _lastPointerMoveTimestamp, now);
        e.Handled = true;
        await SendPointerAsync(RemotePointerAction.Move, e.GetCurrentPoint(DeviceScreen));
    }

    private async void DeviceScreen_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_activePointerId != e.Pointer.PointerId)
        {
            return;
        }
        _activePointerId = null;
        DeviceScreen.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        try
        {
            await SendPointerAsync(RemotePointerAction.Up, e.GetCurrentPoint(DeviceScreen));
        }
        finally
        {
            EndPointerOperation();
        }
    }

    private void DeviceScreen_PointerCanceled(object sender, PointerRoutedEventArgs e) =>
        ReleaseRemotePointer(e.Pointer.PointerId);

    private void DeviceScreen_PointerCaptureLost(object sender, PointerRoutedEventArgs e) =>
        ReleaseRemotePointer(e.Pointer.PointerId);

    private async void ReleaseRemotePointer(uint pointerId)
    {
        if (_activePointerId != pointerId)
        {
            return;
        }
        await ResetRemoteInputStateAsync();
    }

    internal async Task ResetRemoteInputStateAsync()
    {
        _activePointerId = null;
        DeviceScreen.ReleasePointerCaptures();
        var session = _inputSession;
        var generation = Volatile.Read(ref _routeGeneration);
        if (session is null ||
            generation is null ||
            Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
            !IsCurrentGeneration(generation))
        {
            EndPointerOperation();
            return;
        }
        try
        {
            var token = generation.CancellationToken;
            await session.ResetAsync(token);
            if (IsCurrentGeneration(generation))
            {
                MarkInputActivity();
            }
        }
        catch (OperationCanceledException) when (generation.CancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is InputSessionException or ObjectDisposedException)
        {
            var removal = await DropInputSessionAfterFailureAsync(session, generation, exception);
            if (removal.Removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                if (IsCurrentGeneration(generation))
                {
                    ShowInfo(
                        removal.AutomaticRecoveryScheduled
                            ? "Reconnecting tablet controls."
                            : "Tablet controls stopped. Choose Retry to restore them.",
                        InfoBarSeverity.Warning);
                }
            }
        }
        finally
        {
            EndPointerOperation();
        }
    }

    private bool TryBeginPointerOperation(uint pointerId)
    {
        lock (_routeAdmissionGate)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            var session = _inputSession;
            if (generation is null ||
                generation.CancellationToken.IsCancellationRequested ||
                session is null ||
                Interlocked.Read(ref _inputSessionGeneration) != generation.Id)
            {
                return false;
            }

            _activePointerId = pointerId;
            _activePointerOperation = 1;
            return true;
        }
    }

    private void EndPointerOperation()
    {
        var requestPreferredRouteProbe = false;
        lock (_routeAdmissionGate)
        {
            _activePointerOperation = 0;
            var generation = Volatile.Read(ref _routeGeneration);
            requestPreferredRouteProbe = _activeFilesOperations == 0 &&
                generation?.Kind is DeviceRouteKind.Wifi &&
                !generation.CancellationToken.IsCancellationRequested;
        }
        if (requestPreferredRouteProbe)
        {
            _connectionMonitor.RequestProbe();
        }
    }

    private async Task SendPointerAsync(RemotePointerAction action, PointerPoint point)
    {
        var session = _inputSession;
        var generation = Volatile.Read(ref _routeGeneration);
        if (session is null ||
            generation is null ||
            Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
            !IsCurrentGeneration(generation))
        {
            return;
        }

        var x = Math.Clamp(point.Position.X / SshFrameSource.FrameWidth, 0, 1);
        var y = Math.Clamp(point.Position.Y / SshFrameSource.FrameHeight, 0, 1);
        var pressure = Math.Clamp((double)point.Properties.Pressure, 0.08, 1);
        var token = generation.CancellationToken;
        try
        {
            if (_inputMode is RemoteInputMode.Pen)
            {
                await session.SendPenAsync(
                    action,
                    action is RemotePointerAction.Up ? null : x,
                    action is RemotePointerAction.Up ? null : y,
                    action is RemotePointerAction.Up ? null : pressure,
                    _activePenEraser,
                    token);
            }
            else
            {
                await session.SendTouchAsync(
                    action,
                    action is RemotePointerAction.Up ? null : x,
                    action is RemotePointerAction.Up ? null : y,
                    action is RemotePointerAction.Up ? null : pressure,
                    token);
            }
            if (IsCurrentGeneration(generation))
            {
                MarkInputActivity();
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (InputCommandRejectedException)
        {
            if (IsCurrentGeneration(generation) && ReferenceEquals(session, _inputSession))
            {
                await ResetRemoteInputStateAsync();
                ShowInfo("Tablet input state was reset.");
            }
        }
        catch (Exception exception) when (exception is InputSessionException or ObjectDisposedException)
        {
            var removal = await DropInputSessionAfterFailureAsync(session, generation, exception);
            if (removal.Removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                if (IsCurrentGeneration(generation))
                {
                    ShowInfo(
                        removal.AutomaticRecoveryScheduled
                            ? "Reconnecting tablet controls."
                            : "Tablet controls stopped. Choose Retry to restore them.",
                        InfoBarSeverity.Warning);
                }
            }
        }
    }

    private async void MainPage_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!HasRemoteKeyboardFocus() || _inputSession is null ||
            LinuxKeyName(e.Key) is not { } key)
        {
            return;
        }
        e.Handled = true;
        await SendKeyAsync(key, true);
    }

    private async void MainPage_KeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (!HasRemoteKeyboardFocus() || _inputSession is null ||
            LinuxKeyName(e.Key) is not { } key)
        {
            return;
        }
        e.Handled = true;
        await SendKeyAsync(key, false);
    }

    private bool HasRemoteKeyboardFocus() =>
        XamlRoot is not null &&
        ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), this);

    private void FocusRemoteKeyboard(FocusState state)
    {
        if (!Focus(state))
        {
            _diagnostics.Record("input focus rejected", $"state={state}");
        }
    }

    private async void Page_LostFocus(object sender, RoutedEventArgs e)
    {
        if (ReferenceEquals(e.OriginalSource, this))
        {
            await ResetRemoteInputStateAsync();
        }
    }

    private async Task SendKeyAsync(string key, bool isDown)
    {
        var session = _inputSession;
        var generation = Volatile.Read(ref _routeGeneration);
        if (session is null ||
            generation is null ||
            Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
            !IsCurrentGeneration(generation))
        {
            return;
        }
        var token = generation.CancellationToken;
        try
        {
            await session.SendKeyAsync(key, isDown, token);
            if (IsCurrentGeneration(generation))
            {
                MarkInputActivity();
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (InputCommandRejectedException)
        {
            if (IsCurrentGeneration(generation) && ReferenceEquals(session, _inputSession))
            {
                await ResetRemoteInputStateAsync();
                ShowInfo("Tablet input state was reset.");
            }
        }
        catch (Exception exception) when (exception is InputSessionException or ObjectDisposedException)
        {
            var removal = await DropInputSessionAfterFailureAsync(session, generation, exception);
            if (removal.Removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                if (IsCurrentGeneration(generation))
                {
                    ShowInfo(
                        removal.AutomaticRecoveryScheduled
                            ? "Reconnecting tablet controls."
                            : "Tablet controls stopped. Choose Retry to restore them.",
                        InfoBarSeverity.Warning);
                }
            }
        }
    }

    private static string? LinuxKeyName(Windows.System.VirtualKey key)
    {
        var value = (int)key;
        if (value is >= 65 and <= 90)
        {
            return $"KEY_{(char)value}";
        }
        if (value is >= 48 and <= 57)
        {
            return $"KEY_{(char)value}";
        }
        if (value is >= 96 and <= 105)
        {
            return $"KEY_{value - 96}";
        }
        if (value is >= 112 and <= 123)
        {
            return $"KEY_F{value - 111}";
        }
        return value switch
        {
            8 => "KEY_BACKSPACE",
            9 => "KEY_TAB",
            13 => "KEY_ENTER",
            16 => "KEY_LEFTSHIFT",
            17 => "KEY_LEFTCTRL",
            18 => "KEY_LEFTALT",
            20 => "KEY_CAPSLOCK",
            27 => "KEY_ESC",
            32 => "KEY_SPACE",
            33 => "KEY_PAGEUP",
            34 => "KEY_PAGEDOWN",
            35 => "KEY_END",
            36 => "KEY_HOME",
            37 => "KEY_LEFT",
            38 => "KEY_UP",
            39 => "KEY_RIGHT",
            40 => "KEY_DOWN",
            45 => "KEY_INSERT",
            46 => "KEY_DELETE",
            91 => "KEY_LEFTMETA",
            92 => "KEY_RIGHTMETA",
            186 => "KEY_SEMICOLON",
            187 => "KEY_EQUAL",
            188 => "KEY_COMMA",
            189 => "KEY_MINUS",
            190 => "KEY_DOT",
            191 => "KEY_SLASH",
            192 => "KEY_GRAVE",
            219 => "KEY_LEFTBRACE",
            220 => "KEY_BACKSLASH",
            221 => "KEY_RIGHTBRACE",
            222 => "KEY_APOSTROPHE",
            _ => null,
        };
    }

    private async void FilesPane_FilesDropped(object? sender, DragEventArgs e)
    {
        if (e.DataView.Contains(FilesPaneView.OutboundDocumentDragFormat))
        {
            return;
        }
        if (!e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            ShowInfo("Drop a PDF or EPUB file here.");
            return;
        }

        var destinationFolderId = _currentFolderId;
        IReadOnlyList<IStorageItem> storageItems;
        try
        {
            storageItems = await e.DataView.GetStorageItemsAsync();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or
            System.Runtime.InteropServices.COMException)
        {
            ShowInfo("Windows couldn’t read those dropped files.", InfoBarSeverity.Error);
            return;
        }
        var compatibleFiles = storageItems
            .OfType<StorageFile>()
            .Where(item => item.FileType.Equals(".pdf", StringComparison.OrdinalIgnoreCase) ||
                           item.FileType.Equals(".epub", StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (compatibleFiles.Length == 0)
        {
            ShowInfo("No compatible PDF or EPUB files were found.");
            return;
        }

        var routeGeneration = BeginFilesOperation();
        if (routeGeneration is null)
        {
            ShowInfo("Connect your reMarkable before sending files.");
            return;
        }

        var sent = 0;
        try
        {
            foreach (var file in compatibleFiles)
            {
                if (!IsCurrentGeneration(routeGeneration))
                {
                    break;
                }

                var transfer = new TransferItem(file.Name, "Sending…", file.Path);
                Transfers.Insert(0, transfer);
                UpdateTransferCount();
                try
                {
                    if (string.IsNullOrWhiteSpace(file.Path))
                    {
                        throw new FileTransferException(
                            FileTransferFailure.LocalFile,
                            "Windows did not provide a readable path for this file.");
                    }

                    await routeGeneration.FileTransport.UploadAsync(
                        file.Path,
                        destinationFolderId,
                        routeGeneration.CancellationToken);
                    if (!IsCurrentGeneration(routeGeneration))
                    {
                        break;
                    }
                    transfer.State = "Sent";
                    sent++;
                }
                catch (OperationCanceledException) when (
                    routeGeneration.CancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (FileTransferException exception)
                {
                    if (!IsCurrentGeneration(routeGeneration))
                    {
                        break;
                    }
                    transfer.State = exception.Failure is FileTransferFailure.AmbiguousResult
                        ? "Check tablet, then refresh"
                        : "Couldn’t send";
                    var status = exception.StatusCode is { } statusCode
                        ? $" http={(int)statusCode}"
                        : string.Empty;
                    _diagnostics.Record(
                        "files upload failure",
                        $"failure={exception.Failure}{status}");
                    ShowInfo(exception.Message, InfoBarSeverity.Error);
                }
            }
        }
        finally
        {
            EndFilesOperation(routeGeneration);
        }

        UpdateTransferCount();
        if (sent > 0 && IsCurrentGeneration(routeGeneration))
        {
            ShowInfo(
                $"Sent {sent} file{(sent == 1 ? string.Empty : "s")} to your reMarkable.",
                InfoBarSeverity.Success);
            await RefreshLibraryAsync();
        }
    }

    private void UpdateTransferCount()
    {
        _filesPaneState.RefreshTransferSummary();
    }

    private void ShowInfo(string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        var (background, border, foreground, glyph, duration) = severity switch
        {
            InfoBarSeverity.Success => (
                Windows.UI.Color.FromArgb(255, 231, 244, 235),
                Windows.UI.Color.FromArgb(255, 185, 219, 196),
                Windows.UI.Color.FromArgb(255, 22, 92, 50),
                "\uE73E",
                TimeSpan.FromSeconds(3)),
            InfoBarSeverity.Warning => (
                Windows.UI.Color.FromArgb(255, 255, 244, 215),
                Windows.UI.Color.FromArgb(255, 232, 204, 137),
                Windows.UI.Color.FromArgb(255, 112, 79, 0),
                "\uE7BA",
                TimeSpan.FromSeconds(4)),
            InfoBarSeverity.Error => (
                Windows.UI.Color.FromArgb(255, 253, 232, 231),
                Windows.UI.Color.FromArgb(255, 231, 181, 178),
                Windows.UI.Color.FromArgb(255, 143, 29, 24),
                "\uEA39",
                TimeSpan.FromSeconds(5)),
            _ => (
                Windows.UI.Color.FromArgb(255, 248, 247, 243),
                Windows.UI.Color.FromArgb(255, 215, 213, 206),
                Windows.UI.Color.FromArgb(255, 32, 33, 36),
                "\uE946",
                TimeSpan.FromSeconds(3.5)),
        };

        _toastTimer.Stop();
        ActionToastText.Text = message;
        ActionToastIcon.Glyph = glyph;
        ActionToastIcon.Foreground = new SolidColorBrush(foreground);
        ActionToast.Background = new SolidColorBrush(background);
        ActionToast.BorderBrush = new SolidColorBrush(border);
        ActionToast.Visibility = Visibility.Visible;
        _toastTimer.Interval = duration;
        _toastTimer.Start();
    }

    private sealed record StartupRouteConfiguration(
        SshRoute UsbRoute,
        SshRoute? WifiRoute,
        DeviceProfile? Profile,
        DeviceProfileLoadStatus ProfileStatus,
        bool WifiRequiresProfileMatch);

    private readonly record struct InputSessionRemovalResult(
        bool Removed,
        bool RestoreConfirmed)
    {
        public static InputSessionRemovalResult NotRemoved(bool restoreConfirmed) =>
            new(Removed: false, RestoreConfirmed: restoreConfirmed);
    }

    private readonly record struct InputFailureRemovalResult(
        bool Removed,
        MirrorInputRecoveryDisposition RecoveryDisposition)
    {
        public bool AutomaticRecoveryScheduled =>
            RecoveryDisposition is not MirrorInputRecoveryDisposition.None;
    }

    private enum RouteTransitionResult
    {
        Unchanged,
        Changed,
        Deferred,
    }
}

public enum MirrorConnectionState
{
    Waiting,
    WakeAndUnlock,
    AwaitingUnlock,
    Sleeping,
    Waking,
    Starting,
    WakeSetupRequired,
    Preparing,
    Live,
    Error,
}

public enum RemoteInputMode
{
    Touch,
    Pen,
}

public sealed class TransferItem : INotifyPropertyChanged
{
    private string _state;

    public TransferItem(string name, string state, string path)
    {
        Name = name;
        _state = state;
        Path = path;
    }

    public string Name { get; set; }

    public string State
    {
        get => _state;
        set
        {
            if (_state == value)
            {
                return;
            }

            _state = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(State)));
        }
    }

    public string Path { get; set; }

    public event PropertyChangedEventHandler? PropertyChanged;
}
