using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security;
using System.Security.Cryptography;
using Microsoft.Win32;

namespace ReMarkableMirror;

internal sealed class OpenSshSetupClient
{
    private const string UsbTabletHost = "10.11.99.1";
    private const string UsbWindowsHost = "10.11.99.11";
    private const int UsbPrefixLength = 27;
    private const int MaximumKnownHostsBytes = 64 * 1024;
    private const SocketOptionName IpUnicastInterface = (SocketOptionName)31;
    private static readonly IPAddress UsbTabletAddress = IPAddress.Parse(UsbTabletHost);
    private static readonly IPAddress UsbWindowsAddress = IPAddress.Parse(UsbWindowsHost);

    private const string TabletSupportCommand = """
        tablet_model="$(tr -d '\000' < /sys/firmware/devicetree/base/model 2>/dev/null || true)"
        if test "$tablet_model" != 'reMarkable Chiappa'; then
          printf '%s\n' 'RMMIRROR_UNSUPPORTED_TABLET=1'
          exit 83
        fi
        """;

    private const string AuthorizationCommand = TabletSupportCommand + "\n" + """
        set -eu
        umask 077
        key_type='ssh-ed25519'
        key_blob='PUBLIC_KEY_BLOB'
        mkdir -p /home/root/.ssh
        test ! -L /home/root/.ssh
        if test -e /home/root/.ssh/authorized_keys || \
            test -L /home/root/.ssh/authorized_keys; then
          test -f /home/root/.ssh/authorized_keys
          test ! -L /home/root/.ssh/authorized_keys
        else
          : > /home/root/.ssh/authorized_keys
        fi
        chmod 0700 /home/root/.ssh
        chmod 0600 /home/root/.ssh/authorized_keys
        if ! awk -v type="$key_type" -v blob="$key_blob" \
            '$1 == type && $2 == blob { found = 1 } END { exit !found }' \
            /home/root/.ssh/authorized_keys; then
          printf '%s %s %s\n' "$key_type" "$key_blob" 'remarkable-mirror' >> \
            /home/root/.ssh/authorized_keys
        fi
        printf '%s\n' 'RMMIRROR_HOST_AUTHORIZED=1'
        """;

    private readonly SshRoute _route = new(UsbTabletHost);

