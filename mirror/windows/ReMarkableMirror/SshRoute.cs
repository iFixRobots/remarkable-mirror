using System.Diagnostics;

namespace ReMarkableMirror;

/// <summary>
/// Immutable SSH destination and identity policy for one tablet route.
/// </summary>
public sealed class SshRoute
{
    public const string TabletHostKeyAlias = "10.11.99.1";
    public const int DefaultFilesTargetPort = 80;

    public SshRoute(
        string host,
        string? identityFile = null,
        string? knownHostsFile = null,
        string? filesTargetHost = null,
        int filesTargetPort = DefaultFilesTargetPort)
    {
        Host = ValidateHost(host, nameof(host));
        FilesTargetHost = ValidateHost(filesTargetHost ?? host, nameof(filesTargetHost));
        if (filesTargetPort is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(
                nameof(filesTargetPort),
                "The tablet Files target port must be between 1 and 65535.");
        }

        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        IdentityFile = Path.GetFullPath(identityFile ??
            Path.Combine(profile, ".ssh", "remarkable_chiappa_ed25519"));
        KnownHostsFile = Path.GetFullPath(knownHostsFile ??
            Path.Combine(profile, ".ssh", "remarkable_known_hosts"));
        FilesTargetPort = filesTargetPort;
    }

    public string Host { get; }

    public string HostKeyAlias => TabletHostKeyAlias;

    public string IdentityFile { get; }

    public string KnownHostsFile { get; }

    public string FilesTargetHost { get; }

    public int FilesTargetPort { get; }

    internal bool CredentialFilesExist =>
        File.Exists(IdentityFile) && File.Exists(KnownHostsFile);

    internal ProcessStartInfo CreateProcessStartInfo(
        string? remoteCommand = null,
        bool enableCompression = false,
        bool noRemoteCommand = false,
        bool disablePseudoTerminal = false,
        int? localForwardPort = null,
        bool redirectStandardInput = false,
        bool redirectStandardOutput = false,
        bool redirectStandardError = false)
    {
        if (noRemoteCommand && remoteCommand is not null)
        {
            throw new ArgumentException(
                "A no-command SSH session cannot also specify a remote command.",
                nameof(remoteCommand));
        }

        var info = new ProcessStartInfo
        {
            FileName = "ssh.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = redirectStandardInput,
            RedirectStandardOutput = redirectStandardOutput,
            RedirectStandardError = redirectStandardError,
        };

        // OpenSSH uses the first value it sees for most configuration options.
        // Keep the mandatory policy first and expose only typed, non-overriding
        // switches below so callers cannot prepend -o, -F, or another target.
        foreach (var argument in new[]
        {
            "-F", "NUL",
            "-i", IdentityFile,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "-o", $"UserKnownHostsFile={KnownHostsFile}",
            "-o", "GlobalKnownHostsFile=NUL",
            "-o", $"HostKeyAlias={HostKeyAlias}",
            "-o", "UpdateHostKeys=no",
            "-o", "ConnectTimeout=3",
            "-o", "ServerAliveInterval=3",
            // One late reply is normal on Wi-Fi. Three unanswered probes still
            // fail within the tablet companion's 15-second input lease while
            // avoiding a full Mirror recovery for a single 3-second pause.
            "-o", "ServerAliveCountMax=3",
        })
        {
            info.ArgumentList.Add(argument);
        }

        if (enableCompression)
        {
            info.ArgumentList.Add("-C");
        }
        if (noRemoteCommand)
        {
            info.ArgumentList.Add("-N");
        }
        if (disablePseudoTerminal)
        {
            info.ArgumentList.Add("-T");
        }
        if (localForwardPort is { } forwardingPort)
        {
            info.ArgumentList.Add("-o");
            info.ArgumentList.Add("ExitOnForwardFailure=yes");
            info.ArgumentList.Add("-L");
            info.ArgumentList.Add(CreateFilesForwardArgument(forwardingPort));
        }

        info.ArgumentList.Add($"root@{Host}");

        if (remoteCommand is not null)
        {
            info.ArgumentList.Add(remoteCommand);
        }

        return info;
    }

    internal string CreateFilesForwardArgument(int localPort)
    {
        if (localPort is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(
                nameof(localPort),
                "The local forwarding port must be between 1 and 65535.");
        }

        var target = FilesTargetHost.Contains(':', StringComparison.Ordinal)
            ? $"[{FilesTargetHost}]"
            : FilesTargetHost;
        return $"127.0.0.1:{localPort}:{target}:{FilesTargetPort}";
    }

    private static string ValidateHost(string host, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(host) ||
            host.StartsWith("-", StringComparison.Ordinal) ||
            host.Any(char.IsWhiteSpace) ||
            host.Any(char.IsControl))
        {
            throw new ArgumentException("A valid tablet SSH host is required.", parameterName);
        }

        return host;
    }
}
