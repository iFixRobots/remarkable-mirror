using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReMarkableMirror;

/// <summary>
/// One persistent, ordered input channel from the Windows UI to rmmirror-probe.
/// The remote command owns every virtual device for exactly this SSH session.
/// </summary>
public sealed class SshInputSession : IAsyncDisposable
{
    private const string ProtocolSchema = "rmmirror.input/v1";
    private const int TouchXMax = 1248;
    private const int TouchYMax = 2208;
    private const int PenXMax = 6760;
    private const int PenYMax = 11960;
    private static readonly TimeSpan InputStartupTimeout = TimeSpan.FromSeconds(100);
    private static readonly TimeSpan GracefulShutdownTimeout = TimeSpan.FromSeconds(100);
    private static readonly TimeSpan ForcedShutdownTimeout = TimeSpan.FromSeconds(3);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly Process _process;
    private readonly Task<string> _stderrTask;
    private readonly SemaphoreSlim _commandGate = new(1, 1);
    private long _nextCommandId;
    private int _forcedAbort;
    private bool _disposed;

    public string InitialDisplayState { get; private set; } = "unknown";
    public string InitialFilesState { get; private set; } = "not_requested";
    internal bool IsRunning => !_disposed && !_process.HasExited;

    private SshInputSession(Process process, Task<string> stderrTask)
    {
        _process = process;
        _stderrTask = stderrTask;
        _process.StandardInput.NewLine = "\n";
        _process.StandardInput.AutoFlush = true;
    }

    public static async Task<SshInputSession> ConnectAsync(
        string host,
        CancellationToken cancellationToken = default) =>
        await ConnectAsync(
            new SshRoute(host),
            enableFilesFallback: false,
            cancellationToken).ConfigureAwait(false);

    public static async Task<SshInputSession> ConnectAsync(
        SshRoute route,
        CancellationToken cancellationToken = default) =>
        await ConnectAsync(
            route,
            enableFilesFallback: false,
            cancellationToken).ConfigureAwait(false);

    public static async Task<SshInputSession> ConnectAsync(
        SshRoute route,
        bool enableFilesFallback,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (!route.CredentialFilesExist)
        {
            throw new InputSessionException(
                "Mirror setup is missing its tablet SSH key.",
                isPersistent: true);
        }

        using var startupTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        startupTimeout.CancelAfter(InputStartupTimeout);

        var process = new Process
        {
            StartInfo = CreateStartInfo(route, enableFilesFallback),
        };
        var started = false;
        Task<string>? stderrTask = null;
        SshInputSession? session = null;
        try
        {
            try
            {
                if (!process.Start())
                {
                    throw new InputSessionException("Windows could not start the tablet input connection.");
                }
                started = true;
                try
                {
                    SshChildProcessJob.AssignOrTerminate(process);
                }
                catch (Win32Exception exception)
                {
                    throw new InputSessionException(
                        "Windows could not secure the tablet input connection lifetime.",
                        exception,
                        isPersistent: true);
                }
            }
            catch (Win32Exception exception)
            {
                throw new InputSessionException(
                    "Windows OpenSSH is not available.",
                    exception,
                    isPersistent: true);
            }

            stderrTask = process.StandardError.ReadToEndAsync();
            session = new SshInputSession(process, stderrTask);
            string? readyLine;
            try
            {
                readyLine = await process.StandardOutput.ReadLineAsync(startupTimeout.Token);
            }
            catch (OperationCanceledException exception) when (!cancellationToken.IsCancellationRequested)
            {
                throw new InputSessionException(
                    "The tablet input session did not become ready in time.",
                    exception);
            }
            if (readyLine is null)
            {
                var stopped = await session.DescribeStoppedProcessAsync();
                throw new InputSessionException(stopped.Message, stopped.IsPersistent);
            }

            InputEnvelope? ready;
            try
            {
                ready = JsonSerializer.Deserialize<InputEnvelope>(readyLine, JsonOptions);
            }
            catch (JsonException exception)
            {
                throw new InputSessionException(
                    "The tablet returned an invalid input handshake.",
                    exception,
                    isPersistent: true);
            }
            if (ready is not
                {
                    Schema: ProtocolSchema,
                    Ready: true,
                    Touch.XMax: TouchXMax,
                    Touch.YMax: TouchYMax,
                    Pen.XMax: PenXMax,
                    Pen.YMax: PenYMax,
                } ||
                (enableFilesFallback &&
                 ready.FilesState is not ("ready" or "unavailable")))
            {
                throw new InputSessionException(
                    "The tablet input ranges do not match this Paper Pro Move.",
                    isPersistent: true);
            }
            session.InitialDisplayState = ready.DisplayState ?? "unknown";
            session.InitialFilesState = ready.FilesState ?? "not_requested";
            return session;
        }
        catch (Exception startupException)
        {
            Exception? cleanupException = null;
            try
            {
                if (session is not null)
                {
                    await session.DisposeAsync();
                }
                else if (started)
                {
                    var stop = await StopProcessAsync(
                        process,
                        stderrTask,
                        closeStandardInput: true,
                        GracefulShutdownTimeout);
                    if (stop.Forced || !stop.Exited)
                    {
                        cleanupException = new InputSessionException(
                            "Mirror could not confirm tablet input cleanup after setup failed.",
                            isPersistent: true);
                    }
                }
            }
            catch (Exception exception)
            {
                cleanupException = exception;
            }
            if (session is null)
            {
                process.Dispose();
            }
            if (cleanupException is not null)
            {
                throw new InputSessionException(
                    "Mirror could not confirm that physical tablet input was restored after control setup failed.",
                    new AggregateException(startupException, cleanupException),
                    isPersistent: true);
            }

            ExceptionDispatchInfo.Capture(startupException).Throw();
            throw new UnreachableException();
        }
    }

