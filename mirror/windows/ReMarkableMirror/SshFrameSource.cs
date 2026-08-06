using System.Buffers;
using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ReMarkableMirror;

public sealed class SshFrameSource
{
    public const int FrameWidth = 954;
    public const int FrameHeight = 1696;
    public const int FrameBytes = FrameWidth * FrameHeight * 4;

    private const int HeaderBytes = 28;
    private const string StreamRemoteCommand =
        "/home/root/.local/bin/rmmirror-probe stream --interval 40ms --heartbeat-timeout 15s";
    private const string StreamHeartbeatPulse = "\n";
    private const string DisplayReadyMarker = "RMMIRROR_DISPLAY_READY=";
    private const string XoviActivationSchema = "rmmirror.xovi-activation/v1";
    private const string XoviActivationStatusUnavailable = "xovi_activation_status_unavailable";
    private const string XoviActivationStatusStale = "xovi_activation_status_stale";
    private const string XoviActivationBusy = "xovi_activation_busy";
    private static readonly TimeSpan ActivationPollTimeout = TimeSpan.FromSeconds(120);
    private static readonly TimeSpan ActivationTransientTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan FreshReadinessTimeout = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan StreamHeartbeatInterval = TimeSpan.FromSeconds(3);
    private const string EnsureDisplayReadyCommand = """
        probe=/home/root/.local/bin/rmmirror-probe
        xovi=/home/root/xovi

        if ! test -x "$probe"; then
          printf '%s\n' 'rmmirror: companion_missing' >&2
          exit 40
        fi

        cancel_pending_system_sleep() {
          systemctl stop suspend-then-hibernate.target >/dev/null 2>&1 || true
          systemctl stop systemd-suspend-then-hibernate.service >/dev/null 2>&1 || true
          for sleep_unit in suspend-then-hibernate.target systemd-suspend-then-hibernate.service; do
            sleep_state=$(systemctl is-active "$sleep_unit" 2>/dev/null || true)
            case "$sleep_state" in
              inactive|failed) ;;
              *) return 1 ;;
            esac
          done
        }

        if test "$allow_start" -eq 1 && ! cancel_pending_system_sleep; then
          printf '%s\n' 'rmmirror: sleep_cancel_failed' >&2
          exit 49
        fi

        if test "$allow_start" -eq 1; then
          input_ready_output=$("$probe" input-ready --restore-timeout 50s 2>&1) || {
            printf '%s\n' 'rmmirror: input_restore_not_ready' >&2
            printf '%s\n' "$input_ready_output" | tail -c 800 >&2
            exit 47
          }
        fi

        display_ready() {
          "$probe" snapshot 2>/dev/null | grep -q '"framebuffer_address_seen":true'
        }

        runtime_ready() {
          runtime_pid="$(pidof xochitl || true)"
          test -n "$runtime_pid" &&
            test -p /run/xovi-mb &&
            test -p /run/xovi-mb-out &&
            grep -Fq "$xovi/xovi.so" "/proc/$runtime_pid/maps" &&
            grep -Fq "$xovi/extensions.d/framebuffer-spy.so" "/proc/$runtime_pid/maps" &&
            grep -Fq "$xovi/extensions.d/xovi-message-broker.so" "/proc/$runtime_pid/maps" &&
            grep -Fq "$xovi/extensions.d/rmmirror-files-loopback.so" "/proc/$runtime_pid/maps" &&
            ! grep -Fq "$xovi/extensions.d/qt-resource-rebuilder.so" "/proc/$runtime_pid/maps" &&
            ! grep -Fq "$xovi/extensions.d/webserver-remote.so" "/proc/$runtime_pid/maps" &&
            systemctl is-active --quiet xochitl &&
            systemctl is-active --quiet rm-sync
        }

        if display_ready && runtime_ready; then
          printf '%s\n' 'RMMIRROR_DISPLAY_READY=ready'
          exit 0
        fi

        attempt=0
        while test "$attempt" -lt "$readiness_attempts"; do
          sleep 0.25
          if display_ready && runtime_ready; then
            printf '%s\n' 'RMMIRROR_DISPLAY_READY=ready'
            exit 0
          fi
          attempt=$((attempt + 1))
        done

        printf '%s\n' 'RMMIRROR_DISPLAY_READY=not_ready'
        exit 0
        """;
    private readonly SshRoute _route;

    public SshFrameSource(string host) : this(new SshRoute(host))
    {
    }

