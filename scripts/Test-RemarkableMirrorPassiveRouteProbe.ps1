[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$probePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\PassiveRouteProbe.cs'
$source = [System.IO.File]::ReadAllText($probePath)
$monitorPath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\DeviceConnectionMonitor.cs'
$monitorSource = [System.IO.File]::ReadAllText($monitorPath)
$wifiRepairPolicyPath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\WifiRepairConfirmationPolicy.cs'
$wifiRepairPolicySource = [System.IO.File]::ReadAllText($wifiRepairPolicyPath)
$agentMainPath = Join-Path `
    $repositoryRoot `
    'mirror\agent\cmd\rmmirror-probe\main.go'
$agentMain = [System.IO.File]::ReadAllText($agentMainPath)
$prerequisitePath = Join-Path `
    $repositoryRoot `
    'scripts\Install-RemarkableMirrorPrerequisites.ps1'
$prerequisiteSource = [System.IO.File]::ReadAllText($prerequisitePath)

$expectedOsReleaseParser = @'
        os_version="$(sed -n 's/^IMG_VERSION=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
        os_build="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
'@.Replace("`r`n", "`n").TrimEnd()

if (-not $source.Replace("`r`n", "`n").Contains(
        $expectedOsReleaseParser,
        [StringComparison]::Ordinal)) {
    throw 'Passive route probe does not use the proven os-release parser.'
}

if ($source.Contains('\{0,1\}', [StringComparison]::Ordinal)) {
    throw 'Passive route probe still contains the broken optional-quote sed expression.'
}

foreach ($requiredMarker in @(
        'internal static PassiveRouteProbeResult ClassifyAuthenticationResult(',
        'var identityAuthenticated = standardOutput.Contains(',
        'IdentityAuthenticated: true',
        'bool IdentityAuthenticated = false'
    )) {
    if (-not $source.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Passive route authentication evidence is missing marker: $requiredMarker"
    }
}

foreach ($requiredMarker in @(
        'result.IdentityAuthenticated',
        'result.Detail is PassiveRouteProbeDetail.TabletPrerequisiteMismatch',
        '? DeviceConnectionStatus.WakeSetupRequired',
        ': DeviceConnectionStatus.Disconnected'
    )) {
    if (-not $monitorSource.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Wi-Fi repair classification is missing marker: $requiredMarker"
    }
}
if (-not $wifiRepairPolicySource.Contains(
        'private const int RequiredConsecutiveMatches = 2;',
        [StringComparison]::Ordinal)) {
    throw 'Wi-Fi tablet repair no longer requires two consecutive authenticated mismatches.'
}

$usbWakeSetupPattern = [regex]::new(
    'if\s*\(kind\s+is\s+DeviceRouteKind\.Usb\)\s*\{\s*' +
    'return\s+DeviceConnectionStatus\.WakeSetupRequired;',
    [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $usbWakeSetupPattern.IsMatch($monitorSource)) {
    throw 'Direct USB setup failures no longer map immediately to Repair.'
}

$escapedProbePath = [System.Security.SecurityElement]::Escape($probePath)
$sshRoutePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\SshRoute.cs'
$escapedSshRoutePath = [System.Security.SecurityElement]::Escape($sshRoutePath)
$sshJobPath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\SshChildProcessJob.cs'
$escapedSshJobPath = [System.Security.SecurityElement]::Escape($sshJobPath)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-passive-route-validation-' + [guid]::NewGuid().ToString('N'))
$temporaryProjectPath = Join-Path $temporaryRoot 'PassiveRouteValidation.csproj'
$temporaryProgramPath = Join-Path $temporaryRoot 'Program.cs'
$temporaryProject = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$escapedProbePath" Link="PassiveRouteProbe.cs" />
    <Compile Include="$escapedSshRoutePath" Link="SshRoute.cs" />
    <Compile Include="$escapedSshJobPath" Link="SshChildProcessJob.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@
$temporaryProgram = @'
namespace ReMarkableMirror;

internal static class Program
{
    public static int Main()
    {
        var output = """
            RMMIRROR_ROUTE_AUTHENTICATED=1
            RMMIRROR_CAP_BOOT_ID=00000000-0000-0000-0000-000000000001
            RMMIRROR_CAP_ACTIVE_ROOT=/dev/root
            RMMIRROR_CAP_OS_VERSION=3.28.0.164
            RMMIRROR_CAP_OS_BUILD=5.8.199
            RMMIRROR_CAP_KERNEL=6.0.0
            RMMIRROR_CAP_PROBE_VERSION=
            RMMIRROR_CAP_TRANSPORT_VERSION=0.6.0
            RMMIRROR_CAP_TRANSPORT_SCHEMA=rmmirror.transport-wake/v1
            RMMIRROR_CAP_TRANSPORT_ACTIVE=active
            RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY=true
            RMMIRROR_CAP_XOVI_VERSION=v19-23052026
            RMMIRROR_ROUTE_PREREQUISITE_MISMATCH=1
            """;
        var result = PassiveRouteProbe.ClassifyAuthenticationResult(42, output, string.Empty);
        if (result.State is not PassiveRouteProbeState.PrerequisiteMismatch ||
            result.Detail is not PassiveRouteProbeDetail.TabletPrerequisiteMismatch ||
            result.Capability is not null ||
            !result.IdentityAuthenticated)
        {
            Console.Error.WriteLine("Authenticated missing-component mismatch was not preserved.");
            return 1;
        }

        Console.WriteLine("AuthenticatedMissingComponent: PASS");
        return 0;
    }
}
'@

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    [System.IO.File]::WriteAllText($temporaryProjectPath, $temporaryProject)
    [System.IO.File]::WriteAllText($temporaryProgramPath, $temporaryProgram)
    & dotnet run --project $temporaryProjectPath -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "Passive route classification validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$abortiveClosePattern = [regex]::new(
    'var\s+socket\s*=\s*client\.Client;\s*' +
    'socket\.LingerState\s*=\s*new\s+LingerOption\(enable:\s*true,\s*seconds:\s*0\);\s*' +
    'socket\.Close\(timeout:\s*0\);',
    [Text.RegularExpressions.RegexOptions]::Singleline)
$abortiveCloseCases = @(
    @{
        Name = 'passive route probe'
        Source = $source
        CleanupPattern = [regex]::new(
            'private\s+async\s+Task<PassiveRouteProbeResult\?>\s+ProbeBannerAsync\b.*?' +
            'finally\s*\{\s*UseAbortiveClose\(client\);\s*\}\s*\}\s*' +
            'private\s+static\s+void\s+UseAbortiveClose',
            [Text.RegularExpressions.RegexOptions]::Singleline)
    }
    @{
        Name = 'device connection monitor'
        Source = $monitorSource
        CleanupPattern = [regex]::new(
            'private\s+async\s+Task<DeviceConnectionStatus>\s+ProbeUsbSshAsync\b.*?' +
            'finally\s*\{\s*UseAbortiveClose\(client\);\s*\}\s*\}\s*' +
            'private\s+static\s+void\s+UseAbortiveClose',
            [Text.RegularExpressions.RegexOptions]::Singleline)
    }
)
foreach ($case in $abortiveCloseCases) {
    if (-not $abortiveClosePattern.IsMatch($case.Source)) {
        throw 'A Windows SSH-banner path does not close its underlying socket abortively.'
    }
    if (-not $case.CleanupPattern.IsMatch($case.Source)) {
        throw "The $($case.Name) does not invoke abortive close from its probe cleanup path."
    }
}

$versionMatch = [regex]::Match(
    $agentMain,
    'const version = "(?<version>[0-9]+\.[0-9]+\.[0-9]+)"')
if (-not $versionMatch.Success) {
    throw 'Could not read the rmmirror-probe version from the Go source.'
}
$probeVersion = $versionMatch.Groups['version'].Value
if (-not $source.Contains(
        "private const string ExpectedProbeVersion = `"$probeVersion`";",
        [StringComparison]::Ordinal) -or
    -not $source.Contains(
        "test `"`$probe_version`" = '$probeVersion' || mismatch=1",
        [StringComparison]::Ordinal) -or
    -not $prerequisiteSource.Contains(
        "`$mirrorProbeVersion = '$probeVersion'",
        [StringComparison]::Ordinal)) {
    throw 'The Windows passive probe and tablet companion versions do not match.'
}

Write-Host 'PASS: passive route probe uses the proven os-release parser.'
Write-Host "PASS: passive route probe expects rmmirror-probe $probeVersion."
Write-Host 'PASS: authenticated missing-component mismatches retain identity proof.'
Write-Host 'PASS: both Windows SSH-banner probe cleanup paths explicitly close the underlying socket.'
Write-Host 'PASS: Wi-Fi Repair requires a repeated authenticated tablet mismatch; direct USB remains immediate.'