    public Task SendTouchAsync(
        RemotePointerAction action,
        double? normalizedX = null,
        double? normalizedY = null,
        double? pressure = null,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(
                NextCommandId(), "touch", ActionName(action),
                normalizedX, normalizedY, pressure),
            cancellationToken);

    public Task SendPenAsync(
        RemotePointerAction action,
        double? normalizedX = null,
        double? normalizedY = null,
        double? pressure = null,
        bool eraser = false,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(
                NextCommandId(), "pen", ActionName(action),
                normalizedX, normalizedY, pressure,
                action == RemotePointerAction.Down ? (eraser ? "eraser" : "pen") : null),
            cancellationToken);

    public Task SendKeyAsync(
        string linuxKeyName,
        bool isDown,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(
                NextCommandId(), "key", isDown ? "down" : "up",
                Key: linuxKeyName),
            cancellationToken);

    public Task ClickKeyAsync(
        string linuxKeyName,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(
                NextCommandId(), "key", "click",
                Key: linuxKeyName),
            cancellationToken);

    public Task SendTextAsync(
        string text,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(NextCommandId(), "text", Text: text),
            cancellationToken);

    public Task ResetAsync(CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(NextCommandId(), "reset"),
            cancellationToken);

    public Task PingAsync(CancellationToken cancellationToken = default) =>
        SendCommandAsync(
            new InputCommand(NextCommandId(), "ping"),
            cancellationToken);

