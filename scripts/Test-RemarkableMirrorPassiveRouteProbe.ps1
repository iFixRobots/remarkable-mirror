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
Write-Host 'PASS: both Windows SSH-banner probe cleanup paths explicitly close the underlying socket.'