    public SshFrameSource(SshRoute route)
    {
        _route = route ?? throw new ArgumentNullException(nameof(route));
    }

    public async Task<DisplayPreparationResult> EnsureDisplayReadyAsync(
        bool allowStart,
        CancellationToken cancellationToken)
    {
        EnsureLocalSetup();

        XoviActivationStatus? status = null;
        if (allowStart)
        {
            // A prior launch SSH session can disappear while its detached
            // worker remains authoritative. Adopt it before input-ready or any
            // other mutation-capable preflight can disturb its transaction.
            var existing = await ReadActivationStatusAsync(cancellationToken).ConfigureAwait(false);
            if (existing?.Outcome == XoviActivationOutcome.Running)
            {
                status = existing;
            }
        }

        if (status is null)
        {
            var ready = await ProbeDisplayReadinessAsync(
                    allowStart,
                    readinessAttempts: allowStart ? 0 : 40,
                    TimeSpan.FromSeconds(150),
                    cancellationToken)
                .ConfigureAwait(false);
            if (ready)
            {
                return new DisplayPreparationResult(StartedXovi: false);
            }

            var afterPreflight = await ReadActivationStatusAsync(cancellationToken)
                .ConfigureAwait(false);
            if (afterPreflight?.Outcome == XoviActivationOutcome.Running)
            {
                status = afterPreflight;
            }
            else
            {
                if (!allowStart)
                {
                    throw DisplayRuntimeNotReady();
                }
                status = await LaunchActivationAsync(cancellationToken).ConfigureAwait(false);
            }
        }

        status = await PollActivationAsync(status, cancellationToken).ConfigureAwait(false);
        if (status.Outcome is not XoviActivationOutcome.ReadyAlready and
            not XoviActivationOutcome.ReadyStarted)
        {
            throw DescribeActivationFailure(status);
        }

        await WaitForFreshDisplayReadinessAsync(cancellationToken).ConfigureAwait(false);
        return new DisplayPreparationResult(
            StartedXovi: status.Outcome == XoviActivationOutcome.ReadyStarted);
    }

