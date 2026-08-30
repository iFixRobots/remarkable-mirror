using System.Diagnostics;
using System.Security;
using Microsoft.Win32;

namespace ReMarkableMirror;

/// <summary>
/// Runs one owner-requested first-time setup attempt. Construction and local
/// readiness checks never contact the tablet.
/// </summary>
public sealed class TabletSetupCoordinator
{
    private static readonly string[] RequiredComponentFiles =
    [
        "install-mirror-prerequisites.sh",
        "install-transport-wake.sh",
        "rmmirror-files-loopback.so",
        "rmmirror-prerequisites.env",
        "rmmirror-probe",
        "rmmirror-transport-wake",
        "rmmirror-transport-wake.service",
        "rmmirror-usb-sleep-guard.conf",
        "xovi-aarch64.tar.gz",
    ];

    private static readonly TimeSpan AttemptFloor = TimeSpan.FromSeconds(1.5);

    private readonly SemaphoreSlim _runGate = new(1, 1);
    private readonly DeviceProfileStore _profileStore = new();
    private readonly OpenSshSetupClient _ssh = new();
    private long _lastAttemptTimestamp;
    private bool _hasAttempt;

    public async Task<TabletSetupResult> RunAsync(
        string? oneTimePassword,
        bool forceRepair = false,
        IProgress<TabletSetupPhase>? progress = null,
        Action<string>? diagnostics = null,
        CancellationToken cancellationToken = default)
    {
        if (!await _runGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return Result(TabletSetupStatus.AlreadyRunning);
        }

        try
        {
            // Floor between attempts so rapid retries cannot flood the
            // tablet's SSH service with connection churn.
            if (_hasAttempt)
            {
                var sinceLastAttempt = Stopwatch.GetElapsedTime(_lastAttemptTimestamp);
                if (sinceLastAttempt < AttemptFloor)
                {
                    await Task.Delay(AttemptFloor - sinceLastAttempt, cancellationToken)
                        .ConfigureAwait(false);
                }
            }
            _lastAttemptTimestamp = Stopwatch.GetTimestamp();
            _hasAttempt = true;

            if (!TryResolveBundle(out var installerScript))
            {
                return Result(TabletSetupStatus.SetupFilesMissing);
            }

            progress?.Report(TabletSetupPhase.CheckingUsb);
            progress?.Report(TabletSetupPhase.PairingComputer);
            var authorizationTimer = Stopwatch.StartNew();
            var authorization = await _ssh.AuthorizeAsync(
                    oneTimePassword,
                    cancellationToken)
                .ConfigureAwait(false);
            diagnostics?.Invoke(
                $"authorization: {authorization} in {authorizationTimer.ElapsedMilliseconds}ms");
            var authorizationFailure = MapAuthorizationFailure(authorization);
            if (authorizationFailure is not null)
            {
                return authorizationFailure;
            }

            var readyProbe = await ProbeTabletAsync(cancellationToken).ConfigureAwait(false);
            diagnostics?.Invoke(DescribeProbe(readyProbe));
            var tabletAlreadyReady =
                readyProbe.State is PassiveRouteProbeState.Authenticated &&
                readyProbe.Capability is { MeetsRuntimeContract: true };

            if (!forceRepair && tabletAlreadyReady)
            {
                diagnostics?.Invoke("setup path: recognize, tablet already provisioned");
                var recognizeTimer = Stopwatch.StartNew();
                var recognized = await RunInstallerAsync(
                        installerScript,
                        recognizeOnly: true,
                        cancellationToken)
                    .ConfigureAwait(false);
                if (!recognized.Started)
                {
                    diagnostics?.Invoke("recognize: PowerShell unavailable");
                    return Result(TabletSetupStatus.PowerShellUnavailable);
                }
                diagnostics?.Invoke(
                    $"recognize: exit {recognized.ExitCode} in {recognizeTimer.ElapsedMilliseconds}ms");
                if (recognized.ExitCode != 0)
                {
                    diagnostics?.Invoke($"recognize stderr: {Tail(recognized.StandardError)}");
                    return Result(InstallerFailureStatus(
                        recognized.StandardError,
                        TabletSetupStatus.VerificationFailed));
                }

                var recognizedProfile = _profileStore.Load();
                diagnostics?.Invoke($"device profile: {recognizedProfile.Status}");
                return recognizedProfile.Status switch
                {
                    DeviceProfileLoadStatus.Ready => Result(TabletSetupStatus.Ready),
                    _ => Result(TabletSetupStatus.VerificationFailed),
                };
            }

            diagnostics?.Invoke(forceRepair
                ? "setup path: repair install"
                : "setup path: full install");
            progress?.Report(TabletSetupPhase.InstallingTabletComponents);
            var installTimer = Stopwatch.StartNew();
            var install = await RunInstallerAsync(
                    installerScript,
                    recognizeOnly: false,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!install.Started)
            {
                diagnostics?.Invoke("install: PowerShell unavailable");
                return Result(TabletSetupStatus.PowerShellUnavailable);
            }
            diagnostics?.Invoke(
                $"install: exit {install.ExitCode} in {installTimer.ElapsedMilliseconds}ms");
            if (install.ExitCode != 0)
            {
                diagnostics?.Invoke($"install stderr: {Tail(install.StandardError)}");
                return Result(InstallerFailureStatus(
                    install.StandardError,
                    TabletSetupStatus.InstallationFailed));
            }
            // The tablet script proceeds on untested software and logs the
            // exact pair. Surface it so diagnostics carry the disclaimer.
            var untestedTabletSoftware =
                TryExtractUntestedTabletSoftware(install.StandardError);

            progress?.Report(TabletSetupPhase.VerifyingSetup);
            var profile = _profileStore.Load();
            diagnostics?.Invoke($"device profile: {profile.Status}");
            if (profile.Status is DeviceProfileLoadStatus.Ready)
            {
                return Result(TabletSetupStatus.Ready) with
                {
                    UntestedTabletSoftware = untestedTabletSoftware,
                };
            }
            return Result(TabletSetupStatus.VerificationFailed) with
            {
                UntestedTabletSoftware = untestedTabletSoftware,
            };
        }
        catch (OperationCanceledException)
        {
            return Result(TabletSetupStatus.Cancelled);
        }
        finally
        {
            _runGate.Release();
        }
    }