    public async Task<OpenSshAuthorizationResult> AuthorizeAsync(
        string? oneTimePassword,
        CancellationToken cancellationToken)
    {
        var usbRoute = FindDirectUsbRoute();
        if (usbRoute is null ||
            !await HasSshBannerAsync(usbRoute, cancellationToken).ConfigureAwait(false))
        {
            return OpenSshAuthorizationResult.UsbUnavailable;
        }

        var identity = await EnsureIdentityAsync(cancellationToken).ConfigureAwait(false);
        if (identity.Status is not OpenSshIdentityStatus.Ready)
        {
            return identity.Status is OpenSshIdentityStatus.ToolUnavailable
                ? OpenSshAuthorizationResult.OpenSshUnavailable
                : OpenSshAuthorizationResult.LocalCredentialFailure;
        }

        var knownHostsPath = _route.KnownHostsFile;
        var knownHostsDirectory = Path.GetDirectoryName(knownHostsPath)!;
        if (!EnsureCredentialDirectory(knownHostsDirectory))
        {
            return OpenSshAuthorizationResult.LocalCredentialFailure;
        }

        var temporaryKnownHosts = Path.Combine(
            knownHostsDirectory,
            $".remarkable_known_hosts.{Guid.NewGuid():N}.tmp");
        try
        {
            var hasExistingPin = File.Exists(knownHostsPath);
            if (hasExistingPin)
            {
                var existing = new FileInfo(knownHostsPath);
                if (!IsSafeCredentialFile(existing, MaximumKnownHostsBytes))
                {
                    return OpenSshAuthorizationResult.LocalCredentialFailure;
                }
                DeviceProfileStore.ApplyCurrentUserOnlyAcl(existing);
                File.Copy(knownHostsPath, temporaryKnownHosts, overwrite: false);
            }
            else
            {
                using var _ = new FileStream(
                    temporaryKnownHosts,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None);
            }
            DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(temporaryKnownHosts));

            var proof = await RunKeyProofAsync(
                    usbRoute,
                    temporaryKnownHosts,
                    hasExistingPin ? "yes" : "accept-new",
                    cancellationToken)
                .ConfigureAwait(false);
            if (proof is OpenSshAuthorizationResult.Authorized)
            {
                if (!await HasOnePinnedEd25519KeyAsync(
                        temporaryKnownHosts,
                        cancellationToken)
                    .ConfigureAwait(false))
                {
                    return OpenSshAuthorizationResult.HostIdentityRejected;
                }
                if (!hasExistingPin)
                {
                    PublishKnownHosts(temporaryKnownHosts, knownHostsPath);
                    temporaryKnownHosts = string.Empty;
                }
                return OpenSshAuthorizationResult.Authorized;
            }
            if (proof is OpenSshAuthorizationResult.HostIdentityRejected or
                OpenSshAuthorizationResult.UnsupportedTablet)
            {
                return proof;
            }

            if (string.IsNullOrEmpty(oneTimePassword))
            {
                return OpenSshAuthorizationResult.PasswordRequired;
            }
            try
            {
                AskPassBridge.ValidatePassword(oneTimePassword);
            }
            catch (ArgumentException)
            {
                return OpenSshAuthorizationResult.PasswordRejected;
            }

            var authorization = await RunPasswordAuthorizationAsync(
                    usbRoute,
                    identity.PublicKeyBlob!,
                    temporaryKnownHosts,
                    hasExistingPin,
                    oneTimePassword,
                    cancellationToken)
                .ConfigureAwait(false);
            if (authorization is not OpenSshAuthorizationResult.Authorized)
            {
                return authorization;
            }

            var keyProof = await RunKeyProofAsync(
                    usbRoute,
                    temporaryKnownHosts,
                    "yes",
                    cancellationToken)
                .ConfigureAwait(false);
            if (keyProof is not OpenSshAuthorizationResult.Authorized ||
                !await HasOnePinnedEd25519KeyAsync(
                        temporaryKnownHosts,
                        cancellationToken)
                    .ConfigureAwait(false))
            {
                return keyProof is OpenSshAuthorizationResult.HostIdentityRejected or
                    OpenSshAuthorizationResult.UnsupportedTablet
                    ? keyProof
                    : OpenSshAuthorizationResult.KeyProofFailed;
            }

            PublishKnownHosts(temporaryKnownHosts, knownHostsPath);
            temporaryKnownHosts = string.Empty;
            return OpenSshAuthorizationResult.Authorized;
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            SecurityException or
            NotSupportedException or
            ArgumentException)
        {
            return OpenSshAuthorizationResult.LocalCredentialFailure;
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporaryKnownHosts))
            {
                TryDelete(temporaryKnownHosts);
            }
        }
    }

    private async Task<OpenSshIdentityResult> EnsureIdentityAsync(
        CancellationToken cancellationToken)
    {
        var identityPath = _route.IdentityFile;
        var identityDirectory = Path.GetDirectoryName(identityPath)!;
        if (!EnsureCredentialDirectory(identityDirectory))
        {
            return new(OpenSshIdentityStatus.Invalid, null);
        }

        if (File.Exists(identityPath))
        {
            try
            {
                var existing = new FileInfo(identityPath);
                if (!IsSafeCredentialFile(existing, 64 * 1024))
                {
                    return new(OpenSshIdentityStatus.Invalid, null);
                }
                DeviceProfileStore.ApplyCurrentUserOnlyAcl(existing);
                return await DerivePublicKeyAsync(identityPath, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is
                IOException or
                UnauthorizedAccessException or
                SecurityException or
                NotSupportedException)
            {
                return new(OpenSshIdentityStatus.Invalid, null);
            }
        }

        var publicPath = identityPath + ".pub";
        if (File.Exists(publicPath))
        {
            return new(OpenSshIdentityStatus.Invalid, null);
        }

        var temporaryIdentity = Path.Combine(
            identityDirectory,
            $".{Path.GetFileName(identityPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var keygen = CreateProcessStartInfo("ssh-keygen.exe",
                "-q", "-t", "ed25519", "-N", string.Empty,
                "-C", "remarkable-mirror", "-f", temporaryIdentity);
            var generated = await RunChildAsync(keygen, TimeSpan.FromSeconds(10), cancellationToken)
                .ConfigureAwait(false);
            if (!generated.Started)
            {
                return new(OpenSshIdentityStatus.ToolUnavailable, null);
            }
            if (generated.ExitCode != 0 ||
                !File.Exists(temporaryIdentity) ||
                !File.Exists(temporaryIdentity + ".pub"))
            {
                return new(OpenSshIdentityStatus.Invalid, null);
            }

            DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(temporaryIdentity));
            DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(temporaryIdentity + ".pub"));
            var derived = await DerivePublicKeyAsync(temporaryIdentity, cancellationToken)
                .ConfigureAwait(false);
            if (derived.Status is not OpenSshIdentityStatus.Ready)
            {
                return derived;
            }

            File.Move(temporaryIdentity, identityPath);
            File.Move(temporaryIdentity + ".pub", publicPath);
            DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(identityPath));
            DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(publicPath));
            temporaryIdentity = string.Empty;
            return derived;
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            SecurityException or
            NotSupportedException)
        {
            return new(OpenSshIdentityStatus.Invalid, null);
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporaryIdentity))
            {
                TryDelete(temporaryIdentity);
                TryDelete(temporaryIdentity + ".pub");
            }
        }
    }

    private static async Task<OpenSshIdentityResult> DerivePublicKeyAsync(
        string identityPath,
        CancellationToken cancellationToken)
    {
        var keygen = CreateProcessStartInfo("ssh-keygen.exe", "-y", "-f", identityPath);
        var result = await RunChildAsync(keygen, TimeSpan.FromSeconds(5), cancellationToken)
            .ConfigureAwait(false);
        if (!result.Started)
        {
            return new(OpenSshIdentityStatus.ToolUnavailable, null);
        }
        if (result.ExitCode != 0)
        {
            return new(OpenSshIdentityStatus.Invalid, null);
        }

        var fields = result.StandardOutput.Trim().Split(
            (char[]?)null,
            StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 2 ||
            !string.Equals(fields[0], "ssh-ed25519", StringComparison.Ordinal) ||
            !IsValidPublicKeyBlob(fields[1]))
        {
            return new(OpenSshIdentityStatus.Invalid, null);
        }
        return new(OpenSshIdentityStatus.Ready, fields[1]);
    }

    private async Task<OpenSshAuthorizationResult> RunPasswordAuthorizationAsync(
        DirectUsbRoute usbRoute,
        string publicKeyBlob,
        string knownHostsPath,
        bool hasExistingPin,
        string password,
        CancellationToken cancellationToken)
    {
        var command = AuthorizationCommand.Replace(
            "PUBLIC_KEY_BLOB",
            publicKeyBlob,
            StringComparison.Ordinal);
        var info = CreateSshStartInfo(
            usbRoute,
            knownHostsPath,
            command,
            batchMode: false,
            strictHostKeyChecking: hasExistingPin ? "yes" : "accept-new");
        info.ArgumentList.Insert(info.ArgumentList.Count - 2, "-o");
        info.ArgumentList.Insert(info.ArgumentList.Count - 2, "PubkeyAuthentication=no");
        info.ArgumentList.Insert(info.ArgumentList.Count - 2, "-o");
        info.ArgumentList.Insert(
            info.ArgumentList.Count - 2,
            "PreferredAuthentications=password");
        info.ArgumentList.Insert(info.ArgumentList.Count - 2, "-o");
        info.ArgumentList.Insert(info.ArgumentList.Count - 2, "NumberOfPasswordPrompts=1");

        var processPath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(processPath))
        {
            return OpenSshAuthorizationResult.OpenSshUnavailable;
        }

        var pipeName = AskPassBridge.CreatePipeName();
        using var pipe = AskPassBridge.CreateServer(pipeName);
        info.Environment["SSH_ASKPASS"] = processPath;
        info.Environment["SSH_ASKPASS_REQUIRE"] = "force";
        info.Environment["DISPLAY"] = "remarkable-mirror";
        info.Environment[AskPassBridge.ModeVariable] = AskPassBridge.Mode;
        info.Environment[AskPassBridge.PipeVariable] = pipeName;

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var passwordTransfer = AskPassBridge.SendAsync(pipe, password, timeout.Token);
        ChildProcessResult result;
        try
        {
            result = await RunChildAsync(info, Timeout.InfiniteTimeSpan, timeout.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The bounded authorization window elapsed. That is a stalled
            // exchange, not the tablet refusing the password.
            return OpenSshAuthorizationResult.AuthorizationTimedOut;
        }
        finally
        {
            timeout.Cancel();
            try
            {
                await passwordTransfer.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
            catch (IOException)
            {
            }
        }

        if (!result.Started)
        {
            return OpenSshAuthorizationResult.OpenSshUnavailable;
        }
        if (ContainsHostIdentityFailure(result.StandardError))
        {
            return OpenSshAuthorizationResult.HostIdentityRejected;
        }
        if (result.StandardOutput.Contains(
                "RMMIRROR_UNSUPPORTED_TABLET=1",
                StringComparison.Ordinal))
        {
            return OpenSshAuthorizationResult.UnsupportedTablet;
        }
        return result.ExitCode == 0 && result.StandardOutput.Contains(
            "RMMIRROR_HOST_AUTHORIZED=1",
            StringComparison.Ordinal)
            ? OpenSshAuthorizationResult.Authorized
            : OpenSshAuthorizationResult.PasswordRejected;
    }

    private async Task<OpenSshAuthorizationResult> RunKeyProofAsync(
        DirectUsbRoute usbRoute,
        string knownHostsPath,
        string strictHostKeyChecking,
        CancellationToken cancellationToken)
    {
        var info = CreateSshStartInfo(
            usbRoute,
            knownHostsPath,
            TabletSupportCommand + "\nprintf '%s\\n' 'RMMIRROR_KEY_VERIFIED=1'",
            batchMode: true,
            strictHostKeyChecking);
        var result = await RunChildAsync(info, TimeSpan.FromSeconds(10), cancellationToken)
            .ConfigureAwait(false);
        if (!result.Started)
        {
            return OpenSshAuthorizationResult.OpenSshUnavailable;
        }
        if (ContainsHostIdentityFailure(result.StandardError))
        {
            return OpenSshAuthorizationResult.HostIdentityRejected;
        }
        if (result.StandardOutput.Contains(
                "RMMIRROR_UNSUPPORTED_TABLET=1",
                StringComparison.Ordinal))
        {
            return OpenSshAuthorizationResult.UnsupportedTablet;
        }
        return result.ExitCode == 0 && result.StandardOutput.Contains(
            "RMMIRROR_KEY_VERIFIED=1",
            StringComparison.Ordinal)
            ? OpenSshAuthorizationResult.Authorized
            : OpenSshAuthorizationResult.KeyProofFailed;
    }

    private ProcessStartInfo CreateSshStartInfo(
        DirectUsbRoute usbRoute,
        string knownHostsPath,
        string remoteCommand,
        bool batchMode,
        string strictHostKeyChecking)
    {
        var info = CreateProcessStartInfo("ssh.exe");
        foreach (var argument in new[]
        {
            "-F", "NUL",
            "-i", _route.IdentityFile,
            "-o", $"BatchMode={(batchMode ? "yes" : "no")}",
            "-o", "IdentitiesOnly=yes",
            "-o", $"StrictHostKeyChecking={strictHostKeyChecking}",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "-o", $"UserKnownHostsFile={knownHostsPath}",
            "-o", "GlobalKnownHostsFile=NUL",
            "-o", $"HostKeyAlias={_route.HostKeyAlias}",
            "-o", "HashKnownHosts=no",
            "-o", "UpdateHostKeys=no",
            "-o", "CheckHostIP=no",
            "-o", $"BindAddress={UsbWindowsHost}",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-T",
            $"root@{UsbTabletHost}",
            remoteCommand.ReplaceLineEndings("\n"),
        })
        {
            info.ArgumentList.Add(argument);
        }
        return info;
    }

    private async Task<bool> HasOnePinnedEd25519KeyAsync(
        string knownHostsPath,
        CancellationToken cancellationToken)
    {
        var info = CreateProcessStartInfo(
            "ssh-keygen.exe", "-F", _route.HostKeyAlias, "-f", knownHostsPath);
        var result = await RunChildAsync(info, TimeSpan.FromSeconds(5), cancellationToken)
            .ConfigureAwait(false);
        if (!result.Started || result.ExitCode != 0)
        {
            return false;
        }

        var records = result.StandardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Where(line => !line.StartsWith('#'))
            .ToArray();
        if (records.Length != 1)
        {
            return false;
        }

        var fields = records[0].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var offset = fields.Length > 0 && fields[0].StartsWith('@') ? 1 : 0;
        return offset == 0 &&
            fields.Length >= 3 &&
            string.Equals(fields[1], "ssh-ed25519", StringComparison.Ordinal) &&
            IsValidPublicKeyBlob(fields[2]);
    }

    private static DirectUsbRoute? FindDirectUsbRoute()
    {
        try
        {
            var matches = NetworkInterface.GetAllNetworkInterfaces()
                .Where(networkInterface =>
                    networkInterface.OperationalStatus is OperationalStatus.Up &&
                    networkInterface.NetworkInterfaceType is not
                        NetworkInterfaceType.Loopback and not NetworkInterfaceType.Tunnel &&
                    networkInterface.GetIPProperties().UnicastAddresses.Any(address =>
                        address.Address.Equals(UsbWindowsAddress) &&
                        address.PrefixLength == UsbPrefixLength))
                .Select(networkInterface => new
                {
                    Interface = networkInterface,
                    Index = networkInterface.GetIPProperties().GetIPv4Properties()?.Index ?? 0,
                })
                .Where(match => match.Index > 0)
                .Take(2)
                .ToArray();
            if (matches.Length != 1 ||
                !Guid.TryParse(matches[0].Interface.Id, out var interfaceId))
            {
                return null;
            }

            var connectionPath =
                @"SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\" +
                $"{{{interfaceId:D}}}\\Connection";
            using var connection = Registry.LocalMachine.OpenSubKey(connectionPath);
            var pnpInstanceId = connection?.GetValue("PnpInstanceId") as string;
            if (pnpInstanceId is null ||
                !pnpInstanceId.StartsWith(@"USB\", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            return new DirectUsbRoute(matches[0].Index);
        }
        catch (Exception exception) when (exception is
            NetworkInformationException or
            SecurityException or
            UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static async Task<bool> HasSshBannerAsync(
        DirectUsbRoute usbRoute,
        CancellationToken cancellationToken)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            socket.SetSocketOption(
                SocketOptionLevel.IP,
                IpUnicastInterface,
                IPAddress.HostToNetworkOrder(usbRoute.InterfaceIndex));
            socket.Bind(new IPEndPoint(UsbWindowsAddress, 0));
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));
            await socket.ConnectAsync(new IPEndPoint(UsbTabletAddress, 22), timeout.Token)
                .ConfigureAwait(false);
            if (socket.LocalEndPoint is not IPEndPoint local ||
                !local.Address.Equals(UsbWindowsAddress))
            {
                return false;
            }

            using var stream = new NetworkStream(socket, ownsSocket: false);
            var line = new byte[1024];
            var nextByte = new byte[1];
            var lineLength = 0;
            var total = 0;
            while (total < 4096)
            {
                var read = await stream.ReadAsync(nextByte, timeout.Token).ConfigureAwait(false);
                if (read == 0)
                {
                    return false;
                }
                total++;
                if (nextByte[0] == (byte)'\n')
                {
                    var length = lineLength > 0 && line[lineLength - 1] == (byte)'\r'
                        ? lineLength - 1
                        : lineLength;
                    if (PassiveRouteProbe.IsRealSshIdentification(line.AsSpan(0, length)))
                    {
                        return true;
                    }
                    lineLength = 0;
                    continue;
                }
                if (lineLength == line.Length)
                {
                    return false;
                }
                line[lineLength++] = nextByte[0];
            }
        }
        catch (Exception exception) when (exception is
            SocketException or
            IOException or
            OperationCanceledException)
        {
        }
        return false;
    }

    internal static async Task<ChildProcessResult> RunChildAsync(
        ProcessStartInfo startInfo,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                return ChildProcessResult.NotStarted;
            }
        }
        catch (Win32Exception)
        {
            return ChildProcessResult.NotStarted;
        }

        try
        {
            SshChildProcessJob.AssignOrTerminate(process);
        }
        catch (Win32Exception)
        {
            return ChildProcessResult.NotStarted;
        }

        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeout != Timeout.InfiniteTimeSpan)
        {
            timeoutSource.CancelAfter(timeout);
        }

        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
            return new ChildProcessResult(
                true,
                process.ExitCode,
                await output.ConfigureAwait(false),
                await error.ConfigureAwait(false));
        }
        finally
        {
            if (!process.HasExited)
            {
                SshChildProcessJob.TerminateAndDispose(process);
            }
        }
    }

    internal static ProcessStartInfo CreateProcessStartInfo(
        string fileName,
        params string[] arguments)
    {
        var info = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }
        return info;
    }

    private static bool EnsureCredentialDirectory(string path)
    {
        try
        {
            var existed = Directory.Exists(path);
            var directory = Directory.CreateDirectory(path);
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return false;
            }
            if (!existed)
            {
                DeviceProfileStore.ApplyCurrentUserOnlyAcl(directory);
            }
            return true;
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or SecurityException)
        {
            return false;
        }
    }

    private static bool IsSafeCredentialFile(FileInfo file, long maximumBytes) =>
        file.Exists &&
        file.Length is > 0 && file.Length <= maximumBytes &&
        (file.Attributes & FileAttributes.ReparsePoint) == 0;

    private static bool IsValidPublicKeyBlob(string value)
    {
        try
        {
            var decoded = Convert.FromBase64String(value);
            return decoded.Length is > 0 and <= 512;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool ContainsHostIdentityFailure(string error) =>
        error.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.OrdinalIgnoreCase) ||
        error.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase);

    private static void PublishKnownHosts(string temporaryPath, string destinationPath)
    {
        var temporary = new FileInfo(temporaryPath);
        if (!IsSafeCredentialFile(temporary, MaximumKnownHostsBytes))
        {
            throw new InvalidDataException("The pinned host key file is invalid.");
        }
        DeviceProfileStore.ApplyCurrentUserOnlyAcl(temporary);

        if (File.Exists(destinationPath))
        {
            var destination = new FileInfo(destinationPath);
            if ((destination.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new UnauthorizedAccessException("The pinned host key path is unsafe.");
            }
            DeviceProfileStore.ApplyCurrentUserOnlyAcl(destination);
            File.Move(temporaryPath, destinationPath, overwrite: true);
        }
        else
        {
            File.Move(temporaryPath, destinationPath);
        }
        DeviceProfileStore.ApplyCurrentUserOnlyAcl(new FileInfo(destinationPath));
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException)
        {
        }
    }

    private sealed record DirectUsbRoute(int InterfaceIndex);
}

internal enum OpenSshAuthorizationResult
{
    Authorized,
    UsbUnavailable,
    PasswordRequired,
    PasswordRejected,
    AuthorizationTimedOut,
    HostIdentityRejected,
    UnsupportedTablet,
    KeyProofFailed,
    LocalCredentialFailure,
    OpenSshUnavailable,
}

internal enum OpenSshIdentityStatus
{
    Ready,
    Invalid,
    ToolUnavailable,
}

internal sealed record OpenSshIdentityResult(
    OpenSshIdentityStatus Status,
    string? PublicKeyBlob);

internal sealed record ChildProcessResult(
    bool Started,
    int ExitCode,
    string StandardOutput,
    string StandardError)
{
    public static ChildProcessResult NotStarted { get; } = new(false, -1, string.Empty, string.Empty);
}
