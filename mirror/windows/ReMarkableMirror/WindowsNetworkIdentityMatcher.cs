using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace ReMarkableMirror;

/// <summary>
/// Recomputes the same local route/interface/network identity material used by
/// the prerequisite installer. It never opens a connection to the tablet.
/// </summary>
internal static class WindowsNetworkIdentityMatcher
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(5);
    private const string ResultPrefix = "rmmirror.network/v1\t";
    private const string ProbeScript = """
        $ErrorActionPreference = 'Stop'
        $remoteAddress = $env:RMMIRROR_NETWORK_REMOTE
        $routeResult = @(Find-NetRoute -RemoteIPAddress $remoteAddress -ErrorAction Stop)
        $interfaceIndexes = @(
            $routeResult |
                ForEach-Object { [int]$_.InterfaceIndex } |
                Sort-Object -Unique
        )
        if ($interfaceIndexes.Count -ne 1) { throw 'ambiguous route' }
        $adapter = Get-NetAdapter -InterfaceIndex $interfaceIndexes[0] -ErrorAction Stop
        $interfaceGuid = ([guid]$adapter.InterfaceGuid).ToString('B').ToUpperInvariant()
        $connectionProfiles = @(Get-NetConnectionProfile -InterfaceIndex $interfaceIndexes[0] -ErrorAction Stop)
        if ($connectionProfiles.Count -ne 1 -or [string]::IsNullOrWhiteSpace($connectionProfiles[0].Name)) {
            throw 'missing network profile'
        }
        $identityMaterial = "{0}`n{1}" -f @(
            $connectionProfiles[0].Name,
            $connectionProfiles[0].NetworkCategory
        )
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $identityHash = $sha256.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($identityMaterial)
            )
        }
        finally {
            $sha256.Dispose()
        }
        $networkIdentity = 'sha256:' + [BitConverter]::ToString($identityHash).Replace('-', '').ToLowerInvariant()
        [Console]::Out.WriteLine("rmmirror.network/v1`t{0}`t{1}" -f @($interfaceGuid, $networkIdentity))
        """;

    private static readonly string EncodedProbeScript = Convert.ToBase64String(
        Encoding.Unicode.GetBytes(ProbeScript));

    public static async Task<WindowsNetworkMatchResult> EvaluateAsync(
        string remoteAddress,
        string expectedInterfaceId,
        string expectedNetworkIdentity,
        CancellationToken cancellationToken)
    {
        if (!Guid.TryParse(expectedInterfaceId, out var expectedInterfaceGuid) ||
            string.IsNullOrWhiteSpace(expectedNetworkIdentity))
        {
            return WindowsNetworkMatchResult.Mismatch;
        }

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        process.StartInfo.ArgumentList.Add("-NoLogo");
        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-NonInteractive");
        process.StartInfo.ArgumentList.Add("-EncodedCommand");
        process.StartInfo.ArgumentList.Add(EncodedProbeScript);
        process.StartInfo.Environment["RMMIRROR_NETWORK_REMOTE"] = remoteAddress;

        Task<string>? outputDrain = null;
        Task<string>? errorDrain = null;
        var started = false;
        try
        {
            try
            {
                if (!process.Start())
                {
                    return WindowsNetworkMatchResult.Unavailable;
                }
                started = true;
                SshChildProcessJob.AssignOrTerminate(process);
            }
            catch (Win32Exception)
            {
                return WindowsNetworkMatchResult.Unavailable;
            }

            outputDrain = process.StandardOutput.ReadToEndAsync();
            errorDrain = process.StandardError.ReadToEndAsync();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return WindowsNetworkMatchResult.Unavailable;
            }
            if (process.ExitCode != 0)
            {
                return WindowsNetworkMatchResult.Unavailable;
            }

            var output = await outputDrain.ConfigureAwait(false);
            var resultLine = output
                .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
                .SingleOrDefault(line => line.StartsWith(ResultPrefix, StringComparison.Ordinal));
            if (resultLine is null)
            {
                return WindowsNetworkMatchResult.Unavailable;
            }

            var fields = resultLine.Split('\t');
            if (fields.Length != 3 ||
                !Guid.TryParse(fields[1], out var currentInterfaceGuid))
            {
                return WindowsNetworkMatchResult.Unavailable;
            }
            return currentInterfaceGuid == expectedInterfaceGuid &&
                string.Equals(fields[2], expectedNetworkIdentity, StringComparison.Ordinal)
                    ? WindowsNetworkMatchResult.Match
                    : WindowsNetworkMatchResult.Mismatch;
        }
        catch (Exception exception) when (exception is
            InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return WindowsNetworkMatchResult.Unavailable;
        }
        finally
        {
            if (started)
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
            if (outputDrain is not null)
            {
                await IgnoreFailureAsync(outputDrain.WaitAsync(TimeSpan.FromSeconds(1)))
                    .ConfigureAwait(false);
            }
            if (errorDrain is not null)
            {
                await IgnoreFailureAsync(errorDrain.WaitAsync(TimeSpan.FromSeconds(1)))
                    .ConfigureAwait(false);
            }
        }
    }

    private static async Task IgnoreFailureAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is
            IOException or ObjectDisposedException or TimeoutException)
        {
        }
    }
}

internal enum WindowsNetworkMatchResult
{
    Match,
    Mismatch,
    Unavailable,
}