    internal async Task<InputSessionStopStatus?> InspectStoppedAsync(
        TimeSpan observationWindow,
        CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(observationWindow, TimeSpan.Zero);
        var observationStarted = Stopwatch.GetTimestamp();
        while (!_disposed && !_process.HasExited)
        {
            var remaining = observationWindow - Stopwatch.GetElapsedTime(observationStarted);
            if (remaining <= TimeSpan.Zero)
            {
                return null;
            }
            try
            {
                await Task.Delay(
                        remaining < TimeSpan.FromMilliseconds(50)
                            ? remaining
                            : TimeSpan.FromMilliseconds(50),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return null;
            }
        }

        if (_disposed)
        {
            return null;
        }

        try
        {
            await _commandGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        try
        {
            if (_disposed || !_process.HasExited)
            {
                return null;
            }

            var stopped = await DescribeStoppedProcessAsync().ConfigureAwait(false);
            return new InputSessionStopStatus(stopped.Message, stopped.IsPersistent);
        }
        finally
        {
            _commandGate.Release();
        }
    }

    public async Task<bool> WakeIfDeepSleepingAsync(CancellationToken cancellationToken = default)
    {
        if (!string.Equals(InitialDisplayState, "deep_sleep", StringComparison.Ordinal))
        {
            return false;
        }

        // Mark the one-shot attempt before writing so this session can never
        // toggle the display twice after a partial or failed acknowledgement.
        InitialDisplayState = "normal";
        await ClickKeyAsync("KEY_POWER", cancellationToken);
        return true;
    }

    public async Task NotifyActivityAsync(CancellationToken cancellationToken = default)
    {
        await ClickKeyAsync("KEY_F12", cancellationToken);
    }

    private async Task SendCommandAsync(
        InputCommand command,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _commandGate.WaitAsync(cancellationToken);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_process.HasExited)
            {
                var stopped = await DescribeStoppedProcessAsync();
                throw new InputSessionException(stopped.Message, stopped.IsPersistent);
            }

            var line = JsonSerializer.Serialize(command, JsonOptions);
            try
            {
                await _process.StandardInput.WriteLineAsync(line.AsMemory(), cancellationToken);
                var responseLine = await _process.StandardOutput.ReadLineAsync(cancellationToken);
                if (responseLine is null)
                {
                    var stopped = await DescribeStoppedProcessAsync();
                    throw new InputSessionException(stopped.Message, stopped.IsPersistent);
                }

                InputEnvelope? response;
                try
                {
                    response = JsonSerializer.Deserialize<InputEnvelope>(responseLine, JsonOptions);
                }
                catch (JsonException exception)
                {
                    throw new InputSessionException(
                        "The tablet returned an invalid input response.",
                        exception,
                        isPersistent: true);
                }
                if (response is null || response.Id != command.Id)
                {
                    throw new InputSessionException(
                        "The tablet input channel lost command ordering.",
                        isPersistent: true);
                }
                if (!response.Ok)
                {
                    throw new InputCommandRejectedException(
                        $"The tablet rejected input: {response.Error ?? "unknown_error"}.");
                }
            }
            catch (OperationCanceledException)
            {
                // Once a written command loses its acknowledgement, the stream
                // cannot be reused without risking response misalignment.
                Abort();
                throw;
            }
            catch (IOException exception)
            {
                Abort();
                throw new InputSessionException("The tablet input connection closed.", exception);
            }
        }
        finally
        {
            _commandGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        var gateEntered = await _commandGate.WaitAsync(TimeSpan.FromSeconds(2));
        try
        {
            // EOF makes the helper release held input, destroy its temporary
            // devices, and restart Xochitl against the physical marker. Startup
            // failures use this same bounded cleanup before frame preparation is
            // allowed to continue.
            var stop = await StopProcessAsync(
                _process,
                _stderrTask,
                closeStandardInput: true,
                GracefulShutdownTimeout);
            if (!gateEntered)
            {
                gateEntered = await _commandGate.WaitAsync(ForcedShutdownTimeout);
            }
            if (stop.Stderr.Contains("input_physical_restore_failed", StringComparison.Ordinal))
            {
                throw new InputSessionException(
                    "The tablet could not restore its physical input after mirroring.",
                    isPersistent: true);
            }
            if (stop.Forced || !stop.Exited || Volatile.Read(ref _forcedAbort) != 0)
            {
                throw new InputSessionException(
                    "The tablet input cleanup lost its completion signal. Mirror will wait for physical input restoration.",
                    isPersistent: true);
            }
        }
        finally
        {
            if (gateEntered)
            {
                _commandGate.Release();
                _commandGate.Dispose();
            }
            _process.Dispose();
        }
    }

    private long NextCommandId() => Interlocked.Increment(ref _nextCommandId);

    private void Abort()
    {
        Interlocked.Exchange(ref _forcedAbort, 1);
        KillProcess(_process);
    }

    private static async Task<ProcessStopResult> StopProcessAsync(
        Process process,
        Task<string>? stderrTask,
        bool closeStandardInput,
        TimeSpan gracefulTimeout)
    {
        if (!process.HasExited && closeStandardInput)
        {
            try
            {
                process.StandardInput.Close();
            }
            catch (Exception exception) when (
                exception is IOException or InvalidOperationException or ObjectDisposedException)
            {
            }
        }

        var forced = false;
        if (!await WaitForExitAsync(process, gracefulTimeout))
        {
            forced = true;
            KillProcess(process);
            await WaitForExitAsync(process, ForcedShutdownTimeout);
        }

        var stderr = string.Empty;
        if (stderrTask is null)
        {
            return new ProcessStopResult(
                process.HasExited,
                process.HasExited ? process.ExitCode : null,
                stderr,
                forced);
        }
        try
        {
            stderr = (await stderrTask.WaitAsync(ForcedShutdownTimeout)).Trim();
        }
        catch (Exception exception) when (
            exception is IOException or InvalidOperationException or ObjectDisposedException or TimeoutException)
        {
        }
        return new ProcessStopResult(
            process.HasExited,
            process.HasExited ? process.ExitCode : null,
            stderr,
            forced);
    }

    private static async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
    {
        if (process.HasExited)
        {
            return true;
        }
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
            return true;
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or OperationCanceledException or Win32Exception)
        {
            return process.HasExited;
        }
    }