    private static TabletSetupResult? MapAuthorizationFailure(
        OpenSshAuthorizationResult authorization) => authorization switch
    {
        OpenSshAuthorizationResult.Authorized => null,
        OpenSshAuthorizationResult.UsbUnavailable => Result(TabletSetupStatus.UsbUnavailable),
        OpenSshAuthorizationResult.PasswordRequired => Result(TabletSetupStatus.PasswordRequired),
        OpenSshAuthorizationResult.PasswordRejected => Result(TabletSetupStatus.PasswordRejected),
        OpenSshAuthorizationResult.AuthorizationTimedOut =>
            Result(TabletSetupStatus.TabletNotAwake),
        OpenSshAuthorizationResult.HostIdentityRejected =>
            Result(TabletSetupStatus.HostIdentityRejected),
        OpenSshAuthorizationResult.UnsupportedTablet =>
            Result(TabletSetupStatus.UnsupportedTablet),
        OpenSshAuthorizationResult.OpenSshUnavailable =>
            Result(TabletSetupStatus.OpenSshUnavailable),
        OpenSshAuthorizationResult.KeyProofFailed or
        OpenSshAuthorizationResult.LocalCredentialFailure =>
            Result(TabletSetupStatus.LocalCredentialFailure),
        _ => Result(TabletSetupStatus.VerificationFailed),
    };