    private async Task<bool> ProbeDisplayReadinessAsync(
        bool allowStart,
        int readinessAttempts,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        SshCommandResult result;
        try
        {
            result = await RunSshCommandAsync(
                    $"allow_start={(allowStart ? 1 : 0)}\n" +
                    $"readiness_attempts={readinessAttempts}\n" +
                    EnsureDisplayReadyCommand,
                    timeout,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (SshCommandTimedOutException)
        {
            throw new FrameStreamException(
                FrameStreamFailureKind.CompanionNotReady,
                "The tablet display setup did not finish. Copy the connection details, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: "category=display_preparation_timeout");
        }

        if (result.ExitCode != 0)
        {
            throw DescribePreparationExit(result.ExitCode, result.StandardError);
        }
        var ready = HasExactOutputLine(result.StandardOutput, DisplayReadyMarker + "ready");
        var notReady = HasExactOutputLine(
            result.StandardOutput,
            DisplayReadyMarker + "not_ready");
        if (ready == notReady)
        {
            throw IncompatibleCompanion("category=display_readiness_invalid");
        }
        if (ready)
        {
            return true;
        }
        return false;
    }

    private async Task<XoviActivationStatus?> ReadActivationStatusAsync(
        CancellationToken cancellationToken)
    {
        SshCommandResult result;
        try
        {
            result = await RunSshCommandAsync(
                    "/home/root/.local/bin/rmmirror-probe xovi-activation-status",
                    TimeSpan.FromSeconds(8),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (SshCommandTimedOutException)
        {
            throw SecureConnectionUnavailable("category=activation_status_timeout");
        }

        if (result.ExitCode == 0)
        {
            return ParseActivationStatus(result.StandardOutput);
        }
        if (ContainsAny(
                result.StandardError,
                XoviActivationStatusUnavailable,
                XoviActivationStatusStale))
        {
            return null;
        }
        throw DescribeExit(result.ExitCode, result.StandardError);
    }

    private async Task<XoviActivationStatus> LaunchActivationAsync(
        CancellationToken cancellationToken)
    {
        var attempt = CreateActivationAttempt();
        SshCommandResult result;
        try
        {
            result = await RunSshCommandAsync(
                    $"/home/root/.local/bin/rmmirror-probe xovi-activate --attempt {attempt}",
                    TimeSpan.FromSeconds(12),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (SshCommandTimedOutException)
        {
            // The SSH process is not the activation owner. The detached tablet
            // worker may have launched before the connection was interrupted.
            return new XoviActivationStatus(attempt, XoviActivationOutcome.Running, null);
        }

        if (!string.IsNullOrWhiteSpace(result.StandardOutput))
        {
            var status = ParseActivationStatus(result.StandardOutput);
            if (!string.Equals(status.Attempt, attempt, StringComparison.Ordinal))
            {
                throw IncompatibleCompanion("category=activation_attempt_mismatch");
            }
            return status;
        }

        if (result.StandardError.Contains(XoviActivationBusy, StringComparison.OrdinalIgnoreCase))
        {
            var existing = await ReadActivationStatusAsync(cancellationToken).ConfigureAwait(false);
            if (existing is not null && existing.Outcome == XoviActivationOutcome.Running)
            {
                return existing;
            }
            throw new FrameStreamException(
                FrameStreamFailureKind.CompanionNotReady,
                "The tablet display service could not be prepared safely. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: "category=activation_busy_without_running_status");
        }

        var failure = DescribeExit(result.ExitCode, result.StandardError);
        if (failure.Kind == FrameStreamFailureKind.SecureConnectionUnavailable)
        {
            // As with a local timeout, loss of the launch SSH session cannot
            // cancel or disprove the detached worker.
            return new XoviActivationStatus(attempt, XoviActivationOutcome.Running, null);
        }
        throw failure;
    }

    private async Task<XoviActivationStatus> PollActivationAsync(
        XoviActivationStatus initialStatus,
        CancellationToken cancellationToken)
    {
        var expectedAttempt = initialStatus.Attempt;
        var status = initialStatus;
        var pollClock = Stopwatch.StartNew();
        TimeSpan? transientStartedAt = null;
        FrameStreamException? lastTransientFailure = null;

        while (status.Outcome == XoviActivationOutcome.Running &&
               pollClock.Elapsed < ActivationPollTimeout)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var observed = await ReadActivationStatusAsync(cancellationToken).ConfigureAwait(false);
                if (observed is null)
                {
                    transientStartedAt ??= pollClock.Elapsed;
                }
                else
                {
                    if (!string.Equals(observed.Attempt, expectedAttempt, StringComparison.Ordinal))
                    {
                        throw IncompatibleCompanion("category=activation_attempt_mismatch");
                    }
                    status = observed;
                    transientStartedAt = null;
                    lastTransientFailure = null;
                    if (status.Outcome != XoviActivationOutcome.Running)
                    {
                        return status;
                    }
                }
            }
            catch (FrameStreamException exception) when (
                exception.Kind == FrameStreamFailureKind.SecureConnectionUnavailable)
            {
                transientStartedAt ??= pollClock.Elapsed;
                lastTransientFailure = exception;
            }

            if (transientStartedAt is { } startedAt &&
                pollClock.Elapsed - startedAt >= ActivationTransientTimeout)
            {
                throw lastTransientFailure ?? new FrameStreamException(
                    FrameStreamFailureKind.CompanionNotReady,
                    "The tablet display service is still starting. Mirror will reconnect automatically.",
                    canAutoRetry: true,
                    technicalDetail: "category=activation_status_temporarily_unavailable");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(350), cancellationToken).ConfigureAwait(false);
        }

        if (status.Outcome != XoviActivationOutcome.Running)
        {
            return status;
        }
        throw new FrameStreamException(
            FrameStreamFailureKind.CompanionNotReady,
            "The tablet display setup did not finish. Copy the connection details, then choose Retry.",
            canAutoRetry: false,
            technicalDetail: "category=activation_poll_timeout");
    }

    private async Task WaitForFreshDisplayReadinessAsync(CancellationToken cancellationToken)
    {
        var clock = Stopwatch.StartNew();
        FrameStreamException? lastTransientFailure = null;
        while (clock.Elapsed < FreshReadinessTimeout)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (await ProbeDisplayReadinessAsync(
                        allowStart: false,
                        readinessAttempts: 20,
                        TimeSpan.FromSeconds(12),
                        cancellationToken)
                    .ConfigureAwait(false))
                {
                    return;
                }
                lastTransientFailure = null;
            }
            catch (FrameStreamException exception) when (
                exception.Kind is FrameStreamFailureKind.SecureConnectionUnavailable or
                    FrameStreamFailureKind.CompanionNotReady)
            {
                lastTransientFailure = exception;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(350), cancellationToken).ConfigureAwait(false);
        }

        throw lastTransientFailure ?? DisplayRuntimeNotReady();
    }

    private async Task<SshCommandResult> RunSshCommandAsync(
        string remoteCommand,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = CreateStartInfo(remoteCommand) };
        var started = false;
        Task<string>? outputDrain = null;
        Task<string>? errorDrain = null;
        try
        {
            try
            {
                if (!process.Start())
                {
                    throw new FrameStreamException(
                        FrameStreamFailureKind.ConnectionProcessUnavailable,
                        "Windows could not open the secure tablet connection. Restart reMarkable Mirror, then choose Retry.",
                        canAutoRetry: false);
                }
                try
                {
                    SshChildProcessJob.AssignOrTerminate(process);
                }
                catch (Win32Exception exception)
                {
                    throw new FrameStreamException(
                        FrameStreamFailureKind.ConnectionProcessUnavailable,
                        "Windows could not secure the tablet connection. Restart reMarkable Mirror, then choose Retry.",
                        canAutoRetry: false,
                        exception);
                }
                started = true;
            }
            catch (Win32Exception exception)
            {
                throw new FrameStreamException(
                    FrameStreamFailureKind.OpenSshUnavailable,
                    "Windows OpenSSH is unavailable. Install OpenSSH Client, then choose Retry.",
                    canAutoRetry: false,
                    exception);
            }

            outputDrain = process.StandardOutput.ReadToEndAsync();
            errorDrain = process.StandardError.ReadToEndAsync();
            using var commandTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            commandTimeout.CancelAfter(timeout);
            try
            {
                await process.WaitForExitAsync(commandTimeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new SshCommandTimedOutException();
            }

            return new SshCommandResult(
                process.ExitCode,
                await outputDrain.ConfigureAwait(false),
                await errorDrain.ConfigureAwait(false));
        }
        finally
        {
            await TerminateAndDrainAsync(process, started, outputDrain, errorDrain)
                .ConfigureAwait(false);
        }
    }

    public async IAsyncEnumerable<FrameUpdate> WatchUpdatesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        EnsureLocalSetup();

        using var process = new Process
        {
            StartInfo = CreateStartInfo(
                StreamRemoteCommand,
                redirectStandardInput: true),
        };
        using var heartbeatCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        var started = false;
        Task<string>? errorDrain = null;
        Task? heartbeatWriter = null;
        try
        {
            try
            {
                if (!process.Start())
                {
                    throw new FrameStreamException(
                        FrameStreamFailureKind.ConnectionProcessUnavailable,
                        "Windows could not open the secure tablet connection. Restart reMarkable Mirror, then choose Retry.",
                        canAutoRetry: false);
                }
                try
                {
                    SshChildProcessJob.AssignOrTerminate(process);
                }
                catch (Win32Exception exception)
                {
                    throw new FrameStreamException(
                        FrameStreamFailureKind.ConnectionProcessUnavailable,
                        "Windows could not secure the tablet connection. Restart reMarkable Mirror, then choose Retry.",
                        canAutoRetry: false,
                        exception);
                }
                started = true;
            }
            catch (Win32Exception exception)
            {
                throw new FrameStreamException(
                    FrameStreamFailureKind.OpenSshUnavailable,
                    "Windows OpenSSH is unavailable. Install OpenSSH Client, then choose Retry.",
                    canAutoRetry: false,
                    exception);
            }

            errorDrain = process.StandardError.ReadToEndAsync();
            heartbeatWriter = WriteStreamHeartbeatsAsync(
                process.StandardInput,
                heartbeatCancellation.Token);
            var stream = process.StandardOutput.BaseStream;
            var header = new byte[HeaderBytes];
            var haveFullFrame = false;
            ulong previousSequence = 0;

            while (!cancellationToken.IsCancellationRequested &&
                   await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false))
            {
                if (!TryParseHeader(header, previousSequence, out var parsed))
                {
                    throw IncompatibleCompanion();
                }
                previousSequence = parsed.Sequence;

                var payload = ArrayPool<byte>.Shared.Rent(parsed.PayloadBytes);
                try
                {
                    if (!await ReadExactlyAsync(
                            stream,
                            payload.AsMemory(0, parsed.PayloadBytes),
                            cancellationToken).ConfigureAwait(false))
                    {
                        throw StreamInterrupted();
                    }

                    if (!haveFullFrame)
                    {
                        if (!parsed.IsFull || parsed.X != 0 || parsed.Y != 0 ||
                            parsed.Width != FrameWidth || parsed.Height != FrameHeight)
                        {
                            throw IncompatibleCompanion();
                        }
                        haveFullFrame = true;
                    }

                    yield return new FrameUpdate(
                        parsed.Sequence,
                        parsed.IsFull,
                        parsed.X,
                        parsed.Y,
                        parsed.Width,
                        parsed.Height,
                        parsed.PayloadBytes,
                        payload);
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(payload);
                }
            }

            if (cancellationToken.IsCancellationRequested)
            {
                yield break;
            }

            using var exitTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            exitTimeout.CancelAfter(TimeSpan.FromSeconds(2));
            try
            {
                await process.WaitForExitAsync(exitTimeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw StreamInterrupted("ssh process remained open after its frame stream closed");
            }
            var error = await errorDrain.ConfigureAwait(false);
            throw DescribeExit(process.ExitCode, error);
        }
        finally
        {
            heartbeatCancellation.Cancel();
            try
            {
                if (heartbeatWriter is not null)
                {
                    await heartbeatWriter.ConfigureAwait(false);
                }
            }
            finally
            {
                await TerminateAndDrainAsync(process, started, errorDrain).ConfigureAwait(false);
            }
        }
    }

    private static async Task WriteStreamHeartbeatsAsync(
        StreamWriter input,
        CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(StreamHeartbeatInterval);
        try
        {
            await input.WriteAsync(StreamHeartbeatPulse.AsMemory(), cancellationToken)
                .ConfigureAwait(false);
            await input.FlushAsync(cancellationToken).ConfigureAwait(false);

            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                await input.WriteAsync(StreamHeartbeatPulse.AsMemory(), cancellationToken)
                    .ConfigureAwait(false);
                await input.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (
            exception is IOException or InvalidOperationException or ObjectDisposedException)
        {
            // Process exit or a broken SSH stdin pipe is observed by the frame
            // reader and the stream lease on the tablet. Cleanup still owns the
            // writer before it closes stdin or terminates the process tree.
        }
    }

    private void EnsureLocalSetup()
    {
        if (!_route.CredentialFilesExist)
        {
            throw new FrameStreamException(
                FrameStreamFailureKind.SetupMissing,
                "Mirror setup is incomplete on this PC. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false);
        }
    }

    private ProcessStartInfo CreateStartInfo(
        string remoteCommand,
        bool redirectStandardInput = false)
    {
        return _route.CreateProcessStartInfo(
            remoteCommand: remoteCommand,
            enableCompression: true,
            redirectStandardInput: redirectStandardInput,
            redirectStandardOutput: true,
            redirectStandardError: true);
    }

    private static async Task TerminateAndDrainAsync(
        Process process,
        bool started,
        params Task?[] drains)
    {
        if (!started)
        {
            return;
        }

        try
        {
            if (!process.HasExited && process.StartInfo.RedirectStandardInput)
            {
                try
                {
                    process.StandardInput.Close();
                }
                catch (Exception exception) when (
                    exception is IOException or InvalidOperationException or ObjectDisposedException)
                {
                }

                try
                {
                    using var gracefulTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    await process.WaitForExitAsync(gracefulTimeout.Token).ConfigureAwait(false);
                }
                catch (Exception exception) when (
                    exception is InvalidOperationException or OperationCanceledException or Win32Exception)
                {
                }
            }

            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or Win32Exception)
        {
        }

        try
        {
            using var exitTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await process.WaitForExitAsync(exitTimeout.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or OperationCanceledException or Win32Exception)
        {
        }

        foreach (var drain in drains)
        {
            if (drain is null)
            {
                continue;
            }
            try
            {
                await drain.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }
            catch (Exception exception) when (
                exception is IOException or InvalidOperationException or ObjectDisposedException or TimeoutException)
            {
            }
        }
    }

    private static async Task<bool> ReadExactlyAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            int read;
            try
            {
                read = await stream.ReadAsync(buffer[offset..], cancellationToken).ConfigureAwait(false);
            }
            catch (IOException)
            {
                throw StreamInterrupted();
            }
            if (read == 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    private static bool TryParseHeader(
        ReadOnlySpan<byte> header,
        ulong previousSequence,
        out ParsedFrameUpdate update)
    {
        update = default;
        if (header.Length != HeaderBytes ||
            !header[..4].SequenceEqual("RMM1"u8) ||
            header[4] != 1 ||
            BinaryPrimitives.ReadUInt16LittleEndian(header[6..8]) != HeaderBytes)
        {
            return false;
        }

        var sequence = BinaryPrimitives.ReadUInt64LittleEndian(header[8..16]);
        var x = BinaryPrimitives.ReadUInt16LittleEndian(header[16..18]);
        var y = BinaryPrimitives.ReadUInt16LittleEndian(header[18..20]);
        var width = BinaryPrimitives.ReadUInt16LittleEndian(header[20..22]);
        var height = BinaryPrimitives.ReadUInt16LittleEndian(header[22..24]);
        var payloadBytes = BinaryPrimitives.ReadUInt32LittleEndian(header[24..28]);
        if (sequence <= previousSequence || width == 0 || height == 0 ||
            x + width > FrameWidth || y + height > FrameHeight ||
            payloadBytes != (uint)(width * height * 4) || payloadBytes > (uint)FrameBytes)
        {
            return false;
        }

        update = new ParsedFrameUpdate(
            sequence,
            (header[5] & 1) != 0,
            x,
            y,
            width,
            height,
            (int)payloadBytes);
        return true;
    }

    private static XoviActivationStatus ParseActivationStatus(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || Encoding.UTF8.GetByteCount(value) > 4096)
        {
            throw IncompatibleCompanion("category=activation_status_invalid");
        }

        try
        {
            using var document = JsonDocument.Parse(
                value,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 4,
                });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw IncompatibleCompanion("category=activation_status_invalid");
            }

            string? schema = null;
            string? attempt = null;
            string? outcomeValue = null;
            string? errorCode = null;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (!seen.Add(property.Name) ||
                    property.Value.ValueKind != JsonValueKind.String)
                {
                    throw IncompatibleCompanion("category=activation_status_invalid");
                }

                var propertyValue = property.Value.GetString();
                switch (property.Name)
                {
                    case "schema":
                        schema = propertyValue;
                        break;
                    case "attempt":
                        attempt = propertyValue;
                        break;
                    case "outcome":
                        outcomeValue = propertyValue;
                        break;
                    case "error_code":
                        errorCode = propertyValue;
                        break;
                    default:
                        throw IncompatibleCompanion("category=activation_status_invalid");
                }
            }

            var outcome = outcomeValue switch
            {
                "running" => XoviActivationOutcome.Running,
                "ready_already" => XoviActivationOutcome.ReadyAlready,
                "ready_started" => XoviActivationOutcome.ReadyStarted,
                "failed_unchanged" => XoviActivationOutcome.FailedUnchanged,
                "failed_rolled_back" => XoviActivationOutcome.FailedRolledBack,
                "failed_unknown" => XoviActivationOutcome.FailedUnknown,
                _ => XoviActivationOutcome.Invalid,
            };
            var failed = outcome is XoviActivationOutcome.FailedUnchanged or
                XoviActivationOutcome.FailedRolledBack or
                XoviActivationOutcome.FailedUnknown;
            if (!string.Equals(schema, XoviActivationSchema, StringComparison.Ordinal) ||
                !IsActivationAttempt(attempt) ||
                outcome == XoviActivationOutcome.Invalid ||
                failed != (errorCode is not null) ||
                (errorCode is not null && !IsActivationErrorCode(errorCode)) ||
                seen.Count != (failed ? 4 : 3))
            {
                throw IncompatibleCompanion("category=activation_status_invalid");
            }

            return new XoviActivationStatus(attempt!, outcome, errorCode);
        }
        catch (JsonException)
        {
            throw IncompatibleCompanion("category=activation_status_invalid");
        }
    }

    private static string CreateActivationAttempt() =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

    private static bool IsActivationAttempt(string? value) =>
        value is { Length: 32 } &&
        value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsActivationErrorCode(string value) =>
        value.Length is > 0 and <= 64 &&
        value.All(character =>
            character is >= 'a' and <= 'z' or >= '0' and <= '9' or '_');

    private static bool HasExactOutputLine(string output, string expected)
    {
        using var reader = new StringReader(output);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            if (string.Equals(line, expected, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private static FrameStreamException DescribeActivationFailure(XoviActivationStatus status)
    {
        var technicalDetail =
            $"category=activation_{ActivationOutcomeName(status.Outcome)}; " +
            $"error_code={status.ErrorCode}";
        if (status.ErrorCode is "xovi_configuration_missing" or
            "xovi_worker_executable_failed")
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionMissing,
                "Tablet mirror setup is incomplete. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (status.Outcome == XoviActivationOutcome.FailedUnknown)
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionFailed,
                "The tablet display service stopped in an unverified state. Run Mirror setup again before retrying.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        return new FrameStreamException(
            FrameStreamFailureKind.CompanionNotReady,
            "The tablet display service could not be prepared safely. Run Mirror setup again, then choose Retry.",
            canAutoRetry: false,
            technicalDetail: technicalDetail);
    }

    private static string ActivationOutcomeName(XoviActivationOutcome outcome) => outcome switch
    {
        XoviActivationOutcome.FailedUnchanged => "failed_unchanged",
        XoviActivationOutcome.FailedRolledBack => "failed_rolled_back",
        XoviActivationOutcome.FailedUnknown => "failed_unknown",
        _ => "invalid",
    };

    private static FrameStreamException DisplayRuntimeNotReady() =>
        new(
            FrameStreamFailureKind.CompanionNotReady,
            "The tablet display service is still starting. Mirror will reconnect automatically.",
            canAutoRetry: true,
            technicalDetail: "category=display_runtime_not_ready");

    private static FrameStreamException DescribePreparationExit(
        int exitCode,
        string standardError)
    {
        var technicalDetail = FormatTechnicalDetail(exitCode, standardError);
        if (standardError.Contains("rmmirror: companion_missing", StringComparison.OrdinalIgnoreCase))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionMissing,
                "Tablet mirror setup is incomplete. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (ContainsAny(
                standardError,
                "rmmirror: display_runtime_not_ready"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionNotReady,
                "The tablet display service is still starting. Mirror will reconnect automatically.",
                canAutoRetry: true,
                technicalDetail: technicalDetail);
        }
        if (ContainsAny(
                standardError,
                "rmmirror: sleep_cancel_failed",
                "rmmirror: input_restore_not_ready"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionNotReady,
                "The tablet display service could not be prepared safely. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        return DescribeExit(exitCode, standardError);
    }

    private static FrameStreamException DescribeExit(int exitCode, string standardError)
    {
        var technicalDetail = FormatTechnicalDetail(exitCode, standardError);
        if (ContainsAny(
                standardError,
                "REMOTE HOST IDENTIFICATION HAS CHANGED",
                "Host key verification failed"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.HostIdentityChanged,
                "The tablet's secure identity changed. Run Mirror setup again before retrying.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (exitCode == 255 && ContainsAny(
                standardError,
                "Permission denied",
                "no supported authentication methods available",
                "Too many authentication failures"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.AuthenticationRejected,
                "This PC is no longer authorized to connect to the tablet. Run Mirror setup again before retrying.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (ContainsAny(
                standardError,
                "rmmirror-probe: stream_heartbeat_timeout"))
        {
            return StreamInterrupted("exit=" + exitCode + "; category=stream_heartbeat_timeout");
        }
        if (ContainsAny(
                standardError,
                "rmmirror-probe: stream_broker_",
                "rmmirror-probe: stream_not_ready",
                "rmmirror-probe: stream_xochitl_not_running",
                "rmmirror-probe: stream_process_memory_"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionNotReady,
                "The tablet display service is restarting. Mirror will reconnect automatically.",
                canAutoRetry: true,
                technicalDetail: technicalDetail);
        }
        if (ContainsAny(standardError, "not found", "No such file", "rmmirror: companion_missing"))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionMissing,
                "The mirror companion is missing on the tablet. Run Mirror setup again, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (standardError.Contains("rmmirror-probe:", StringComparison.OrdinalIgnoreCase))
        {
            return new FrameStreamException(
                FrameStreamFailureKind.CompanionFailed,
                "The tablet mirror companion stopped unexpectedly. Copy the connection details, then choose Retry.",
                canAutoRetry: false,
                technicalDetail: technicalDetail);
        }
        if (ContainsAny(
                standardError,
                "Connection refused",
                "Connection timed out",
                "Operation timed out",
                "No route to host",
                "Network is unreachable",
                "Connection reset",
                "Connection closed",
                "Broken pipe",
                "kex_exchange_identification"))
        {
            return SecureConnectionUnavailable(technicalDetail);
        }
        if (exitCode == 255)
        {
            return SecureConnectionUnavailable(technicalDetail);
        }
        return StreamInterrupted(technicalDetail);
    }

    private static bool ContainsAny(string value, params string[] candidates) =>
        candidates.Any(candidate => value.Contains(candidate, StringComparison.OrdinalIgnoreCase));

    private static string FormatTechnicalDetail(int exitCode, string standardError)
    {
        var category = standardError switch
        {
            var value when ContainsAny(
                value,
                "REMOTE HOST IDENTIFICATION HAS CHANGED",
                "Host key verification failed") => "host_identity_changed",
            var value when ContainsAny(
                value,
                "Permission denied",
                "no supported authentication methods available",
                "Too many authentication failures") => "authentication_rejected",
            var value when ContainsAny(value, "rmmirror: companion_missing", "rmmirror: xovi_missing") =>
                "companion_missing",
            var value when value.Contains("rmmirror: display_runtime_not_ready", StringComparison.OrdinalIgnoreCase) =>
                "display_runtime_not_ready",
            var value when value.Contains("rmmirror: xovi_configuration_invalid", StringComparison.OrdinalIgnoreCase) =>
                "xovi_configuration_invalid",
            var value when value.Contains("rmmirror-probe:", StringComparison.OrdinalIgnoreCase) =>
                "companion_reported_failure",
            var value when
                value.Contains("Timeout, server", StringComparison.OrdinalIgnoreCase) &&
                value.Contains("not responding", StringComparison.OrdinalIgnoreCase) =>
                "ssh_keepalive_timeout",
            var value when ContainsAny(
                value,
                "Connection refused",
                "Connection timed out",
                "Operation timed out",
                "No route to host",
                "Network is unreachable",
                "Connection reset",
                "Connection closed",
                "Broken pipe",
                "kex_exchange_identification") => "connection_unavailable",
            var value when string.IsNullOrWhiteSpace(value) => "stderr_empty",
            _ => "ssh_process_failed",
        };
        return $"exit={exitCode}; category={category}";
    }

    private static FrameStreamException SecureConnectionUnavailable(string? technicalDetail = null) =>
        new(
            FrameStreamFailureKind.SecureConnectionUnavailable,
            "The secure connection is not ready. Mirror will reconnect automatically.",
            canAutoRetry: true,
            technicalDetail: technicalDetail);

    private static FrameStreamException IncompatibleCompanion(string? technicalDetail = null) =>
        new(
            FrameStreamFailureKind.ProtocolMismatch,
            "The tablet mirror companion is incompatible with this app. Update Mirror setup before retrying.",
            canAutoRetry: false,
            technicalDetail: technicalDetail);

    private static FrameStreamException StreamInterrupted(string? technicalDetail = null) =>
        new(
            FrameStreamFailureKind.StreamInterrupted,
            "The tablet display connection stopped. Mirror will reconnect automatically.",
            canAutoRetry: true,
            technicalDetail: technicalDetail);

    private readonly record struct ParsedFrameUpdate(
        ulong Sequence,
        bool IsFull,
        int X,
        int Y,
        int Width,
        int Height,
        int PayloadBytes);

    private sealed record SshCommandResult(
        int ExitCode,
        string StandardOutput,
        string StandardError);

    private sealed record XoviActivationStatus(
        string Attempt,
        XoviActivationOutcome Outcome,
        string? ErrorCode);

    private enum XoviActivationOutcome
    {
        Invalid,
        Running,
        ReadyAlready,
        ReadyStarted,
        FailedUnchanged,
        FailedRolledBack,
        FailedUnknown,
    }

    private sealed class SshCommandTimedOutException : Exception
    {
    }
}

public sealed record FrameUpdate(
    ulong Sequence,
    bool IsFull,
    int X,
    int Y,
    int Width,
    int Height,
    int PayloadBytes,
    byte[] Buffer)
{
    public ReadOnlySpan<byte> Payload => Buffer.AsSpan(0, PayloadBytes);
}

public sealed record DisplayPreparationResult(bool StartedXovi);

public enum FrameStreamFailureKind
{
    SetupMissing,
    OpenSshUnavailable,
    ConnectionProcessUnavailable,
    HostIdentityChanged,
    AuthenticationRejected,
    SecureConnectionUnavailable,
    CompanionMissing,
    CompanionNotReady,
    CompanionFailed,
    ProtocolMismatch,
    StreamInterrupted,
}

public sealed class FrameStreamException : Exception
{
    public FrameStreamException(
        FrameStreamFailureKind kind,
        string message,
        bool canAutoRetry,
        Exception? innerException = null,
        string? technicalDetail = null)
        : base(message, innerException)
    {
        Kind = kind;
        CanAutoRetry = canAutoRetry;
        TechnicalDetail = technicalDetail;
    }

    public FrameStreamFailureKind Kind { get; }

    public bool CanAutoRetry { get; }

    public string? TechnicalDetail { get; }
}
