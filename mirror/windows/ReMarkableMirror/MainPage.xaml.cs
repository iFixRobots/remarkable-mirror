using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Composition;
using Microsoft.UI.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
    private static readonly TimeSpan InputHeartbeatInterval = TimeSpan.FromSeconds(3);

    private const int FilesPaneWidth = 320;
    private const double FilesPaneOpenDurationSeconds = 0.250;
    private const double FilesPaneCloseDurationSeconds = 0.167;
    private const float StageCornerRadius = 24;
    private static readonly TimeSpan ManualConnectionAttemptLimit = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan ManualWifiRepairConfirmationDelay =
        TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan CompletedDocumentDragRetention = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan StaleDocumentDragRetention = TimeSpan.FromDays(1);
    private const int ClipboardCannotOpenHResult = unchecked((int)0x800401D0);
    private StartupRouteConfiguration _startupRoutes = ResolveStartupRoutes();
    private readonly TabletSetupCoordinator _tabletSetup = new();
    private readonly MirrorDiagnostics _diagnostics = new();
    private readonly InputPublicationGate _inputPublication = new();
    private readonly WriteableBitmap _displayBitmap = new(
        SshFrameSource.FrameWidth,
        SshFrameSource.FrameHeight);
    private readonly byte[] _latestFrame = new byte[SshFrameSource.FrameBytes];
    private readonly Stream _displayPixelStream;
    private readonly DispatcherQueueTimer _toastTimer;
    private readonly SemaphoreSlim _frameRetrySignal = new(0, 1);
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _connectionAttemptGate = new(1, 1);
    private readonly SemaphoreSlim _routeLifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _inputLifecycleGate = new(1, 1);
    private readonly object _routeAdmissionGate = new();
    private TaskCompletionSource<bool> _displayPreparation = CreatePreparation();
    private TaskCompletionSource<bool> _inputPreparation = CreatePreparation();
    private CancellationTokenSource? _connectionCancellation;
    private CancellationTokenSource? _connectionAttemptCancellation;
    private CancellationTokenSource? _tabletSetupCancellation;
    private Task? _connectionAttemptTask;
    private Task? _tabletSetupTask;
    private Task? _frameDisplayTask;
    private Task? _inputSessionTask;
    private volatile SshInputSession? _inputSession;
    private MirrorRouteGeneration? _routeGeneration;
    private long _nextRouteGeneration;
    private long _nextConnectionAttempt;
    private long _activeConnectionAttempt;
    private long _retiringRouteGeneration;
    private long _inputSessionGeneration;
    private bool _haveFrame;
    private volatile MirrorConnectionState _mirrorState = MirrorConnectionState.Waiting;
    private string _connectionDetail = string.Empty;
    private bool _tabletSetupForceRepair;
    private volatile bool _pageIsLoaded;
    private RemoteInputMode _inputMode = RemoteInputMode.Touch;
    private uint? _activePointerId;
    private bool _activePenEraser;
    private long _lastPointerMoveTimestamp;
    private long _lastInputActivityTimestamp = Stopwatch.GetTimestamp();
    private long _lastInputHeartbeatTimestamp = Stopwatch.GetTimestamp();
    private volatile bool _inputRetryLatched;
    private volatile bool _inputRestoreUncertain;
    private readonly Stack<(string? Id, string Name)> _folderHistory = new();
    private string? _currentFolderId;
    private string _currentFolderName = "My files";
    private int _libraryRefreshGeneration;
    private readonly SemaphoreSlim _exportGate = new(1, 1);
    private long _filesReadyGeneration;
    private long _filesProbeGeneration;
    private CompositionRoundedRectangleGeometry? _stageClipGeometry;
    private CompositionRoundedRectangleGeometry? _stageOutlineGeometry;
    private ShapeVisual? _stageOutlineVisual;
    private TaskCompletionSource? _filesPaneTransitionCompletion;
    private double _filesPaneProgress;
    private bool _filesPaneRenderingSubscribed;
    private volatile bool _filesPaneOpen;
    private volatile bool _filesPaneDesiredOpen;
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
                DeviceProfileLoadStatus.Unavailable);
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
                loadResult.Status);
        }

        if (!profile.HasWifiPairing)
        {
            // A USB-only profile is ready with no stored Wi-Fi route. The
            // manual Wi-Fi action still works from its typed address.
            return new StartupRouteConfiguration(
                usbRoute,
                null,
                profile,
                loadResult.Status);
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
                loadResult.Status);
        }
        catch (ArgumentException)
        {
            return new StartupRouteConfiguration(
                usbRoute,
                null,
                null,
                DeviceProfileLoadStatus.Corrupt);
        }
    }

    private bool IsTabletSetupComplete() =>
        _startupRoutes.Profile is not null;

    private static string TabletSetupMarkerPath =>
        Path.Combine(MirrorApplicationData.LocalFolder.Path, "tablet-setup-complete");

    private static bool HasFinishedTabletSetup() =>
        File.Exists(TabletSetupMarkerPath);

    private static void RememberFinishedTabletSetup()
    {
        try
        {
            File.WriteAllText(TabletSetupMarkerPath, string.Empty);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
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
            _haveFrame = false;
            _inputPublication.Reset();
            ResetInputRetryPolicy();
            Interlocked.Exchange(ref _activeConnectionAttempt, 0);
            _startupRoutes = ResolveStartupRoutes();
            var setupComplete = IsTabletSetupComplete() && HasFinishedTabletSetup();
            _tabletSetupForceRepair = false;
            SetMirrorState(
                setupComplete
                    ? MirrorConnectionState.Waiting
                    : MirrorConnectionState.SetupRequired);

            var cancellation = new CancellationTokenSource();
            _connectionCancellation = cancellation;
            _diagnostics.Record("lifecycle", "Mirror window opened");
            _diagnostics.Record(
                "wifi profile",
                _startupRoutes.WifiRoute is not null
                    ? "Ready"
                    : _startupRoutes.Profile is not null
                        ? "USB-only profile, no stored Wi-Fi route"
                        : $"Unavailable ({_startupRoutes.ProfileStatus})");
            _diagnostics.Record(
                "connection",
                setupComplete
                    ? "Waiting for owner connection choice"
                    : "Waiting for owner setup request");
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
        _tabletSetupCancellation?.Cancel();
        if (_tabletSetupTask is { } tabletSetupTask)
        {
            try
            {
                await tabletSetupTask;
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception exception)
            {
                _diagnostics.Record("shutdown", $"Tablet setup: {exception.GetType().Name}");
            }
        }
        await _lifecycleGate.WaitAsync();
        try
        {
            var cancellation = _connectionCancellation;
            if (cancellation is null)
            {
                return;
            }

            var connectionAttemptCancellation = _connectionAttemptCancellation;
            var connectionAttemptTask = _connectionAttemptTask;
            var frameTask = _frameDisplayTask;
            var inputTask = _inputSessionTask;
            var generation = Interlocked.Exchange(ref _routeGeneration, null);
            generation?.Cancel();
            Interlocked.Exchange(ref _activeConnectionAttempt, 0);
            connectionAttemptCancellation?.Cancel();
            cancellation.Cancel();
            SignalFrameRetry();
            try
            {
                await AwaitWorkerShutdownAsync(
                    connectionAttemptTask,
                    frameTask,
                    inputTask);
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
                connectionAttemptCancellation?.Dispose();
                _connectionCancellation = null;
                _connectionAttemptCancellation = null;
                _connectionAttemptTask = null;
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

    private async Task<RouteTransitionOutcome> TransitionRouteAsync(
        SshRoute? nextRoute,
        DeviceRouteKind? nextKind,
        CancellationToken applicationCancellationToken,
        MirrorRouteGeneration? expectedCurrent = null,
        Func<bool>? transitionAllowed = null)
    {
        await _routeLifecycleGate.WaitAsync(applicationCancellationToken).ConfigureAwait(false);
        try
        {
            MirrorRouteGeneration? current;
            var deferCancellationForInputCleanup = false;
            lock (_routeAdmissionGate)
            {
                current = Volatile.Read(ref _routeGeneration);
                if (expectedCurrent is not null &&
                    !ReferenceEquals(current, expectedCurrent))
                {
                    return RouteTransitionOutcome.Unchanged;
                }
                if (transitionAllowed is not null && !transitionAllowed())
                {
                    return RouteTransitionOutcome.Unchanged;
                }
                if (current is not null &&
                    nextRoute is not null &&
                    nextKind == current.Kind &&
                    ReferenceEquals(nextRoute, current.Route) &&
                    !current.CancellationToken.IsCancellationRequested)
                {
                    return RouteTransitionOutcome.Unchanged;
                }
                if (current is null && nextRoute is null)
                {
                    return RouteTransitionOutcome.Unchanged;
                }
                _inputRetryLatched = true;
                current = Interlocked.Exchange(ref _routeGeneration, null);
                if (current is not null)
                {
                    _inputPublication.Complete(current.Id);
                }
                _filesReadyGeneration = 0;
                deferCancellationForInputCleanup =
                    current is not null &&
                    Interlocked.Read(ref _inputSessionGeneration) == current.Id;
                if (!deferCancellationForInputCleanup)
                {
                    current?.Cancel();
                }
            }
            Interlocked.Increment(ref _libraryRefreshGeneration);
            SignalFrameRetry();

            var inputRemoval = InputSessionRemovalResult.NotRemoved(
                restoreConfirmed: !_inputRestoreUncertain);
            await _inputLifecycleGate.WaitAsync().ConfigureAwait(false);
            try
            {
                _activePointerId = null;
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
                if (deferCancellationForInputCleanup)
                {
                    current?.Cancel();
                }
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
                        },
                        applicationCancellationToken).ConfigureAwait(false);
                }

                applicationCancellationToken.ThrowIfCancellationRequested();
                if (nextRoute is null || nextKind is null)
                {
                    _haveFrame = false;
                    return RouteTransitionOutcome.Retired;
                }
                if (!inputRemoval.RestoreConfirmed || _inputRestoreUncertain)
                {
                    return RouteTransitionOutcome.Unchanged;
                }

                var next = new MirrorRouteGeneration(
                    Interlocked.Increment(ref _nextRouteGeneration),
                    nextKind.Value,
                    nextRoute,
                    applicationCancellationToken);
                _inputPublication.Begin(next.Id);
                var published = false;
                lock (_routeAdmissionGate)
                {
                    if (transitionAllowed is null || transitionAllowed())
                    {
                        Volatile.Write(ref _routeGeneration, next);
                        published = true;
                    }
                }
                if (!published)
                {
                    _inputPublication.Complete(next.Id);
                    await next.DisposeAsync().ConfigureAwait(false);
                    return RouteTransitionOutcome.Unchanged;
                }
                _haveFrame = false;
                _diagnostics.Record(
                    "route",
                    next.Kind is DeviceRouteKind.Usb ? "USB selected" : "Wi-Fi selected");
                SignalFrameRetry();
                return RouteTransitionOutcome.Published(next);
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
        catch (Exception exception)
        {
            _diagnostics.Record("route cleanup", exception.GetType().Name);
        }
    }

    private bool IsCurrentConnectionAttempt(long attemptId) =>
        attemptId != 0 &&
        Interlocked.Read(ref _activeConnectionAttempt) == attemptId &&
        _pageIsLoaded;

    private async Task StartManualConnectionAsync(ManualConnectionRequest request)
    {
        var applicationCancellation = _connectionCancellation;
        if (!_pageIsLoaded || applicationCancellation is null)
        {
            return;
        }
        if (_inputRestoreUncertain)
        {
            ShowInfo(
                "Restart tablet and Mirror.",
                InfoBarSeverity.Warning);
            return;
        }

        Task? attemptTask = null;
        CancellationTokenSource? attemptCancellation = null;
        long attemptId = 0;
        await _connectionAttemptGate.WaitAsync();
        try
        {
            if (!_pageIsLoaded ||
                applicationCancellation.IsCancellationRequested ||
                !ReferenceEquals(_connectionCancellation, applicationCancellation))
            {
                return;
            }
            if (_connectionAttemptTask is { IsCompleted: false })
            {
                ShowInfo(
                    "A connection attempt is already in progress.",
                    InfoBarSeverity.Informational);
                return;
            }

            attemptId = Interlocked.Increment(ref _nextConnectionAttempt);
            Interlocked.Exchange(ref _activeConnectionAttempt, attemptId);
            attemptCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                applicationCancellation.Token);
            attemptCancellation.CancelAfter(ManualConnectionAttemptLimit);
            SetMirrorState(
                MirrorConnectionState.Preparing,
                request.Kind is DeviceRouteKind.Usb
                    ? "Checking only the USB-C connection you selected."
                    : "Checking only the Wi-Fi address you entered.");
            attemptTask = RunManualConnectionAttemptAsync(
                request,
                attemptId,
                attemptCancellation.Token,
                applicationCancellation.Token);
            _connectionAttemptCancellation = attemptCancellation;
            _connectionAttemptTask = attemptTask;
        }
        finally
        {
            _connectionAttemptGate.Release();
        }

        if (attemptTask is null || attemptCancellation is null)
        {
            return;
        }

        try
        {
            await attemptTask;
        }
        catch (OperationCanceledException) when (
            attemptCancellation.IsCancellationRequested &&
            !applicationCancellation.IsCancellationRequested)
        {
            if (IsCurrentConnectionAttempt(attemptId))
            {
                SetMirrorState(
                    MirrorConnectionState.Error,
                    request.Kind is DeviceRouteKind.Usb
                        ? "Couldn’t connect over USB-C. Check the cable and tablet, then choose Connect USB-C to try again."
                        : "Couldn’t connect over Wi-Fi. Check the tablet and network, then choose Connect Wi-Fi to try again.");
            }
        }
        catch (OperationCanceledException) when (applicationCancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _diagnostics.Record("connection attempt", exception.GetType().Name);
            if (IsCurrentConnectionAttempt(attemptId))
            {
                SetMirrorState(
                    MirrorConnectionState.Error,
                    "Mirror couldn’t finish that connection attempt. Copy the connection details, then choose USB-C or Wi-Fi to try again.");
            }
        }
        finally
        {
            await _connectionAttemptGate.WaitAsync();
            try
            {
                if (ReferenceEquals(_connectionAttemptTask, attemptTask))
                {
                    _connectionAttemptTask = null;
                    _connectionAttemptCancellation = null;
                    Interlocked.CompareExchange(ref _activeConnectionAttempt, 0, attemptId);
                }
            }
            finally
            {
                _connectionAttemptGate.Release();
                attemptCancellation.Dispose();
            }
        }
    }

    private async Task RunManualConnectionAttemptAsync(
        ManualConnectionRequest request,
        long attemptId,
        CancellationToken attemptCancellationToken,
        CancellationToken applicationCancellationToken)
    {
        await TransitionRouteAsync(
                null,
                null,
                applicationCancellationToken,
                transitionAllowed: () =>
                    IsCurrentConnectionAttempt(attemptId) &&
                    !attemptCancellationToken.IsCancellationRequested)
            .ConfigureAwait(false);
        if (!IsCurrentConnectionAttempt(attemptId) ||
            attemptCancellationToken.IsCancellationRequested)
        {
            attemptCancellationToken.ThrowIfCancellationRequested();
            return;
        }

        _diagnostics.Record(
            "action",
            request.Kind is DeviceRouteKind.Usb
                ? "Manual USB-C connection requested"
                : "Manual Wi-Fi connection requested");

        using var monitor = request.Kind is DeviceRouteKind.Usb
            ? DeviceConnectionMonitor.ForUsb(
                _startupRoutes.UsbRoute,
                _startupRoutes.Profile)
            : DeviceConnectionMonitor.ForWifi(
                request.Route,
                _startupRoutes.Profile);

        var wifiProbeCount = 0;
        DeviceConnectionStatus? lastPublishedStatus = null;
        var lastObservedStatus = DeviceConnectionStatus.Disconnected;
        var lastObservedDetail = PassiveRouteProbeDetail.None;
        await foreach (var state in monitor
            .WatchAsync(attemptCancellationToken)
            .ConfigureAwait(false))
        {
            if (request.Kind is DeviceRouteKind.Wifi)
            {
                wifiProbeCount++;
            }
            if (!IsCurrentConnectionAttempt(attemptId))
            {
                return;
            }

            if (lastObservedStatus != state.Status)
            {
                _diagnostics.Record("connection", state.Status.ToString());
            }
            if (state.ProbeDetail is not PassiveRouteProbeDetail.None &&
                (lastObservedStatus != state.Status || lastObservedDetail != state.ProbeDetail))
            {
                _diagnostics.Record("connection detail", state.ProbeDetail.ToString());
            }
            lastObservedStatus = state.Status;
            lastObservedDetail = state.ProbeDetail;
            if (state.IsSshReady &&
                state.SelectedRoute is not null &&
                state.RouteKind == request.Kind)
            {
                var transition = await TransitionRouteAsync(
                        state.SelectedRoute,
                        state.RouteKind,
                        applicationCancellationToken,
                        transitionAllowed: () =>
                            IsCurrentConnectionAttempt(attemptId) &&
                            !attemptCancellationToken.IsCancellationRequested)
                    .ConfigureAwait(false);
                var publishedGeneration = transition.PublishedGeneration;
                if (publishedGeneration is null)
                {
                    attemptCancellationToken.ThrowIfCancellationRequested();
                    if (IsCurrentConnectionAttempt(attemptId))
                    {
                        await RunOnUIThreadAsync(
                            () => SetMirrorState(
                                MirrorConnectionState.Error,
                                _inputRestoreUncertain
                                    ? "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again."
                                    : "Mirror couldn’t start the selected connection. Choose USB-C or Wi-Fi to try again."),
                            applicationCancellationToken).ConfigureAwait(false);
                    }
                    return;
                }
                if (attemptCancellationToken.IsCancellationRequested ||
                    !IsCurrentConnectionAttempt(attemptId))
                {
                    await TransitionRouteAsync(
                            null,
                            null,
                            applicationCancellationToken,
                            expectedCurrent: publishedGeneration)
                        .ConfigureAwait(false);
                    attemptCancellationToken.ThrowIfCancellationRequested();
                }
                else if (request.Kind is DeviceRouteKind.Wifi)
                {
                    // A first Wi-Fi connect may have just recorded its pairing
                    // into the stored profile; later attempts must see it
                    // instead of this session's stale USB-only profile.
                    await RunOnUIThreadAsync(
                            () => _startupRoutes = ResolveStartupRoutes(),
                            applicationCancellationToken)
                        .ConfigureAwait(false);
                }
                return;
            }

            if (lastPublishedStatus != state.Status)
            {
                await PublishManualConnectionObservationAsync(
                        state,
                        request.Kind,
                        applicationCancellationToken)
                    .ConfigureAwait(false);
                lastPublishedStatus = state.Status;
            }

            if (request.Kind is DeviceRouteKind.Wifi)
            {
                if (wifiProbeCount == 1 &&
                    state.Status is DeviceConnectionStatus.Disconnected &&
                    state.ProbeDetail is PassiveRouteProbeDetail.TabletPrerequisiteMismatch)
                {
                    await Task.Delay(
                            ManualWifiRepairConfirmationDelay,
                            attemptCancellationToken)
                        .ConfigureAwait(false);
                    monitor.RequestProbe();
                    continue;
                }

                await RunOnUIThreadAsync(
                    () => SetMirrorState(
                        MirrorConnectionState.Error,
                        ManualConnectionFailureMessage(request.Kind, state.Status)),
                    applicationCancellationToken).ConfigureAwait(false);
                return;
            }

            if (state.Status is DeviceConnectionStatus.WakeSetupRequired)
            {
                return;
            }
        }

        attemptCancellationToken.ThrowIfCancellationRequested();
    }

    private Task PublishManualConnectionObservationAsync(
        DeviceConnectionState state,
        DeviceRouteKind routeKind,
        CancellationToken cancellationToken) =>
        RunOnUIThreadAsync(
            () =>
            {
                switch (state.Status)
                {
                    case DeviceConnectionStatus.Disconnected:
                        SetMirrorState(
                            MirrorConnectionState.Preparing,
                            routeKind is DeviceRouteKind.Usb
                                ? "Waiting for the USB-C connection you selected."
                                : "Waiting for the Wi-Fi address you entered.");
                        break;
                    case DeviceConnectionStatus.PortOpenWithoutSshBanner:
                        if (routeKind is DeviceRouteKind.Usb)
                        {
                            SetMirrorState(MirrorConnectionState.WakeAndUnlock);
                        }
                        else
                        {
                            SetMirrorState(
                                MirrorConnectionState.Error,
                                ManualConnectionFailureMessage(routeKind, state.Status));
                        }
                        break;
                    case DeviceConnectionStatus.UnlockRequired:
                        SetMirrorState(MirrorConnectionState.AwaitingUnlock);
                        break;
                    case DeviceConnectionStatus.Sleeping:
                        SetMirrorState(MirrorConnectionState.Sleeping);
                        break;
                    case DeviceConnectionStatus.Waking:
                        SetMirrorState(MirrorConnectionState.Waking);
                        break;
                    case DeviceConnectionStatus.Starting:
                        SetMirrorState(MirrorConnectionState.Starting);
                        break;
                    case DeviceConnectionStatus.WakeSetupRequired:
                        SetMirrorState(MirrorConnectionState.WakeSetupRequired);
                        break;
                    case DeviceConnectionStatus.WifiNetworkMismatch:
                        SetMirrorState(
                            MirrorConnectionState.Error,
                            ManualConnectionFailureMessage(
                                DeviceRouteKind.Wifi,
                                state.Status));
                        break;
                    case DeviceConnectionStatus.SshReady:
                        SetMirrorState(MirrorConnectionState.Preparing);
                        break;
                }
            },
            cancellationToken);

    private static string ManualConnectionFailureMessage(
        DeviceRouteKind routeKind,
        DeviceConnectionStatus status) => status switch
        {
            DeviceConnectionStatus.WifiNetworkMismatch =>
                "Connect this PC to the Wi-Fi network paired with this reMarkable, then choose Connect Wi-Fi again.",
            DeviceConnectionStatus.WakeSetupRequired =>
                "Mirror cannot use its tablet setup. Choose Repair Tablet Setup with the tablet connected by USB-C.",
            _ when routeKind is DeviceRouteKind.Usb =>
                "Couldn’t connect over USB-C. Check the cable and tablet, then choose Connect USB-C to try again.",
            _ =>
                "Couldn’t connect to that Wi-Fi address. Check the tablet and network, then choose Connect Wi-Fi to try again.",
        };

    private async Task DisplayFramesAsync(CancellationToken cancellationToken)
    {
        await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);

        while (!cancellationToken.IsCancellationRequested)
        {
            var generation = Volatile.Read(ref _routeGeneration);
            if (generation is null)
            {
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
                    await HandleFrameFailureAsync(
                            exception,
                            generation,
                            cancellationToken)
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
                await HandleFrameFailureAsync(
                        exception,
                        generation,
                        cancellationToken)
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
                    }
                    await RunOnUIThreadAsync(
                        () =>
                        {
                            if (!IsCurrentGeneration(generation))
                            {
                                return;
                            }
                            ApplyFrameUpdate(update);
                            SetLiveState(generation);
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
                    "The secure connection opened, but the tablet display did not start.",
                    isTransient: true);
            }
            catch (FrameStreamException exception)
            {
                failure = exception;
            }

            if (failure is null)
            {
                if (!IsCurrentGeneration(generation))
                {
                    await WaitForFrameRetryAsync(Timeout.InfiniteTimeSpan, cancellationToken)
                        .ConfigureAwait(false);
                    continue;
                }

                failure = new FrameStreamException(
                    FrameStreamFailureKind.StreamInterrupted,
                    "The tablet display connection stopped.",
                    isTransient: true);
            }

            if (!IsCurrentGeneration(generation) ||
                !ReferenceEquals(displayPreparation, Volatile.Read(ref _displayPreparation)) ||
                !ReferenceEquals(inputPreparation, Volatile.Read(ref _inputPreparation)))
            {
                continue;
            }

            await HandleFrameFailureAsync(
                    failure,
                    generation,
                    cancellationToken)
                .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (
                routeToken.IsCancellationRequested &&
                !cancellationToken.IsCancellationRequested)
            {
            }
        }
    }

    private async Task HandleFrameFailureAsync(
        FrameStreamException failure,
        MirrorRouteGeneration generation,
        CancellationToken cancellationToken)
    {
        if (!IsCurrentGeneration(generation))
        {
            return;
        }
        var diagnostic = string.IsNullOrWhiteSpace(failure.TechnicalDetail)
            ? $"{failure.Kind}: {failure.Message}"
            : $"{failure.Kind}: {failure.TechnicalDetail}";
        _diagnostics.Record("mirror failure", diagnostic);
        var hadFrame = _haveFrame;
        // A session that was live and lost its route ended; it did not fail
        // to open. Present it calmly and say which route to re-choose.
        var endedAfterLive = failure.IsTransient && hadFrame;
        var message = failure.IsTransient
            ? hadFrame
                ? generation.Kind is DeviceRouteKind.Usb
                    ? "The USB-C connection ended. Check the cable, then choose Connect USB-C to reconnect."
                    : "The Wi-Fi connection ended. Check the tablet and network, then choose Connect Wi-Fi to reconnect."
                : "Mirror couldn’t start the display on the selected connection. Choose USB-C or Wi-Fi to try again."
            : failure.Message;
        await RetireSelectedConnectionAsync(
                generation,
                endedAfterLive
                    ? MirrorConnectionState.ConnectionEnded
                    : MirrorConnectionState.Error,
                message,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task RetireSelectedConnectionAsync(
        MirrorRouteGeneration generation,
        MirrorConnectionState state,
        string message,
        CancellationToken cancellationToken)
    {
        try
        {
            if (!IsCurrentGeneration(generation))
            {
                return;
            }

            var transition = await TransitionRouteAsync(
                    null,
                    null,
                    cancellationToken,
                    expectedCurrent: generation)
                .ConfigureAwait(false);
            if (!transition.Changed)
            {
                return;
            }
            await RunOnUIThreadAsync(
                () =>
                {
                    if (cancellationToken.IsCancellationRequested ||
                        !_pageIsLoaded ||
                        _connectionCancellation is null ||
                        _connectionCancellation.Token != cancellationToken ||
                        Volatile.Read(ref _routeGeneration) is not null)
                    {
                        return;
                    }
                    _haveFrame = false;
                    SetInputAvailability(false);
                    SetMirrorState(
                        _inputRestoreUncertain ? MirrorConnectionState.Error : state,
                        _inputRestoreUncertain
                            ? "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again."
                            : message);
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private void ApplyFrameUpdate(FrameUpdate update)
    {
        if (update.IsFull &&
            update.X == 0 &&
            update.Y == 0 &&
            update.Width == SshFrameSource.FrameWidth &&
            update.Height == SshFrameSource.FrameHeight &&
            update.PayloadBytes == _latestFrame.Length)
        {
            update.Payload.CopyTo(_latestFrame);
            _displayPixelStream.Position = 0;
            _displayPixelStream.Write(update.Payload);
        }
        else
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
        }

        _displayBitmap.Invalidate();
        _haveFrame = true;
    }

    private void SetMirrorState(MirrorConnectionState state, string? detail = null)
    {
        var previousState = _mirrorState;
        var previousDetail = _connectionDetail;
        var (connection, title, body, color, showProgress, showChoices, showDetails) = state switch
        {
            MirrorConnectionState.SetupRequired => (
                "Setup",
                "Set up your reMarkable",
                detail ?? "Mirror will install its tablet components and authorize this computer over the direct USB-C cable.",
                Windows.UI.Color.FromArgb(255, 137, 145, 158),
                false,
                false,
                false),
            MirrorConnectionState.SetupInProgress => (
                _tabletSetupForceRepair ? "Repair" : "Setup",
                _tabletSetupForceRepair
                    ? "Repairing tablet setup"
                    : "Setting up your reMarkable",
                detail ?? "Checking the direct USB-C connection.",
                Windows.UI.Color.FromArgb(255, 226, 163, 58),
                true,
                false,
                false),
            MirrorConnectionState.SetupPasswordRequired => (
                "Setup",
                "Authorize this computer",
                detail ?? "Enter the one-time Developer Mode password shown on your tablet.",
                Windows.UI.Color.FromArgb(255, 137, 145, 158),
                false,
                false,
                false),
            MirrorConnectionState.SetupNeedsAttention => (
                "Setup",
                "Setup needs attention",
                detail ?? "Check the tablet and direct USB-C cable, then try again.",
                Windows.UI.Color.FromArgb(255, 224, 92, 92),
                false,
                false,
                false),
            MirrorConnectionState.Preparing => (
                "Connecting",
                "Preparing your reMarkable",
                detail ?? "Starting the tablet display and controls for this connection.",
                Windows.UI.Color.FromArgb(255, 226, 163, 58),
                true,
                false,
                false),
            MirrorConnectionState.Live => (
                "Live",
                string.Empty,
                string.Empty,
                Windows.UI.Color.FromArgb(255, 59, 186, 118),
                false,
                false,
                false),
            MirrorConnectionState.Error => (
                "Attention",
                "Couldn’t open mirror",
                detail ?? "Choose USB-C or Wi-Fi to start another connection attempt.",
                Windows.UI.Color.FromArgb(255, 224, 92, 92),
                false,
                true,
                true),
            MirrorConnectionState.ConnectionEnded => (
                "Offline",
                "Connection ended",
                detail ?? "Choose USB-C or Wi-Fi to connect again.",
                Windows.UI.Color.FromArgb(255, 137, 145, 158),
                false,
                true,
                true),
            MirrorConnectionState.AwaitingUnlock => (
                "Unlock",
                "Unlock your reMarkable",
                "Wake it if needed and enter your passcode. This USB-C attempt will continue until its time limit.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                true,
                false,
                false),
            MirrorConnectionState.WakeAndUnlock => (
                "Waiting",
                "Wake and unlock your reMarkable",
                "Press the power button once and enter your passcode. This USB-C attempt will keep checking the selected cable.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                true,
                false,
                false),
            MirrorConnectionState.Sleeping => (
                "Sleeping",
                "Waking the display",
                "The selected USB-C attempt is waking the tablet.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                true,
                false,
                false),
            MirrorConnectionState.Waking => (
                "Waking",
                "Waking the display",
                "The selected USB-C attempt is waiting for the tablet to wake.",
                Windows.UI.Color.FromArgb(255, 226, 163, 58),
                true,
                false,
                false),
            MirrorConnectionState.Starting => (
                "Starting",
                "Your reMarkable is finishing startup",
                "The selected USB-C attempt is waiting for tablet services.",
                Windows.UI.Color.FromArgb(255, 112, 118, 128),
                true,
                false,
                false),
            MirrorConnectionState.WakeSetupRequired => (
                "Repair",
                "Repair tablet setup",
                "Mirror cannot use its tablet wake setup. Keep the tablet connected, awake and unlocked, then repair it here.",
                Windows.UI.Color.FromArgb(255, 224, 92, 92),
                false,
                false,
                false),
            _ => (
                "Offline",
                "Connect to your reMarkable",
                "Choose USB-C or Wi-Fi. Mirror connects only after you select a connection.",
                Windows.UI.Color.FromArgb(255, 137, 145, 158),
                false,
                true,
                false),
        };

        var showTabletSetup = state is
            MirrorConnectionState.SetupRequired or
            MirrorConnectionState.SetupInProgress or
            MirrorConnectionState.SetupPasswordRequired or
            MirrorConnectionState.SetupNeedsAttention or
            MirrorConnectionState.WakeSetupRequired;
        ConfigureTabletSetupPanel(state);
        TabletSetupPanel.Visibility = showTabletSetup
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (previousState == state && string.Equals(previousDetail, body, StringComparison.Ordinal))
        {
            LiveFrameImage.Visibility = _haveFrame && state is MirrorConnectionState.Live
                ? Visibility.Visible
                : Visibility.Collapsed;
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
        ConnectionRouteButton.IsEnabled = state is MirrorConnectionState.Live;
        ConnectionPanelTitle.Text = title;
        ConnectionPanelDetail.Text = body;
        ConnectionProgressRing.IsActive = showProgress;
        ConnectionProgressRing.Visibility = showProgress ? Visibility.Visible : Visibility.Collapsed;
        ConnectionChoicePanel.Visibility = showChoices ? Visibility.Visible : Visibility.Collapsed;
        // Restore is not a connection choice. It is a subordinate idle action,
        // offered only when a local backup actually exists to put back; the
        // app never probes the tablet to gate it.
        RestoreBackupPanel.Visibility =
            state is MirrorConnectionState.Waiting &&
            TabletBackupService.LatestBackupFolder() is not null
                ? Visibility.Visible
                : Visibility.Collapsed;
        // The walkthrough (and its backup step) stays reachable after setup,
        // as on macOS. Opening it changes nothing until the owner starts setup.
        SetUpAgainPanel.Visibility = state is MirrorConnectionState.Waiting
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (!showChoices || previousState is MirrorConnectionState.Live)
        {
            WifiAddressPanel.Visibility = Visibility.Collapsed;
        }
        CopyConnectionDetailsButton.Visibility = showDetails ? Visibility.Visible : Visibility.Collapsed;
        ConnectionPanel.Visibility = state is MirrorConnectionState.Live
            ? Visibility.Collapsed
            : Visibility.Visible;
        // A frame only belongs to a live session; a stale frame behind any
        // other card reads as a broken mirror.
        LiveFrameImage.Visibility = _haveFrame && state is MirrorConnectionState.Live
            ? Visibility.Visible
            : Visibility.Collapsed;
        SetFileAvailability(IsFilesRouteReady());
        if (state is MirrorConnectionState.Live &&
            previousState is not MirrorConnectionState.Live &&
            !_filesPaneTransitioning &&
            _filesPaneOpen)
        {
            _ = RefreshLibraryAsync();
        }
    }

    private void ConfigureTabletSetupPanel(MirrorConnectionState state)
    {
        TabletSetupWalkthrough.Visibility = state is MirrorConnectionState.SetupRequired
            ? Visibility.Visible
            : Visibility.Collapsed;
        TabletSetupPasswordPanel.Visibility = state is MirrorConnectionState.SetupPasswordRequired
            ? Visibility.Visible
            : Visibility.Collapsed;
        TabletSetupValidationText.Text = string.Empty;
        TabletSetupValidationText.Visibility = Visibility.Collapsed;
        // A rejected tablet identity is the one attention case with a real
        // way forward: archive the old pairing and pair the new tablet.
        TabletSetupNewTabletButton.Visibility =
            state is MirrorConnectionState.SetupNeedsAttention &&
            _lastTabletSetupStatus is TabletSetupStatus.HostIdentityRejected
                ? Visibility.Visible
                : Visibility.Collapsed;

        if (state is not MirrorConnectionState.SetupPasswordRequired)
        {
            TabletSetupPasswordBox.Password = string.Empty;
        }

        TabletSetupPrimaryButton.Visibility = Visibility.Visible;
        switch (state)
        {
            case MirrorConnectionState.SetupRequired:
                TabletSetupPrimaryButton.Content = "Start Setup";
                AutomationProperties.SetName(
                    TabletSetupPrimaryButton,
                    "Start tablet setup");
                break;
            case MirrorConnectionState.SetupPasswordRequired:
                TabletSetupPrimaryButton.Content = "Authorize & Install";
                AutomationProperties.SetName(
                    TabletSetupPrimaryButton,
                    "Authorize this computer and install tablet setup");
                break;
            case MirrorConnectionState.WakeSetupRequired:
                TabletSetupPrimaryButton.Content = "Repair Tablet Setup";
                AutomationProperties.SetName(
                    TabletSetupPrimaryButton,
                    "Repair tablet setup");
                break;
            case MirrorConnectionState.SetupNeedsAttention:
                TabletSetupPrimaryButton.Content = _tabletSetupForceRepair
                    ? "Repair Tablet Setup"
                    : "Try Setup Again";
                AutomationProperties.SetName(
                    TabletSetupPrimaryButton,
                    _tabletSetupForceRepair
                        ? "Repair tablet setup"
                        : "Try tablet setup again");
                break;
            default:
                TabletSetupPrimaryButton.Visibility = Visibility.Collapsed;
                break;
        }

        if (state is MirrorConnectionState.SetupRequired)
        {
            RefreshWalkthrough();
        }
    }

    private TabletSetupStatus? _lastTabletSetupStatus;

    private async void TabletSetupNewTabletButton_Click(object sender, RoutedEventArgs e)
    {
        if (_tabletSetupTask is { IsCompleted: false })
        {
            return;
        }

        var dialog = new ContentDialog
        {
            Title = "Set up as a new tablet?",
            Content = "Mirror archives the previous pairing on this PC and starts " +
                "first-time setup for the connected tablet. The archived files " +
                "stay in your .ssh folder, and the dedicated key is kept.",
            PrimaryButtonText = "Archive & Set Up",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() is not ContentDialogResult.Primary)
        {
            return;
        }

        string archiveDirectory;
        try
        {
            archiveDirectory = RetiredPairingArchive.ArchiveCurrentPairing();
            File.Delete(TabletSetupMarkerPath);
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            System.Security.SecurityException or
            NotSupportedException or
            ArgumentException)
        {
            SetMirrorState(
                MirrorConnectionState.SetupNeedsAttention,
                "Mirror couldn’t archive the previous pairing, so nothing was changed. Close other apps using the files in your .ssh folder and try again.");
            return;
        }

        _diagnostics.Record(
            "tablet setup",
            $"previous pairing archived to {archiveDirectory}");
        _lastTabletSetupStatus = null;
        _tabletSetupForceRepair = false;
        _walkthroughStepIndex = 0;
        _walkthroughBackupFinished = false;
        _startupRoutes = ResolveStartupRoutes();
        SetMirrorState(MirrorConnectionState.SetupRequired);
    }

    private void SetUpAgainButton_Click(object sender, RoutedEventArgs e)
    {
        if (_tabletSetupTask is { IsCompleted: false })
        {
            return;
        }
        _walkthroughStepIndex = 0;
        _walkthroughBackupFinished = false;
        SetMirrorState(MirrorConnectionState.SetupRequired);
    }

    private sealed record TabletWalkthroughStep(
        string Title,
        string Message,
        string? Checklist = null);

    private static readonly TabletWalkthroughStep[] TabletWalkthroughSteps =
    [
        new(
            "Back up your tablet",
            "Mirror copies every document to this PC before the reset erases them.",
            "1. On the tablet, turn on Settings > Storage > USB web interface.\n" +
            "2. Connect the tablet to this PC with a USB-C cable.\n" +
            "3. Click Back Up Tablet."),
        new(
            "Enable Developer Mode",
            "On the tablet, open Settings > General > Software > Advanced and " +
            "turn on Developer Mode. This factory-resets the tablet."),
        new(
            "Set the tablet up again",
            "Sign in, reconnect Wi-Fi, and wait for your documents to restore. " +
            "Skip any software update it offers for now."),
        new(
            "Unlock it once",
            "After the tablet restarts, unlock it one time so USB-C data is available."),
        new(
            "Turn on the USB web interface",
            "On the tablet, turn Settings > Storage > USB web interface back on. " +
            "The reset switched it off."),
        new(
            "Find the one-time password",
            "It is shown under Settings > General > Help > About > Copyrights " +
            "and Licenses. Mirror asks for it once and never saves it."),
        new(
            "Connect USB-C",
            "Plug the tablet directly into this PC with a data-capable USB-C " +
            "cable. Wake it and unlock it, then start setup. If the tablet was " +
            "set up before, Mirror verifies it and reinstalls nothing."),
    ];

    private int _walkthroughStepIndex;
    private bool _walkthroughBackupRunning;
    private bool _walkthroughBackupFinished;

    private void RefreshWalkthrough()
    {
        var stepIndex = Math.Clamp(
            _walkthroughStepIndex,
            0,
            TabletWalkthroughSteps.Length - 1);
        _walkthroughStepIndex = stepIndex;
        var step = TabletWalkthroughSteps[stepIndex];
        var isLastStep = stepIndex == TabletWalkthroughSteps.Length - 1;
        var isBackupStep = stepIndex == 0;

        WalkthroughStepCounter.Text =
            $"Step {stepIndex + 1} of {TabletWalkthroughSteps.Length}";
        WalkthroughStepTitle.Text = step.Title;
        WalkthroughStepMessage.Text = step.Message;
        WalkthroughStepChecklist.Text = step.Checklist ?? string.Empty;
        WalkthroughStepChecklist.Visibility = step.Checklist is null
            ? Visibility.Collapsed
            : Visibility.Visible;
        WalkthroughBackupStatus.Visibility =
            isBackupStep && WalkthroughBackupStatus.Text.Length > 0
                ? Visibility.Visible
                : Visibility.Collapsed;

        WalkthroughBackButton.Visibility = stepIndex > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        WalkthroughBackButton.IsEnabled = !_walkthroughBackupRunning;
        var showBackupActions = isBackupStep && !_walkthroughBackupFinished;
        WalkthroughBackupButton.Visibility = showBackupActions
            ? Visibility.Visible
            : Visibility.Collapsed;
        WalkthroughBackupButton.IsEnabled = !_walkthroughBackupRunning;
        WalkthroughSkipBackupButton.Visibility = showBackupActions
            ? Visibility.Visible
            : Visibility.Collapsed;
        WalkthroughSkipBackupButton.IsEnabled = !_walkthroughBackupRunning;
        WalkthroughContinueButton.Visibility = !isLastStep && !showBackupActions
            ? Visibility.Visible
            : Visibility.Collapsed;
        WalkthroughSkipAheadPanel.Visibility = isLastStep
            ? Visibility.Collapsed
            : Visibility.Visible;
        WalkthroughSkipAheadButton.IsEnabled = !_walkthroughBackupRunning;

        // Start Setup belongs to the final page; earlier pages advance instead.
        TabletSetupPrimaryButton.Visibility = isLastStep
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void WalkthroughBackButton_Click(object sender, RoutedEventArgs e)
    {
        if (_walkthroughBackupRunning || _walkthroughStepIndex == 0)
        {
            return;
        }
        _walkthroughStepIndex--;
        RefreshWalkthrough();
    }

    private void WalkthroughContinueButton_Click(object sender, RoutedEventArgs e)
    {
        if (_walkthroughBackupRunning ||
            _walkthroughStepIndex >= TabletWalkthroughSteps.Length - 1)
        {
            return;
        }
        _walkthroughStepIndex++;
        RefreshWalkthrough();
    }

    private void WalkthroughSkipAheadButton_Click(object sender, RoutedEventArgs e)
    {
        if (_walkthroughBackupRunning)
        {
            return;
        }
        _walkthroughStepIndex = TabletWalkthroughSteps.Length - 1;
        RefreshWalkthrough();
    }

    private async void WalkthroughBackupButton_Click(object sender, RoutedEventArgs e)
    {
        if (_walkthroughBackupRunning)
        {
            return;
        }
        _walkthroughBackupRunning = true;
        WalkthroughBackupStatus.Text = "Checking the tablet…";
        RefreshWalkthrough();
        _diagnostics.Record("backup", "Tablet backup requested");
        try
        {
            using var backup = new TabletBackupService();
            var progress = new Progress<TabletBackupProgress>(update =>
                WalkthroughBackupStatus.Text =
                    $"Backing up {update.Completed} of {update.Total}…");
            var result = await backup.BackUpAllDocumentsAsync(
                progress,
                CancellationToken.None);
            _walkthroughBackupFinished = true;
            WalkthroughBackupStatus.Text = result.Count == 1
                ? $"Backed up 1 document to {result.Destination}."
                : $"Backed up {result.Count} documents to {result.Destination}.";
            _diagnostics.Record("backup", $"Backed up {result.Count} documents");
        }
        catch (TabletBackupException exception)
        {
            WalkthroughBackupStatus.Text = exception.Message;
            _diagnostics.Record("backup", "Tablet backup failed");
        }
        finally
        {
            _walkthroughBackupRunning = false;
            RefreshWalkthrough();
        }
    }

    private bool _restoreBackupRunning;

    private async void RestoreBackupButton_Click(object sender, RoutedEventArgs e)
    {
        if (_restoreBackupRunning)
        {
            return;
        }

        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add("*");
        if (App.MainWindow is not null)
        {
            WinRT.Interop.InitializeWithWindow.Initialize(
                picker,
                WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        }
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null)
        {
            return;
        }

        _restoreBackupRunning = true;
        RestoreBackupButton.IsEnabled = false;
        _diagnostics.Record("restore", "Backup restore requested");
        try
        {
            using var backup = new TabletBackupService();
            var progress = new Progress<TabletBackupProgress>(update =>
                ShowInfo($"Restoring {update.Completed} of {update.Total}…"));
            var count = await backup.RestoreAllDocumentsAsync(
                folder.Path,
                progress,
                CancellationToken.None);
            ShowInfo(
                count == 1
                    ? "Restored 1 document to the tablet."
                    : $"Restored {count} documents to the tablet.",
                InfoBarSeverity.Success);
            _diagnostics.Record("restore", $"Restored {count} documents");
        }
        catch (TabletBackupException exception)
        {
            ShowInfo(exception.Message, InfoBarSeverity.Error);
            _diagnostics.Record("restore", "Backup restore failed");
        }
        finally
        {
            _restoreBackupRunning = false;
            RestoreBackupButton.IsEnabled = true;
        }
    }

    private async void TabletSetupPrimaryButton_Click(object sender, RoutedEventArgs e)
    {
        var forceRepair = _tabletSetupForceRepair;
        string? oneTimePassword = null;

        switch (_mirrorState)
        {
            case MirrorConnectionState.SetupRequired:
                break;
            case MirrorConnectionState.SetupPasswordRequired:
                oneTimePassword = TabletSetupPasswordBox.Password;
                TabletSetupPasswordBox.Password = string.Empty;
                if (string.IsNullOrWhiteSpace(oneTimePassword))
                {
                    TabletSetupValidationText.Text =
                        "Enter the one-time Developer Mode password shown on your tablet.";
                    TabletSetupValidationText.Visibility = Visibility.Visible;
                    TabletSetupPasswordBox.Focus(FocusState.Programmatic);
                    return;
                }
                break;
            case MirrorConnectionState.SetupNeedsAttention:
                break;
            case MirrorConnectionState.WakeSetupRequired:
                forceRepair = true;
                break;
            default:
                return;
        }

        await RunTabletSetupAsync(oneTimePassword, forceRepair);
    }

    private async Task RunTabletSetupAsync(
        string? oneTimePassword,
        bool forceRepair)
    {
        var applicationCancellation = _connectionCancellation;
        if (!_pageIsLoaded ||
            applicationCancellation is null ||
            _tabletSetupTask is { IsCompleted: false })
        {
            return;
        }

        _tabletSetupForceRepair = forceRepair;
        TabletSetupPasswordBox.Password = string.Empty;
        SetMirrorState(MirrorConnectionState.SetupInProgress);

        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            applicationCancellation.Token);
        _tabletSetupCancellation = cancellation;
        var progress = new Progress<TabletSetupPhase>(ReportTabletSetupPhase);
        var setupTask = _tabletSetup.RunAsync(
            oneTimePassword,
            forceRepair,
            progress,
            message => _diagnostics.Record("tablet setup", message),
            cancellation.Token);
        oneTimePassword = null;
        _tabletSetupTask = setupTask;

        try
        {
            var result = await setupTask;
            if (_pageIsLoaded &&
                ReferenceEquals(_tabletSetupCancellation, cancellation))
            {
                ApplyTabletSetupResult(result);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            var target = exception.TargetSite;
            var location = target?.DeclaringType is null
                ? target?.Name
                : $"{target.DeclaringType.Name}.{target.Name}";
            _diagnostics.Record(
                "tablet setup",
                location is null
                    ? exception.GetType().Name
                    : $"{exception.GetType().Name} at {location}");
            if (_pageIsLoaded &&
                ReferenceEquals(_tabletSetupCancellation, cancellation))
            {
                SetMirrorState(
                    MirrorConnectionState.SetupNeedsAttention,
                    "Mirror couldn’t finish tablet setup. Check the direct USB-C connection and try again.");
            }
        }
        finally
        {
            if (ReferenceEquals(_tabletSetupCancellation, cancellation))
            {
                _tabletSetupCancellation = null;
                _tabletSetupTask = null;
            }
            cancellation.Dispose();
        }
    }

    private void ReportTabletSetupPhase(TabletSetupPhase phase)
    {
        if (!_pageIsLoaded || _mirrorState is not MirrorConnectionState.SetupInProgress)
        {
            return;
        }

        SetMirrorState(
            MirrorConnectionState.SetupInProgress,
            phase switch
            {
                TabletSetupPhase.CheckingUsb =>
                    "Checking the direct USB-C connection.",
                TabletSetupPhase.PairingComputer =>
                    "Authorizing this computer for your tablet.",
                TabletSetupPhase.InstallingTabletComponents =>
                    "Installing the Mirror components on your tablet.",
                _ => "Verifying tablet setup.",
            });
    }

    private void ApplyTabletSetupResult(TabletSetupResult result)
    {
        _lastTabletSetupStatus = result.Status;
        if (result.UntestedTabletSoftware is { } untestedTabletSoftware)
        {
            _diagnostics.Record(
                "tablet setup",
                $"tablet_software_untested:{untestedTabletSoftware}");
        }

        switch (result.Status)
        {
            case TabletSetupStatus.Ready:
                _startupRoutes = ResolveStartupRoutes();
                if (IsTabletSetupComplete())
                {
                    RememberFinishedTabletSetup();
                    _tabletSetupForceRepair = false;
                    SetMirrorState(MirrorConnectionState.Waiting);
                }
                else
                {
                    _tabletSetupForceRepair = true;
                    SetMirrorState(
                        MirrorConnectionState.SetupNeedsAttention,
                        "Mirror installed the tablet components but could not load the finished connection profile. Repair tablet setup and try again.");
                }
                break;
            case TabletSetupStatus.PasswordRequired:
                SetMirrorState(
                    MirrorConnectionState.SetupPasswordRequired,
                    result.Message);
                TabletSetupPasswordBox.Focus(FocusState.Programmatic);
                break;
            case TabletSetupStatus.PasswordRejected:
                SetMirrorState(
                    MirrorConnectionState.SetupPasswordRequired,
                    result.Message);
                TabletSetupValidationText.Text = result.Message;
                TabletSetupValidationText.Visibility = Visibility.Visible;
                TabletSetupPasswordBox.Focus(FocusState.Programmatic);
                break;
            case TabletSetupStatus.Cancelled:
                break;
            default:
                SetMirrorState(
                    MirrorConnectionState.SetupNeedsAttention,
                    result.Message);
                break;
        }
    }

    private void SetLiveState(MirrorRouteGeneration generation)
    {
        if (_inputRestoreUncertain)
        {
            RetireIncompleteConnection(
                generation,
                "Mirror could not confirm that physical tablet input was restored. Restart the tablet and reopen Mirror before using controls again.");
            return;
        }
        if (_inputPublication.IsPending(generation.Id))
        {
            var session = _inputSession;
            if (session is null ||
                Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
                !session.IsRunning)
            {
                RetireIncompleteConnection(
                    generation,
                    "The selected connection opened the display, but controls did not start. Choose USB-C or Wi-Fi to try again.");
                return;
            }
            _inputPublication.Complete(generation.Id);
        }
        SetMirrorState(MirrorConnectionState.Live);
        ConnectionText.Text = generation.Kind is DeviceRouteKind.Usb
            ? "Live over USB"
            : "Live over Wi-Fi";
        if (_filesPaneOpen)
        {
            _ = ProbeFilesRouteAsync(generation);
        }
    }

    private void RetireIncompleteConnection(
        MirrorRouteGeneration generation,
        string message)
    {
        if (Interlocked.CompareExchange(
                ref _retiringRouteGeneration,
                generation.Id,
                0) != 0)
        {
            return;
        }

        _ = RetireIncompleteConnectionAsync(generation, message);
    }

    private async Task RetireIncompleteConnectionAsync(
        MirrorRouteGeneration generation,
        string message)
    {
        try
        {
            await RetireSelectedConnectionAsync(
                generation,
                MirrorConnectionState.Error,
                message,
                _connectionCancellation?.Token ?? new CancellationToken(true));
        }
        finally
        {
            Interlocked.CompareExchange(
                ref _retiringRouteGeneration,
                0,
                generation.Id);
        }
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
                !_filesPaneDesiredOpen ||
                _filesReadyGeneration == generation.Id ||
                _filesProbeGeneration == generation.Id)
            {
                return;
            }
            _filesProbeGeneration = generation.Id;
        }

        FileTransferFailure? recordedFailure = null;
        string? recordedUnexpectedFailure = null;
        IReadOnlyList<RemarkableLibraryItem>? rootItems = null;
        try
        {
            while (IsCurrentGeneration(generation) && _filesPaneDesiredOpen)
            {
                try
                {
                    rootItems = await generation.FileTransport.ListRootAsync(
                            generation.CancellationToken)
                        .ConfigureAwait(false);
                    lock (_routeAdmissionGate)
                    {
                        if (!ReferenceEquals(Volatile.Read(ref _routeGeneration), generation) ||
                            generation.CancellationToken.IsCancellationRequested ||
                            !_filesPaneDesiredOpen)
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
        if (rootItems is not null)
        {
            DispatcherQueue.TryEnqueue(
                DispatcherQueuePriority.High,
                () =>
                {
                    if (IsCurrentGeneration(generation) && _filesPaneOpen)
                    {
                        _ = RefreshLibraryAsync(rootItems);
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
                restartProbe =
                    _filesPaneDesiredOpen &&
                    _filesProbeGeneration != generation.Id;
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
            if (generation is null)
            {
                if (_inputSession is not null)
                {
                    await CloseInputSessionAsync().ConfigureAwait(false);
                }
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
                                _diagnostics.Record(
                                    "input",
                                    "Controls published for the current route");
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
                                retryDelay = RegisterInputFailure();
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
                            LatchInputRestoreUncertain(exception.Message);
                        }
                        catch (Exception exception)
                        {
                            LatchInputRestoreUncertain(
                                "Mirror could not confirm that physical tablet input was restored after control setup failed.");
                            _diagnostics.Record(
                                "input cleanup",
                                $"Unpublished session: {exception.GetType().Name}");
                        }
                    }
                    if (attemptOwned)
                    {
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
                    await RetireSelectedConnectionAsync(
                            generation,
                            MirrorConnectionState.Error,
                            "The selected connection could not start tablet controls. Choose USB-C or Wi-Fi to try again.",
                            cancellationToken)
                        .ConfigureAwait(false);
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
                                 Interlocked.Read(ref _lastInputHeartbeatTimestamp)) >= InputHeartbeatInterval)
                    {
                        await session.PingAsync(routeToken).ConfigureAwait(false);
                        MarkInputHeartbeat();
                    }
                    retryDelay = NextInputMaintenanceDelay(activityInterval);
                }
                catch (InputSessionException exception)
                {
                    var removed = await DropInputSessionAfterFailureAsync(
                        session,
                        generation).ConfigureAwait(false);
                    if (removed)
                    {
                        _diagnostics.Record("input failure", exception.Message);
                        await RetireSelectedConnectionAsync(
                                generation,
                                MirrorConnectionState.Error,
                                "The selected connection lost tablet controls. Choose USB-C or Wi-Fi to connect again.",
                                cancellationToken)
                            .ConfigureAwait(false);
                        retryDelay = TimeSpan.FromMilliseconds(500);
                    }
                }
                catch (ObjectDisposedException)
                {
                    // Route retirement can dispose the session before this loop
                    // observes cancellation. Only a still-current session may end
                    // the selected connection.
                    var removed = await DropInputSessionAfterFailureAsync(
                        session,
                        generation).ConfigureAwait(false);
                    if (removed)
                    {
                        _diagnostics.Record("input failure", "The tablet input session closed unexpectedly.");
                        await RetireSelectedConnectionAsync(
                                generation,
                                MirrorConnectionState.Error,
                                "The selected connection lost tablet controls. Choose USB-C or Wi-Fi to connect again.",
                                cancellationToken)
                            .ConfigureAwait(false);
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
    }

    private TimeSpan RegisterInputFailure()
    {
        // Every managed input attempt can restart Xochitl. Latch this
        // generation after a failure; exact-generation retirement follows.
        _inputRetryLatched = true;
        return TimeSpan.FromMilliseconds(500);
    }

    private void SetInputAvailability(bool available)
    {
        ToolTipService.SetToolTip(
            ModeSelector,
            available
                ? "Choose Touch or Pen for the pointer. Keyboard typing is automatic."
                : "Your pointer choice and automatic keyboard will activate when Mirror connects");
    }

    private void MarkInputActivity()
    {
        var timestamp = Stopwatch.GetTimestamp();
        Interlocked.Exchange(ref _lastInputActivityTimestamp, timestamp);
        Interlocked.Exchange(ref _lastInputHeartbeatTimestamp, timestamp);
    }

    private void MarkInputHeartbeat() =>
        Interlocked.Exchange(ref _lastInputHeartbeatTimestamp, Stopwatch.GetTimestamp());

    private TimeSpan NextInputMaintenanceDelay(TimeSpan activityInterval)
    {
        var untilActivity = activityInterval - Stopwatch.GetElapsedTime(
            Interlocked.Read(ref _lastInputActivityTimestamp));
        var untilHeartbeat = InputHeartbeatInterval - Stopwatch.GetElapsedTime(
            Interlocked.Read(ref _lastInputHeartbeatTimestamp));
        var delay = untilActivity < untilHeartbeat ? untilActivity : untilHeartbeat;
        return delay > TimeSpan.Zero ? delay : TimeSpan.Zero;
    }

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

    private async Task<bool> DropInputSessionAfterFailureAsync(
        SshInputSession session,
        MirrorRouteGeneration generation)
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
            if (belongsToGeneration && removal.Removed)
            {
                _inputPublication.Complete(generation.Id);
            }

            return removal.Removed;
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
        cancellationToken.ThrowIfCancellationRequested();
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
                        if (cancellationToken.IsCancellationRequested)
                        {
                            completion.TrySetCanceled(cancellationToken);
                            return;
                        }
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

    private async void ConnectionRouteButton_Click(object sender, RoutedEventArgs e)
    {
        var generation = Volatile.Read(ref _routeGeneration);
        if (_mirrorState is not MirrorConnectionState.Live ||
            generation is null ||
            !IsCurrentGeneration(generation))
        {
            return;
        }

        if (generation.Kind is DeviceRouteKind.Usb)
        {
            ShowWifiAddressEntry();
            return;
        }

        await ConnectUsbAsync();
    }

    private async void ConnectUsbButton_Click(object sender, RoutedEventArgs e) =>
        await ConnectUsbAsync();

    private async Task ConnectUsbAsync()
    {
        HideWifiAddressEntry();
        await StartManualConnectionAsync(
            ManualConnectionRequest.ForUsb(_startupRoutes.UsbRoute));
    }

    private void ConnectWifiButton_Click(object sender, RoutedEventArgs e) =>
        ShowWifiAddressEntry();

    private void ShowWifiAddressEntry()
    {
        if (_connectionAttemptTask is { IsCompleted: false })
        {
            ShowInfo(
                "A connection attempt is already in progress.",
                InfoBarSeverity.Informational);
            return;
        }

        WifiAddressValidationText.Visibility = Visibility.Collapsed;
        WifiAddressValidationText.Text = string.Empty;
        if (string.IsNullOrWhiteSpace(WifiAddressTextBox.Text) &&
            _startupRoutes.WifiRoute is { } savedRoute)
        {
            WifiAddressTextBox.Text = savedRoute.Host;
        }
        if (_mirrorState is MirrorConnectionState.Live)
        {
            ConnectionPanelTitle.Text = "Switch to Wi-Fi";
            ConnectionPanelDetail.Text = "Enter the tablet’s current Wi-Fi IPv4 address, then choose Connect.";
        }
        ConnectionPanel.Visibility = Visibility.Visible;
        ConnectionChoicePanel.Visibility = Visibility.Collapsed;
        WifiAddressPanel.Visibility = Visibility.Visible;
        WifiAddressTextBox.Focus(FocusState.Programmatic);
        WifiAddressTextBox.SelectAll();
    }

    private async void SubmitWifiAddressButton_Click(object sender, RoutedEventArgs e) =>
        await SubmitWifiAddressAsync();

    private void CancelWifiAddressButton_Click(object sender, RoutedEventArgs e) =>
        HideWifiAddressEntry();

    private async void WifiAddressTextBox_KeyDown(
        object sender,
        KeyRoutedEventArgs e)
    {
        if (e.Key is Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            await SubmitWifiAddressAsync();
        }
        else if (e.Key is Windows.System.VirtualKey.Escape)
        {
            e.Handled = true;
            HideWifiAddressEntry();
        }
    }

    private async Task SubmitWifiAddressAsync()
    {
        var profile = _startupRoutes.Profile;
        if (profile is null)
        {
            _tabletSetupForceRepair =
                _startupRoutes.ProfileStatus is DeviceProfileLoadStatus.Ready;
            SetMirrorState(
                MirrorConnectionState.SetupRequired,
                "Finish tablet setup before connecting over Wi-Fi.");
            return;
        }

        if (!ManualConnectionRequest.TryCreateWifi(
                WifiAddressTextBox.Text,
                profile.FilesTarget.Port,
                out var request,
                out var error) ||
            request is null)
        {
            ShowWifiAddressValidation(error switch
            {
                ManualWifiAddressError.AddressRequired =>
                    "Enter the tablet’s Wi-Fi IPv4 address.",
                ManualWifiAddressError.InvalidAddress =>
                    "Enter a valid IPv4 address, such as 192.168.1.42.",
                _ =>
                    "Enter the tablet’s Wi-Fi address, not a loopback, multicast, or USB-C address.",
            });
            return;
        }

        HideWifiAddressEntry();
        await StartManualConnectionAsync(request);
    }

    private void ShowWifiAddressValidation(string message)
    {
        WifiAddressValidationText.Text = message;
        WifiAddressValidationText.Visibility = Visibility.Visible;
        WifiAddressTextBox.Focus(FocusState.Programmatic);
    }

    private void HideWifiAddressEntry()
    {
        WifiAddressValidationText.Visibility = Visibility.Collapsed;
        WifiAddressValidationText.Text = string.Empty;
        WifiAddressPanel.Visibility = Visibility.Collapsed;
        ConnectionChoicePanel.Visibility = Visibility.Visible;
        var generation = Volatile.Read(ref _routeGeneration);
        ConnectionPanel.Visibility = _mirrorState is MirrorConnectionState.Live &&
                                     generation is not null &&
                                     IsCurrentGeneration(generation)
            ? Visibility.Collapsed
            : Visibility.Visible;
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
            var generation = Volatile.Read(ref _routeGeneration);
            if (generation is not null && IsCurrentGeneration(generation))
            {
                _ = ProbeFilesRouteAsync(generation);
            }
            else
            {
                _ = RefreshLibraryAsync();
            }
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
        lock (_routeAdmissionGate)
        {
            _filesPaneDesiredOpen = false;
            _filesPaneOpen = false;
            _filesReadyGeneration = 0;
        }
        _filesPaneTransitioning = false;
        _filesPaneLinearProgress = 0;
        _filesPaneProgress = 0;
        MainFilesPane.IsHitTestVisible = false;
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

            return generation;
        }
    }

    private async Task RefreshLibraryAsync(
        IReadOnlyList<RemarkableLibraryItem>? knownRootItems = null)
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
                ? knownRootItems ?? await routeGeneration.FileTransport.ListRootAsync(token)
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
                    ? "Wake or unlock your reMarkable. Files will keep checking while this selected connection remains active."
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
        var applicationCancellationToken =
            _connectionCancellation?.Token ?? new CancellationToken(true);
        _activePointerId = null;
        DeviceScreen.ReleasePointerCaptures();
        var session = _inputSession;
        var generation = Volatile.Read(ref _routeGeneration);
        if (session is null ||
            generation is null ||
            Interlocked.Read(ref _inputSessionGeneration) != generation.Id ||
            !IsCurrentGeneration(generation))
        {
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
            var removed = await DropInputSessionAfterFailureAsync(session, generation);
            if (removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                await RetireSelectedConnectionAsync(
                    generation,
                    MirrorConnectionState.Error,
                    "The selected connection lost tablet controls. Choose USB-C or Wi-Fi to connect again.",
                    applicationCancellationToken);
            }
        }
        finally
        {
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
            return true;
        }
    }

    private async Task SendPointerAsync(RemotePointerAction action, PointerPoint point)
    {
        var applicationCancellationToken =
            _connectionCancellation?.Token ?? new CancellationToken(true);
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
            var removed = await DropInputSessionAfterFailureAsync(session, generation);
            if (removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                await RetireSelectedConnectionAsync(
                    generation,
                    MirrorConnectionState.Error,
                    "The selected connection lost tablet controls. Choose USB-C or Wi-Fi to connect again.",
                    applicationCancellationToken);
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
        var applicationCancellationToken =
            _connectionCancellation?.Token ?? new CancellationToken(true);
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
            var removed = await DropInputSessionAfterFailureAsync(session, generation);
            if (removed)
            {
                _diagnostics.Record("input failure", exception.Message);
                await RetireSelectedConnectionAsync(
                    generation,
                    MirrorConnectionState.Error,
                    "The selected connection lost tablet controls. Choose USB-C or Wi-Fi to connect again.",
                    applicationCancellationToken);
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
        foreach (var file in compatibleFiles)
        {
            if (!IsCurrentGeneration(routeGeneration))
            {
                break;
            }

            var transfer = new TransferItem(file.Name, "Sending…");
            Transfers.Insert(0, transfer);
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

        if (sent > 0 && IsCurrentGeneration(routeGeneration))
        {
            ShowInfo(
                $"Sent {sent} file{(sent == 1 ? string.Empty : "s")} to your reMarkable.",
                InfoBarSeverity.Success);
            await RefreshLibraryAsync();
        }
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
        DeviceProfileLoadStatus ProfileStatus);

    private readonly record struct InputSessionRemovalResult(
        bool Removed,
        bool RestoreConfirmed)
    {
        public static InputSessionRemovalResult NotRemoved(bool restoreConfirmed) =>
            new(Removed: false, RestoreConfirmed: restoreConfirmed);
    }

    private readonly record struct RouteTransitionOutcome(
        bool Changed,
        MirrorRouteGeneration? PublishedGeneration)
    {
        public static RouteTransitionOutcome Unchanged => new(false, null);

        public static RouteTransitionOutcome Retired => new(true, null);

        public static RouteTransitionOutcome Published(MirrorRouteGeneration generation) =>
            new(true, generation);
    }
}

public enum MirrorConnectionState
{
    Waiting,
    SetupRequired,
    SetupInProgress,
    SetupPasswordRequired,
    SetupNeedsAttention,
    WakeAndUnlock,
    AwaitingUnlock,
    Sleeping,
    Waking,
    Starting,
    WakeSetupRequired,
    Preparing,
    Live,
    Error,
    ConnectionEnded,
}

public enum RemoteInputMode
{
    Touch,
    Pen,
}

public sealed class TransferItem : INotifyPropertyChanged
{
    private string _state;

    public TransferItem(string name, string state)
    {
        Name = name;
        _state = state;
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

    public event PropertyChangedEventHandler? PropertyChanged;
}