    private async Task<ChildProcessResult> RunInstallerAsync(
        string installerScript,
        bool recognizeOnly,
        CancellationToken cancellationToken)
    {
        var route = new SshRoute("10.11.99.1");
        const string PowerShellVariable = "RMMIRROR_SETUP_PWSH";
        const string InstallerVariable = "RMMIRROR_SETUP_SCRIPT";
        const string IdentityVariable = "RMMIRROR_SETUP_IDENTITY";
        const string KnownHostsVariable = "RMMIRROR_SETUP_KNOWN_HOSTS";
        // Store-distributed PowerShell already belongs to its package job.
        // A job-owned cmd process lets PowerShell inherit Mirror's lifetime.
        var info = OpenSshSetupClient.CreateProcessStartInfo(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "cmd.exe"));
        info.Environment[PowerShellVariable] = FindPowerShell();
        info.Environment[InstallerVariable] = installerScript;
        info.Environment[IdentityVariable] = route.IdentityFile;
        info.Environment[KnownHostsVariable] = route.KnownHostsFile;
        var recognizeOnlyArgument = recognizeOnly ? " -RecognizeOnly" : string.Empty;
        info.Arguments =
            $"/d /s /c \"\"%{PowerShellVariable}%\" -NoLogo -NoProfile " +
            $"-NonInteractive -ExecutionPolicy Bypass -File \"%{InstallerVariable}%\" " +
            $"-IdentityFile \"%{IdentityVariable}%\" " +
            $"-KnownHostsFile \"%{KnownHostsVariable}%\"{recognizeOnlyArgument}\"";

