using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace ReMarkableMirror.Files;

internal sealed class SshWebInterfaceTunnel : IAsyncDisposable
{
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(5);

    private readonly SshRoute _route;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);

    private Process? _process;
    private Task<string>? _stderrTask;
    private Uri? _baseUri;
    private bool _disposed;

    public SshWebInterfaceTunnel(
        string host,
        string? identityFile = null,
        string? knownHostsFile = null) :
        this(new SshRoute(
            host,
            identityFile,
            knownHostsFile,
            filesTargetHost: host))
    {
    }

    internal SshWebInterfaceTunnel(SshRoute route)
    {
        _route = route ?? throw new ArgumentNullException(nameof(route));
    }

    public async Task<Uri> GetBaseUriAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_process is { HasExited: false } existingProcess &&
                _baseUri is { } existingBaseUri)
            {
                try
                {
                    var ownership = TcpListenerOwnershipVerifier.GetOwnership(
                        existingBaseUri.Port,
                        existingProcess.Id);
                    if (ownership == TcpListenerOwnership.ExpectedProcess &&
                        !existingProcess.HasExited)
                    {
                        return existingBaseUri;
                    }
                }
                catch (Win32Exception exception)
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    throw new FileTransferException(
                        FileTransferFailure.Configuration,
                        "Windows could not verify the secure tablet file connection.",
                        exception);
                }
            }

            await StopProcessAsync().ConfigureAwait(false);
            ValidateCredentials();

            for (var attempt = 0; attempt < 2; attempt++)
            {
                var localPort = GetAvailableLoopbackPort();
                var process = new Process
                {
                    StartInfo = CreateStartInfo(localPort),
                };

                try
                {
                    if (!process.Start())
                    {
                        process.Dispose();
                        throw new FileTransferException(
                            FileTransferFailure.Connection,
                            "Windows could not start the secure tablet file connection.");
                    }
                }
                catch (Win32Exception exception)
                {
                    process.Dispose();
                    throw new FileTransferException(
                        FileTransferFailure.Configuration,
                        "Windows OpenSSH is not available.",
                        exception);
                }
                catch
                {
                    process.Dispose();
                    throw;
                }

                try
                {
                    SshChildProcessJob.AssignOrTerminate(process);
                }
                catch (Win32Exception exception)
                {
                    TerminateAndDisposeProcess(process);
                    throw new FileTransferException(
                        FileTransferFailure.Configuration,
                        "Windows could not secure the tablet file connection lifetime.",
                        exception);
                }
                catch
                {
                    TerminateAndDisposeProcess(process);
                    throw;
                }

                _process = process;
                try
                {
                    var stderrTask = process.StandardError.ReadToEndAsync();
                    _stderrTask = stderrTask;
                    var baseUri = new Uri(
                        $"http://127.0.0.1:{localPort}/",
                        UriKind.Absolute);
                    using var startupCancellation =
                        CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    startupCancellation.CancelAfter(StartupTimeout);
                    await WaitUntilListeningAsync(
                            process,
                            stderrTask,
                            localPort,
                            startupCancellation.Token)
                        .ConfigureAwait(false);

                    if (TcpListenerOwnershipVerifier.GetOwnership(localPort, process.Id) !=
                        TcpListenerOwnership.ExpectedProcess)
                    {
                        throw new UnexpectedListenerOwnerException();
                    }

                    if (process.HasExited)
                    {
                        var stderr = await stderrTask.ConfigureAwait(false);
                        throw new TunnelStartException(stderr, process.ExitCode);
                    }

                    _baseUri = baseUri;
                    return baseUri;
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    var stderr = await StopProcessAsync().ConfigureAwait(false);
                    throw DescribeFailure(
                        stderr,
                        "The secure tablet file connection timed out.");
                }
                catch (OperationCanceledException)
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    throw;
                }
                catch (TunnelStartException exception)
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    if (attempt == 0 && IsLocalBindRace(exception.StandardError))
                    {
                        continue;
                    }

                    throw DescribeFailure(
                        exception.StandardError,
                        $"The secure tablet file connection stopped with exit code {exception.ExitCode}.");
                }
                catch (UnexpectedListenerOwnerException)
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    if (attempt == 0)
                    {
                        continue;
                    }

                    throw new FileTransferException(
                        FileTransferFailure.Connection,
                        "Windows could not safely reserve a local port for the tablet file connection.");
                }
                catch (Win32Exception exception)
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    throw new FileTransferException(
                        FileTransferFailure.Configuration,
                        "Windows could not verify the secure tablet file connection.",
                        exception);
                }
                catch
                {
                    await StopProcessAsync().ConfigureAwait(false);
                    throw;
                }
            }

            throw new FileTransferException(
                FileTransferFailure.Connection,
                "Windows could not reserve a local port for the tablet file connection.");
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            await StopProcessAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
            _lifecycleGate.Dispose();
        }
    }

    private void ValidateCredentials()
    {
        if (!File.Exists(_route.IdentityFile))
        {
            throw new FileTransferException(
                FileTransferFailure.Configuration,
                "Mirror setup is missing the tablet SSH identity file.");
        }

        if (!File.Exists(_route.KnownHostsFile))
        {
            throw new FileTransferException(
                FileTransferFailure.Configuration,
                "Mirror setup is missing the pinned tablet known-hosts file.");
        }
    }

    private ProcessStartInfo CreateStartInfo(int localPort)
    {
        return _route.CreateProcessStartInfo(
            noRemoteCommand: true,
            disablePseudoTerminal: true,
            localForwardPort: localPort,
            redirectStandardError: true);
    }

    private static int GetAvailableLoopbackPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        finally
        {
            listener.Stop();
        }
    }

    private static async Task WaitUntilListeningAsync(
        Process process,
        Task<string> stderrTask,
        int localPort,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                var stderr = await stderrTask.ConfigureAwait(false);
                throw new TunnelStartException(stderr, process.ExitCode);
            }

            var ownership = TcpListenerOwnershipVerifier.GetOwnership(localPort, process.Id);
            if (ownership == TcpListenerOwnership.ExpectedProcess)
            {
                return;
            }

            if (ownership == TcpListenerOwnership.UnexpectedProcess)
            {
                throw new UnexpectedListenerOwnerException();
            }

            await Task.Delay(TimeSpan.FromMilliseconds(40), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private async Task<string> StopProcessAsync()
    {
        var process = _process;
        var stderrTask = _stderrTask;
        _process = null;
        _stderrTask = null;
        _baseUri = null;

        if (process is null)
        {
            return string.Empty;
        }

        try
        {
            if (!process.HasExited)
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException)
                {
                }
            }

            using var waitCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try
            {
                await process.WaitForExitAsync(waitCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }

            return stderrTask is null || !stderrTask.IsCompleted
                ? string.Empty
                : (await stderrTask.ConfigureAwait(false)).Trim();
        }
        finally
        {
            process.Dispose();
        }
    }

    private static void TerminateAndDisposeProcess(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }
        finally
        {
            process.Dispose();
        }
    }

    private static FileTransferException DescribeFailure(
        string stderr,
        string fallbackMessage)
    {
        if (stderr.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase))
        {
            return new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet host key does not match the pinned known-hosts entry.");
        }

        if (stderr.Contains("Permission denied", StringComparison.OrdinalIgnoreCase))
        {
            return new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet rejected the configured SSH identity.");
        }

        if (stderr.Contains("Connection refused", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("Connection timed out", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("No route to host", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("Network is unreachable", StringComparison.OrdinalIgnoreCase))
        {
            return new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet SSH connection is not reachable.");
        }

        return new FileTransferException(
            FileTransferFailure.Connection,
            fallbackMessage);
    }

    private static bool IsLocalBindRace(string stderr) =>
        stderr.Contains("Address already in use", StringComparison.OrdinalIgnoreCase) ||
        stderr.Contains("cannot listen to port", StringComparison.OrdinalIgnoreCase);

    private sealed class UnexpectedListenerOwnerException : Exception;

    private sealed class TunnelStartException(string standardError, int exitCode) : Exception
    {
        public string StandardError { get; } = standardError;

        public int ExitCode { get; } = exitCode;
    }
}
