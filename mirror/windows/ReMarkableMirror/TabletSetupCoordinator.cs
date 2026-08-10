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

    private readonly SemaphoreSlim _runGate = new(1, 1);
    private readonly DeviceProfileStore _profileStore = new();
    private readonly OpenSshSetupClient _ssh = new();

    public async Task<TabletSetupResult> RunAsync(
        string? oneTimePassword,
        bool forceRepair = false,
        IProgress<TabletSetupPhase>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!await _runGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return Result(TabletSetupStatus.AlreadyRunning);
        }

        try
        {
            if (!TryResolveBundle(out var installerScript))
            {
                return Result(TabletSetupStatus.SetupFilesMissing);
            }

            progress?.Report(TabletSetupPhase.CheckingUsb);
            progress?.Report(TabletSetupPhase.PairingComputer);
            var authorization = await _ssh.AuthorizeAsync(
                    oneTimePassword,
                    cancellationToken)
                .ConfigureAwait(false);
            var authorizationFailure = MapAuthorizationFailure(authorization);
            if (authorizationFailure is not null)
            {
                return authorizationFailure;
            }

            if (!forceRepair && await TabletIsAlreadyReadyAsync(cancellationToken)
                    .ConfigureAwait(false))
            {
                var recognized = await RunInstallerAsync(
                        installerScript,
                        recognizeOnly: true,
                        cancellationToken)
                    .ConfigureAwait(false);
                if (!recognized.Started)
                {
                    return Result(TabletSetupStatus.PowerShellUnavailable);
                }
                if (recognized.ExitCode != 0)
                {
                    return Result(TabletSetupStatus.VerificationFailed);
                }

                var recognizedProfile = _profileStore.Load();
                return recognizedProfile.Status switch
                {
                    DeviceProfileLoadStatus.Ready => Result(TabletSetupStatus.Ready),
                    DeviceProfileLoadStatus.NotFound => Result(TabletSetupStatus.WifiNotReady),
                    _ => Result(TabletSetupStatus.VerificationFailed),
                };
            }

            progress?.Report(TabletSetupPhase.InstallingTabletComponents);
            var install = await RunInstallerAsync(
                    installerScript,
                    recognizeOnly: false,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!install.Started)
            {
                return Result(TabletSetupStatus.PowerShellUnavailable);
            }
            if (install.ExitCode != 0)
            {
                return Result(TabletSetupStatus.InstallationFailed);
            }

            progress?.Report(TabletSetupPhase.PreparingWifi);
            progress?.Report(TabletSetupPhase.VerifyingSetup);
            var profile = _profileStore.Load();
            if (profile.Status is DeviceProfileLoadStatus.Ready)
            {
                return Result(TabletSetupStatus.Ready);
            }
            if (profile.Status is DeviceProfileLoadStatus.NotFound)
            {
                return Result(TabletSetupStatus.WifiNotReady);
            }
            return Result(TabletSetupStatus.VerificationFailed);
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
        OpenSshAuthorizationResult.HostIdentityRejected =>
            Result(TabletSetupStatus.HostIdentityRejected),
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

    private static async Task<bool> TabletIsAlreadyReadyAsync(
        CancellationToken cancellationToken)
    {
        var result = await new PassiveRouteProbe(new SshRoute("10.11.99.1"))
            .ProbeAsync(cancellationToken)
            .ConfigureAwait(false);
        return result.State is PassiveRouteProbeState.Authenticated &&
            result.Capability is { IsCurrent: true };
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
            TabletSetupStatus.OpenSshUnavailable =>
                "Windows OpenSSH Client is required for setup.",
            TabletSetupStatus.PowerShellUnavailable =>
                "PowerShell 7.5 or newer is required for setup.",
            TabletSetupStatus.LocalCredentialFailure =>
                "Mirror could not create or verify its dedicated SSH key.",
            TabletSetupStatus.InstallationFailed =>
                "The tablet components could not be installed. Check the USB-C connection and try again.",
            TabletSetupStatus.WifiNotReady =>
                "Tablet setup is installed. Reconnect Wi-Fi on the tablet, then resume setup.",
            _ => "Mirror could not verify the completed tablet setup.",
        });
}

public enum TabletSetupPhase
{
    CheckingUsb,
    PairingComputer,
    InstallingTabletComponents,
    PreparingWifi,
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
    OpenSshUnavailable,
    PowerShellUnavailable,
    LocalCredentialFailure,
    InstallationFailed,
    WifiNotReady,
    VerificationFailed,
}

public sealed record TabletSetupResult(
    TabletSetupStatus Status,
    string Message)
{
    public bool IsReady => Status is TabletSetupStatus.Ready;
}
