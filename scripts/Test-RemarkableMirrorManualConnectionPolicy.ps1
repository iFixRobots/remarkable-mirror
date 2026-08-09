[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$requestSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\ManualConnectionRequest.cs'
$sshRouteSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\SshRoute.cs'
$mainPageSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\MainPage.xaml.cs'
$mainPageXamlPath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\MainPage.xaml'
$monitorSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\DeviceConnectionMonitor.cs'

foreach ($requiredPath in @(
    $requestSourcePath,
    $sshRouteSourcePath,
    $mainPageSourcePath,
    $mainPageXamlPath,
    $monitorSourcePath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required manual-connection source is missing: $requiredPath"
    }
}

$mainPageSource = Get-Content -Raw -LiteralPath $mainPageSourcePath
$mainPageXaml = Get-Content -Raw -LiteralPath $mainPageXamlPath
$monitorSource = Get-Content -Raw -LiteralPath $monitorSourcePath
$sshRouteSource = Get-Content -Raw -LiteralPath $sshRouteSourcePath

foreach ($requiredMarker in @(
    'ConnectUsbButton_Click',
    'ConnectWifiButton_Click',
    'SubmitWifiAddressButton_Click',
    'CancelWifiAddressButton_Click',
    'WatchSelectedAsync',
    'RetireSelectedConnectionAsync',
    'TimeSpan.FromSeconds(45)',
    'ManualWifiRepairConfirmationDelay',
    'wifiProbeCount == 1',
    'PassiveRouteProbeDetail.TabletPrerequisiteMismatch',
    'transitionAllowed:',
    'expectedCurrent: generation',
    'expectedCurrent: publishedGeneration',
    '!inputRemoval.RestoreConfirmed || _inputRestoreUncertain',
    'attemptCancellationToken.ThrowIfCancellationRequested();',
    '_connectionCancellation.Token != cancellationToken',
    'if (_filesPaneOpen)',
    'if (open)',
    'while (IsCurrentGeneration(generation) && _filesPaneDesiredOpen)',
    '_filesReadyGeneration == generation.Id',
    'lastPublishedStatus != state.Status',
    'routeKind is DeviceRouteKind.Usb',
    'Waiting for the Wi-Fi address you entered.',
    '.WatchSelectedAsync(request.Kind, attemptCancellationToken)',
    'monitor.RequestProbe();'
)) {
    if (-not $mainPageSource.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "MainPage is missing the manual-connection marker: $requiredMarker"
    }
}

$disposeFilesStart = $mainPageSource.IndexOf(
    'internal void DisposeFilesPaneAnimation()',
    [StringComparison]::Ordinal)
$filesCloseRequestedStart = $mainPageSource.IndexOf(
    'private async void FilesPane_CloseRequested(',
    $disposeFilesStart,
    [StringComparison]::Ordinal)
if ($disposeFilesStart -lt 0 -or $filesCloseRequestedStart -le $disposeFilesStart) {
    throw 'Could not isolate Files pane disposal.'
}
$disposeFilesBlock = $mainPageSource.Substring(
    $disposeFilesStart,
    $filesCloseRequestedStart - $disposeFilesStart)
foreach ($filesResetMarker in @(
        '_filesPaneDesiredOpen = false;',
        '_filesPaneOpen = false;',
        '_filesReadyGeneration = 0;'
    )) {
    if (-not $disposeFilesBlock.Contains($filesResetMarker, [StringComparison]::Ordinal)) {
        throw "Files pane disposal preserves stale owner intent: $filesResetMarker"
    }
}

$noBannerStatusStart = $mainPageSource.IndexOf(
    'case DeviceConnectionStatus.PortOpenWithoutSshBanner:',
    [StringComparison]::Ordinal)
$unlockStatusStart = $mainPageSource.IndexOf(
    'case DeviceConnectionStatus.UnlockRequired:',
    $noBannerStatusStart,
    [StringComparison]::Ordinal)
if ($noBannerStatusStart -lt 0 -or $unlockStatusStart -le $noBannerStatusStart) {
    throw 'Could not isolate no-banner status publication.'
}
$noBannerStatusBlock = $mainPageSource.Substring(
    $noBannerStatusStart,
    $unlockStatusStart - $noBannerStatusStart)
foreach ($routeAwareMarker in @(
        'routeKind is DeviceRouteKind.Usb',
        'ManualConnectionFailureMessage(routeKind, state.Status)'
    )) {
    if (-not $noBannerStatusBlock.Contains($routeAwareMarker, [StringComparison]::Ordinal)) {
        throw "The no-banner status is not route-aware: $routeAwareMarker"
    }
}

if ($mainPageSource.Contains(
        '_ = ProbeFilesRouteAsync(next);',
        [StringComparison]::Ordinal)) {
    throw 'Route publication still starts the Files connection without a Files action.'
}

foreach ($forbiddenMarker in @(
    '_connectionMonitor',
    '_connectionMonitorTask',
    'MonitorConnectionAsync(',
    'ConnectionActionButton_Click',
    'AutomaticFrameRetryLimit',
    'RetryDelayFor',
    'BeginDisplayRecoveryAsync(',
    'TryReserveSetupFailureRecovery('
)) {
    if ($mainPageSource.Contains($forbiddenMarker, [StringComparison]::Ordinal)) {
        throw "MainPage still contains automatic connection behavior: $forbiddenMarker"
    }
}

$pageLoadedStart = $mainPageSource.IndexOf(
    'private async void Page_Loaded(',
    [StringComparison]::Ordinal)
if ($pageLoadedStart -lt 0) {
    throw 'Could not find the Page_Loaded lifecycle block.'
}
$pageUnloadedStart = $mainPageSource.IndexOf(
    'private async void Page_Unloaded(',
    $pageLoadedStart,
    [StringComparison]::Ordinal)
if ($pageLoadedStart -lt 0 -or $pageUnloadedStart -le $pageLoadedStart) {
    throw 'Could not isolate the Page_Loaded lifecycle block.'
}
$pageLoadedBlock = $mainPageSource.Substring(
    $pageLoadedStart,
    $pageUnloadedStart - $pageLoadedStart)
foreach ($forbiddenLaunchMarker in @(
        'StartManualConnectionAsync(',
        'ProbeSelectedRouteAsync(',
        'WatchSelectedAsync(',
        'DeviceConnectionMonitor('
    )) {
    if ($pageLoadedBlock.Contains($forbiddenLaunchMarker, [StringComparison]::Ordinal)) {
        throw "Page_Loaded still contacts the tablet: $forbiddenLaunchMarker"
    }
}

$wifiClickStart = $mainPageSource.IndexOf(
    'private void ConnectWifiButton_Click(',
    [StringComparison]::Ordinal)
if ($wifiClickStart -lt 0) {
    throw 'Could not find the Connect Wi-Fi click handler.'
}
$wifiSubmitStart = $mainPageSource.IndexOf(
    'private async void SubmitWifiAddressButton_Click(',
    $wifiClickStart,
    [StringComparison]::Ordinal)
if ($wifiClickStart -lt 0 -or $wifiSubmitStart -le $wifiClickStart) {
    throw 'Could not isolate the Connect Wi-Fi click handler.'
}
$wifiClickBlock = $mainPageSource.Substring(
    $wifiClickStart,
    $wifiSubmitStart - $wifiClickStart)
if (-not $wifiClickBlock.Contains(
        'WifiAddressPanel.Visibility = Visibility.Visible;',
        [StringComparison]::Ordinal)) {
    throw 'Connect Wi-Fi no longer reveals the address field.'
}
foreach ($forbiddenWifiClickMarker in @(
        'StartManualConnectionAsync(',
        'ProbeSelectedRouteAsync(',
        'WatchSelectedAsync('
    )) {
    if ($wifiClickBlock.Contains($forbiddenWifiClickMarker, [StringComparison]::Ordinal)) {
        throw "Connect Wi-Fi contacts the tablet before address submission: $forbiddenWifiClickMarker"
    }
}

$manualPublishStart = $mainPageSource.IndexOf(
    'var transition = await TransitionRouteAsync(',
    [StringComparison]::Ordinal)
if ($manualPublishStart -lt 0) {
    throw 'Could not find manual route publication.'
}
$manualPublishEnd = $mainPageSource.IndexOf(
    '            return;',
    $manualPublishStart,
    [StringComparison]::Ordinal)
if ($manualPublishStart -lt 0 -or $manualPublishEnd -le $manualPublishStart) {
    throw 'Could not isolate manual route publication.'
}
$manualPublishBlock = $mainPageSource.Substring(
    $manualPublishStart,
    $manualPublishEnd - $manualPublishStart)
if ($manualPublishBlock.Contains(
        'SetMirrorState(MirrorConnectionState.Preparing)',
        [StringComparison]::Ordinal)) {
    throw 'A stale connection attempt can overwrite terminal retirement UI.'
}

$probeUsbStart = $monitorSource.IndexOf(
    'private async Task<DeviceConnectionState> ProbeUsbAsync(',
    [StringComparison]::Ordinal)
$authenticateUsbStart = $monitorSource.IndexOf(
    'private Task<DeviceConnectionState> AuthenticateUsbAsync(',
    $probeUsbStart,
    [StringComparison]::Ordinal)
if ($probeUsbStart -lt 0 -or $authenticateUsbStart -le $probeUsbStart) {
    throw 'Could not isolate the selected USB probe.'
}
$probeUsbBlock = $monitorSource.Substring(
    $probeUsbStart,
    $authenticateUsbStart - $probeUsbStart)
$sshProbeStart = $probeUsbBlock.IndexOf(
    'var sshStatus = await ProbeUsbSshAsync(',
    [StringComparison]::Ordinal)
$wakeClientDeclaration = $probeUsbBlock.IndexOf(
    'TabletWakeClient? wakeClient;',
    $sshProbeStart,
    [StringComparison]::Ordinal)
if ($sshProbeStart -lt 0 -or $wakeClientDeclaration -le $sshProbeStart) {
    throw 'Could not isolate USB SSH admission before wake handling.'
}
$sshAdmissionBlock = $probeUsbBlock.Substring(
    $sshProbeStart,
    $wakeClientDeclaration - $sshProbeStart)
foreach ($sshAdmissionMarker in @(
        'if (sshStatus is DeviceConnectionStatus.SshReady)',
        'AuthenticateUsbAsync('
    )) {
    if (-not $sshAdmissionBlock.Contains($sshAdmissionMarker, [StringComparison]::Ordinal)) {
        throw "A ready USB SSH route can still be overridden by stale wake state: $sshAdmissionMarker"
    }
}

$selectedProbeStart = $monitorSource.IndexOf(
    'public async Task<DeviceConnectionState> ProbeSelectedRouteAsync(',
    [StringComparison]::Ordinal)
$requestProbeStart = $monitorSource.IndexOf(
    'public void RequestProbe()',
    $selectedProbeStart,
    [StringComparison]::Ordinal)
if ($selectedProbeStart -lt 0 -or $requestProbeStart -le $selectedProbeStart) {
    throw 'Could not isolate the owner-selected route dispatcher.'
}
$selectedProbeBlock = $monitorSource.Substring(
    $selectedProbeStart,
    $requestProbeStart - $selectedProbeStart)
foreach ($selectedProbeMarker in @(
        'DeviceRouteKind.Usb',
        'ProbeUsbAsync(cancellationToken)',
        'DeviceRouteKind.Wifi',
        'ProbeWifiAsync(cancellationToken)'
    )) {
    if (-not $selectedProbeBlock.Contains($selectedProbeMarker, [StringComparison]::Ordinal)) {
        throw "The owner-selected route dispatcher is missing: $selectedProbeMarker"
    }
}
foreach ($forbiddenSelectedProbeMarker in @(
        'ProbeAsync(cancellationToken)',
        'ProbePassiveUsbCandidateAsync(',
        'ReportUsbPromotionFailed(',
        'ConfirmUsbPromotionSucceeded('
    )) {
    if ($selectedProbeBlock.Contains($forbiddenSelectedProbeMarker, [StringComparison]::Ordinal)) {
        throw "The owner-selected route can still probe another route: $forbiddenSelectedProbeMarker"
    }
}

foreach ($requiredMarker in @(
    'x:Name="ConnectUsbButton"',
    'x:Name="ConnectWifiButton"',
    'x:Name="WifiAddressPanel"',
    'x:Name="WifiAddressTextBox"',
    'Visibility="Collapsed"'
)) {
    if (-not $mainPageXaml.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "MainPage XAML is missing the manual-connection marker: $requiredMarker"
    }
}

if ($mainPageXaml -notmatch '(?s)x:Name="WifiAddressPanel".{0,160}Visibility="Collapsed"') {
    throw 'The Wi-Fi address panel is not specifically hidden until Connect Wi-Fi is clicked.'
}

$escapedRequestSourcePath = [System.Security.SecurityElement]::Escape($requestSourcePath)
$escapedSshRouteSourcePath = [System.Security.SecurityElement]::Escape($sshRouteSourcePath)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-manual-connection-validation-' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $temporaryRoot 'ManualConnectionValidation.csproj'
$programPath = Join-Path $temporaryRoot 'Program.cs'

$project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$escapedSshRouteSourcePath" Link="SshRoute.cs" />
    <Compile Include="$escapedRequestSourcePath" Link="ManualConnectionRequest.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@

$program = @'
namespace ReMarkableMirror;

public enum DeviceRouteKind
{
    Usb,
    Wifi,
}

internal static class Program
{
    public static int Main()
    {
        try
        {
            var usbRoute = new SshRoute(
                SshRoute.TabletHostKeyAlias,
                filesTargetHost: ManualConnectionRequest.FilesLoopbackHost);
            var usb = ManualConnectionRequest.ForUsb(usbRoute);
            Require(usb.Kind == DeviceRouteKind.Usb);
            Require(usb.Route.Host == SshRoute.TabletHostKeyAlias);

            Require(!ManualConnectionRequest.TryCreateWifi(
                null,
                80,
                out _,
                out var missingError));
            Require(missingError == ManualWifiAddressError.AddressRequired);

            foreach (var invalid in new[]
            {
                "tablet.local",
                "192.168.1",
                "192.168.001.42",
                "0xC0.0xA8.0x01.0x2A",
                "192.168.1.42:22",
                "127.0.0.1",
                "0.0.0.0",
                "0.1.2.3",
                "224.0.0.1",
                "240.0.0.1",
                "255.255.255.255",
                SshRoute.TabletHostKeyAlias,
                "2001:db8::1",
            })
            {
                Require(!ManualConnectionRequest.TryCreateWifi(
                    invalid,
                    80,
                    out _,
                    out _));
            }

            Require(ManualConnectionRequest.TryCreateWifi(
                " 192.168.1.42 ",
                8080,
                out var wifi,
                out var wifiError));
            Require(wifiError == ManualWifiAddressError.None);
            Require(wifi is not null);
            Require(wifi!.Kind == DeviceRouteKind.Wifi);
            Require(wifi.Route.Host == "192.168.1.42");
            Require(wifi.Route.FilesTargetHost == ManualConnectionRequest.FilesLoopbackHost);
            Require(wifi.Route.FilesTargetPort == 8080);

            Console.WriteLine("Result: PASS");
            Console.WriteLine("ExplicitRoutes: PASS");
            Console.WriteLine("WifiIPv4Validation: PASS");
            Console.WriteLine("NoAutomaticMonitor: PASS");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"Manual connection policy validation failed: {exception.GetType().Name}.");
            return 1;
        }
    }

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new InvalidOperationException();
        }
    }
}
'@

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    [System.IO.File]::WriteAllText($projectPath, $project)
    [System.IO.File]::WriteAllText($programPath, $program)
    & dotnet run --project $projectPath -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "Manual connection policy validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