    private static void KillProcess(Process process)
    {
        if (process.HasExited)
        {
            return;
        }
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or Win32Exception)
        {
        }
    }

    private static string ActionName(RemotePointerAction action) => action switch
    {
        RemotePointerAction.Down => "down",
        RemotePointerAction.Move => "move",
        RemotePointerAction.Up => "up",
        _ => throw new ArgumentOutOfRangeException(nameof(action)),
    };

    internal static string CreateRemoteCommand(bool enableFilesFallback)
    {
        const string command =
            "/home/root/.local/bin/rmmirror-probe input --heartbeat-timeout 15s";
        return enableFilesFallback
            ? command + " --files-fallback"
            : command;
    }

    private static ProcessStartInfo CreateStartInfo(
        SshRoute route,
        bool enableFilesFallback)
    {
        return route.CreateProcessStartInfo(
            remoteCommand: CreateRemoteCommand(enableFilesFallback),
            disablePseudoTerminal: true,
            redirectStandardInput: true,
            redirectStandardOutput: true,
            redirectStandardError: true);
    }

    private async Task<InputStopDescription> DescribeStoppedProcessAsync()
    {
        var stop = await StopProcessAsync(
            _process,
            _stderrTask,
            closeStandardInput: false,
            ForcedShutdownTimeout);
        if (stop.Forced || !stop.Exited)
        {
            Interlocked.Exchange(ref _forcedAbort, 1);
        }
        return DescribeStoppedProcess(stop);
    }

    private static InputStopDescription DescribeStoppedProcess(ProcessStopResult stop)
    {
        // SSH stderr can contain local paths, route addresses, and OpenSSH
        // configuration. Classify it in memory but never carry it into the UI
        // or diagnostic ledger.
        if (stop.Stderr.Contains("input_input_session_busy", StringComparison.Ordinal))
        {
            return new InputStopDescription("Tablet input is already in use.", IsPersistent: false);
        }
        if (stop.Stderr.Contains("input_xochitl_not_running", StringComparison.Ordinal))
        {
            return new InputStopDescription("Tablet input is waiting for the display service.", IsPersistent: false);
        }
        if (stop.Stderr.Contains("input_heartbeat_timeout", StringComparison.Ordinal))
        {
            return new InputStopDescription("Tablet input timed out and will reconnect.", IsPersistent: false);
        }
        if (
            stop.Stderr.Contains("Timeout, server", StringComparison.OrdinalIgnoreCase) &&
            stop.Stderr.Contains("not responding", StringComparison.OrdinalIgnoreCase))
        {
            return new InputStopDescription(
                "The tablet input connection missed its network keepalive and will reconnect.",
                IsPersistent: false);
        }
        if (stop.Stderr.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.OrdinalIgnoreCase) ||
            stop.Stderr.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase))
        {
            return new InputStopDescription(
                "The tablet's secure identity changed. Run Mirror setup again before retrying.",
                IsPersistent: true);
        }
        if (stop.Stderr.Contains("Permission denied", StringComparison.OrdinalIgnoreCase))
        {
            return new InputStopDescription(
                "This PC is no longer authorized to control the tablet.",
                IsPersistent: true);
        }
        if (stop.Stderr.Contains("rmmirror-probe:", StringComparison.OrdinalIgnoreCase))
        {
            return new InputStopDescription(
                "The tablet input companion stopped unexpectedly.",
                IsPersistent: true);
        }

        return new InputStopDescription(
            stop.ExitCode is { } exitCode
                ? $"Tablet input stopped with exit code {exitCode}."
                : "Tablet input stopped without an exit status.",
            IsPersistent: false);
    }

    private sealed record InputStopDescription(string Message, bool IsPersistent);

    private sealed record ProcessStopResult(
        bool Exited,
        int? ExitCode,
        string Stderr,
        bool Forced);

    private sealed record InputCommand(
        long Id,
        string Type,
        string? Action = null,
        double? X = null,
        double? Y = null,
        double? Pressure = null,
        string? Tool = null,
        string? Key = null,
        string? Text = null);

    private sealed record InputEnvelope(
        string? Schema,
        bool Ready,
        [property: JsonPropertyName("display_state")] string? DisplayState,
        [property: JsonPropertyName("files_state")] string? FilesState,
        long Id,
        bool Ok,
        string? Error,
        InputRange? Touch,
        InputRange? Pen);

    private sealed record InputRange(
        [property: JsonPropertyName("x_max")] int XMax,
        [property: JsonPropertyName("y_max")] int YMax);
}

public enum RemotePointerAction
{
    Down,
    Move,
    Up,
}

public class InputSessionException : Exception
{
    public bool IsPersistent { get; }

    public InputSessionException(string message, bool isPersistent = false) : base(message)
    {
        IsPersistent = isPersistent;
    }

    public InputSessionException(
        string message,
        Exception innerException,
        bool isPersistent = false) : base(message, innerException)
    {
        IsPersistent = isPersistent;
    }
}

internal sealed record InputSessionStopStatus(string Message, bool IsPersistent);

public sealed class InputCommandRejectedException(string message) :
    InputSessionException(message, isPersistent: true);