        return await OpenSshSetupClient.RunChildAsync(
                info,
                TimeSpan.FromMinutes(8),
                cancellationToken)
            .ConfigureAwait(false);
    }

    private static string FindPowerShell()
    {
        var registered = Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe",
            null,
            null) as string;
        if (!string.IsNullOrWhiteSpace(registered))
        {
            return registered;
        }

        var installed = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "PowerShell", "7", "pwsh.exe");
        return File.Exists(installed) ? installed : "pwsh.exe";
    }

    // The installer names its failing stage in the thrown error text. Map the
    // stages whose recovery differs from "check the cable" to their own copy.
    private static TabletSetupStatus InstallerFailureStatus(
        string standardError,
        TabletSetupStatus fallback)
    {
        if (standardError.Contains(
                "Could not enable the tablet Wi-Fi SSH prerequisite",
                StringComparison.Ordinal))
        {
            return TabletSetupStatus.WifiSshEnableFailed;
        }
        if (standardError.Contains(
                "Could not verify the tablet wake endpoint over trusted USB",
                StringComparison.Ordinal))
        {
            return TabletSetupStatus.TabletNotAwake;
        }
        return fallback;
    }

    private static string? TryExtractUntestedTabletSoftware(string standardError)
    {
        const string Marker = "rmmirror-prerequisite: tablet_software_untested:";
        foreach (var line in standardError.Split(
                     ['\r', '\n'],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var markerIndex = line.IndexOf(Marker, StringComparison.Ordinal);
            if (markerIndex < 0)
            {
                continue;
            }
            var pair = line[(markerIndex + Marker.Length)..].Trim();
            if (pair.Length is > 0 and <= 64 &&
                !pair.Any(char.IsControl))
            {
                return pair;
            }
        }
        return null;
    }

    private static async Task<PassiveRouteProbeResult> ProbeTabletAsync(
        CancellationToken cancellationToken) =>
        await new PassiveRouteProbe(new SshRoute("10.11.99.1"))
            .ProbeAsync(cancellationToken)
            .ConfigureAwait(false);

    private static string DescribeProbe(PassiveRouteProbeResult probe)
    {
        if (probe.Capability is { } capability)
        {
            return $"tablet probe: {probe.State}, model '{capability.TabletModel}', " +
                $"os {capability.OsVersion}+{capability.OsBuild}, " +
                $"probe {capability.ProbeVersion}, transport {capability.TransportVersion} " +
                $"active={capability.TransportActive}, wake healthy={capability.WakeEndpointHealthy}, " +
                $"xovi {capability.XoviVersion}, " +
                $"contract {(capability.MeetsRuntimeContract ? "met" : "not met")}";
        }
        return $"tablet probe: {probe.State}, {probe.Detail}";
    }

    private static string Tail(string text)
    {
        var flattened = text.Replace("\r", " ").Replace("\n", " / ").Trim();
        return flattened.Length <= 200 ? flattened : flattened[^200..];
    }

    private static bool TryResolveBundle(out string installerScript)
    {
        var root = Path.Combine(AppContext.BaseDirectory, "TabletPrerequisites");
        var components = Path.Combine(root, "components");
        var library = Path.Combine(root, "lib");
        installerScript = Path.Combine(root, "Install-RemarkableMirrorPrerequisites.ps1");
        var captureHelper = Path.Combine(library, "RemarkableRmctlCapture.ps1");

        try
        {
            if (!IsSafeDirectory(root) ||
                !IsSafeDirectory(components) ||
                !IsSafeDirectory(library) ||
                !IsSafeFile(installerScript) ||
                !IsSafeFile(captureHelper))
            {
                return false;
            }

            var actualComponents = Directory.EnumerateFiles(components)
                .Select(Path.GetFileName)
                .Order(StringComparer.Ordinal)
                .ToArray();
            if (!actualComponents.SequenceEqual(
                    RequiredComponentFiles.Order(StringComparer.Ordinal),
                    StringComparer.Ordinal))
            {
                return false;
            }
            return RequiredComponentFiles.All(name =>
                IsSafeFile(Path.Combine(components, name)));
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            SecurityException or
            NotSupportedException)
        {
            return false;
        }
    }

    private static bool IsSafeDirectory(string path)
    {
        var directory = new DirectoryInfo(path);
        return directory.Exists &&
            (directory.Attributes & FileAttributes.ReparsePoint) == 0;
    }

    private static bool IsSafeFile(string path)
    {
        var file = new FileInfo(path);
        return file.Exists &&
            file.Length > 0 &&
            (file.Attributes & FileAttributes.ReparsePoint) == 0;
    }

    private static TabletSetupResult Result(TabletSetupStatus status) =>
        new(status, status switch
        {
            TabletSetupStatus.Ready => "Setup is complete. Choose USB-C or Wi-Fi to connect.",
            TabletSetupStatus.AlreadyRunning => "Setup is already running.",
            TabletSetupStatus.Cancelled => "Setup was cancelled. Nothing will retry automatically.",
            TabletSetupStatus.SetupFilesMissing =>
                "This app package does not include the tablet setup files.",
            TabletSetupStatus.UsbUnavailable =>
                "Connect the tablet directly by USB-C, keep it awake and unlocked, then try again.",
            TabletSetupStatus.PasswordRequired =>
                "Enter the one-time Developer Mode password to authorize this computer.",
            TabletSetupStatus.PasswordRejected =>
                "The tablet did not accept that Developer Mode password.",
            TabletSetupStatus.HostIdentityRejected =>
                "The connected tablet does not match the SSH identity already trusted by this computer.",
            TabletSetupStatus.UnsupportedTablet =>
                "This tablet model is not supported by this Mirror build.",
            TabletSetupStatus.OpenSshUnavailable =>
                "Windows OpenSSH Client is required for setup.",
            TabletSetupStatus.PowerShellUnavailable =>
                "PowerShell 7.5 or newer is required for setup.",
            TabletSetupStatus.LocalCredentialFailure =>
                "Mirror could not create or verify its dedicated SSH key.",
            TabletSetupStatus.InstallationFailed =>
                "The tablet components could not be installed. Check the USB-C connection and try again.",
            TabletSetupStatus.WifiSshEnableFailed =>
                "The tablet components are installed, but its Wi-Fi SSH listener would not start. Restart the tablet, unlock it once, then run setup again over USB-C.",
            TabletSetupStatus.TabletNotAwake =>
                "The tablet stopped answering during setup. Wake it, unlock it once, keep USB-C connected, and try again.",
            _ => "Mirror could not verify the completed tablet setup.",
        });
}

public enum TabletSetupPhase
{
    CheckingUsb,
    PairingComputer,
    InstallingTabletComponents,
    VerifyingSetup,
}

public enum TabletSetupStatus
{
    Ready,
    AlreadyRunning,
    Cancelled,
    SetupFilesMissing,
    UsbUnavailable,
    PasswordRequired,
    PasswordRejected,
    HostIdentityRejected,
    UnsupportedTablet,
    OpenSshUnavailable,
    PowerShellUnavailable,
    LocalCredentialFailure,
    InstallationFailed,
    WifiSshEnableFailed,
    TabletNotAwake,
    VerificationFailed,
}

public sealed record TabletSetupResult(
    TabletSetupStatus Status,
    string Message,
    string? UntestedTabletSoftware = null)
{
    public bool IsReady => Status is TabletSetupStatus.Ready;
}
