[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory,
    [string]$Publisher = 'CN=iFixRobots',
    [Guid]$PackageIdentity = [Guid]'A184FD6B-E071-4B75-A3B4-DF4397457284',
    [string]$PublisherDisplayName,
    [string]$PrebuiltFilesLoopbackPath,
    [string]$PrebuiltFilesLoopbackSha256,
    [switch]$AllowDirtyOfficialDevelopmentBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$globalJsonPath = Join-Path $repositoryRoot 'global.json'
$projectPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj'
$packagesLockPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\packages.lock.json'
$nugetConfigPath = Join-Path $repositoryRoot 'mirror\windows\NuGet.config'
$windowsSourceDirectory = Join-Path $repositoryRoot 'mirror\windows'
$installerScriptPath = Join-Path $PSScriptRoot 'Install-RemarkableMirror.ps1'
$installerLauncherPath = Join-Path $PSScriptRoot 'Install-RemarkableMirror.cmd'
$prerequisiteScriptPath = Join-Path $PSScriptRoot 'Install-RemarkableMirrorPrerequisites.ps1'
$captureHelperPath = Join-Path $PSScriptRoot 'lib\RemarkableRmctlCapture.ps1'
$releaseProvenancePath = Join-Path $PSScriptRoot 'lib\RemarkableReleaseProvenance.ps1'
$filesLoopbackArtifactHelperPath = Join-Path $PSScriptRoot 'lib\RemarkableFilesLoopbackArtifact.ps1'
$probeBuildScriptPath = Join-Path $PSScriptRoot 'Build-RemarkableMirrorAgent.ps1'
$probeMainSourcePath = Join-Path $repositoryRoot 'mirror\agent\cmd\rmmirror-probe\main.go'
$passiveRouteProbePath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\PassiveRouteProbe.cs'
$macPassiveRouteProbePath = Join-Path $repositoryRoot 'mirror\macos\ReMarkableMirror\PassiveRouteProbe.swift'
$transportServiceSourcePath = Join-Path $repositoryRoot 'mirror\agent\internal\transportwake\service.go'
$transportBuildScriptPath = Join-Path $PSScriptRoot 'Build-RemarkableTransportWake.ps1'
$filesLoopbackBuildScriptPath = Join-Path $PSScriptRoot 'Build-RemarkableFilesLoopback.ps1'
$transportUnitPath = Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-transport-wake.service'
$transportInstallPath = Join-Path $repositoryRoot 'mirror\agent\deploy\install-transport-wake.sh'
$transportSleepGuardPath = Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-usb-sleep-guard.conf'
$prerequisiteInstallPath = Join-Path $repositoryRoot 'mirror\agent\deploy\install-mirror-prerequisites.sh'
$prerequisiteContractPath = Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-prerequisites.env'
$publicOnboardingGuidePath = Join-Path $repositoryRoot 'docs\PACKAGE_ONBOARDING.md'
$publicGettingStartedGuidePath = Join-Path $repositoryRoot 'docs\GETTING_STARTED.md'
$publicTroubleshootingGuidePath = Join-Path $repositoryRoot 'docs\TROUBLESHOOTING.md'
$publicPlatformSupportGuidePath = Join-Path $repositoryRoot 'docs\PLATFORM_SUPPORT.md'
$publicTabletChangesGuidePath = Join-Path $repositoryRoot 'docs\TABLET_CHANGES.md'
$publicUninstallGuidePath = Join-Path $repositoryRoot 'docs\UNINSTALL.md'
$publicOnboardingImagesDirectory = Join-Path $repositoryRoot 'docs\images'
$xoviNoticePath = Join-Path $repositoryRoot 'mirror\third-party\xovi\NOTICE.txt'
$xoviLicensePath = Join-Path $repositoryRoot 'mirror\third-party\xovi\LICENSE-GPL-3.0.txt'
$microsoftNoticesDirectoryPath = Join-Path $repositoryRoot 'mirror\third-party\microsoft'
$microsoftNoticesIndexPath = Join-Path $microsoftNoticesDirectoryPath 'README.md'
$repositoryLicensePath = Join-Path $repositoryRoot 'LICENSE'
$projectLicensePath = if (Test-Path -LiteralPath $repositoryLicensePath -PathType Leaf) {
    $repositoryLicensePath
}
else {
    $xoviLicensePath
}
$repositoryNoticePath = Join-Path $repositoryRoot 'NOTICE'
$projectNoticePath = if (Test-Path -LiteralPath $repositoryNoticePath -PathType Leaf) {
    $repositoryNoticePath
}
else {
    Join-Path $repositoryRoot 'mirror\public\NOTICE'
}
$repositoryThirdPartyNoticesPath = Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md'
$projectThirdPartyNoticesPath = if (Test-Path -LiteralPath $repositoryThirdPartyNoticesPath -PathType Leaf) {
    $repositoryThirdPartyNoticesPath
}
else {
    Join-Path $repositoryRoot 'mirror\public\THIRD_PARTY_NOTICES.md'
}
$officialPublisher = 'CN=iFixRobots'
$publisher = $Publisher.Trim()
$identityName = $PackageIdentity.ToString('D').ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($publisher) -or $publisher -match "[`r`n]") {
    throw 'Publisher must be a non-empty single-line X.500 subject.'
}
if ([string]::IsNullOrWhiteSpace($PublisherDisplayName)) {
    if ($publisher -ieq $officialPublisher) {
        $PublisherDisplayName = 'iFixRobots'
    }
    else {
        $commonName = [regex]::Match(
            $publisher,
            '(?i)(?:^|,\s*)CN\s*=\s*(?<name>[^,]+)')
        $PublisherDisplayName = if ($commonName.Success) {
            $commonName.Groups['name'].Value.Trim().Trim('"')
        }
        else {
            'Development'
        }
    }
}
$PublisherDisplayName = $PublisherDisplayName.Trim()
if ([string]::IsNullOrWhiteSpace($PublisherDisplayName) -or
    $PublisherDisplayName -match "[`r`n]") {
    throw 'PublisherDisplayName must be a non-empty single-line value.'
}
foreach ($requiredPath in @(
        $globalJsonPath,
        $projectPath,
        $packagesLockPath,
        $nugetConfigPath,
        $installerScriptPath,
        $installerLauncherPath,
        $prerequisiteScriptPath,
        $captureHelperPath,
        $releaseProvenancePath,
        $filesLoopbackArtifactHelperPath,
        $probeBuildScriptPath,
        $probeMainSourcePath,
        $passiveRouteProbePath,
        $macPassiveRouteProbePath,
        $transportServiceSourcePath,
        $transportBuildScriptPath,
        $filesLoopbackBuildScriptPath,
        $transportUnitPath,
        $transportInstallPath,
        $transportSleepGuardPath,
        $prerequisiteInstallPath,
        $prerequisiteContractPath,
        $publicOnboardingGuidePath,
        $publicGettingStartedGuidePath,
        $publicTroubleshootingGuidePath,
        (Join-Path $publicOnboardingImagesDirectory 'remarkable-mirror-live-wifi.png'),
        (Join-Path $publicOnboardingImagesDirectory 'remarkable-mirror-preparing.png'),
        $projectLicensePath,
        $projectNoticePath,
        $projectThirdPartyNoticesPath,
        $microsoftNoticesIndexPath,
        $xoviNoticePath,
        $xoviLicensePath
    )) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required packaging input does not exist: $requiredPath"
    }
}

$prerequisiteContract = @{}
foreach ($line in [System.IO.File]::ReadAllLines($prerequisiteContractPath)) {
    if ($line -cnotmatch '^([A-Z0-9_]+)=([A-Za-z0-9.,/+_-]+)$' -or
        $prerequisiteContract.ContainsKey($Matches[1])) {
        throw 'The tablet prerequisite contract is malformed.'
    }
    $prerequisiteContract[$Matches[1]] = $Matches[2]
}
$expectedPrerequisiteContractKeys = @(
    'RMMIRROR_PREREQUISITES_SCHEMA',
    'RMMIRROR_TABLET_MODEL',
    'RMMIRROR_TABLET_INSTALL_TARGETS',
    'RMMIRROR_XOVI_RELEASE',
    'RMMIRROR_XOVI_ARCHIVE_SHA256',
    'RMMIRROR_PROBE_VERSION',
    'RMMIRROR_TRANSPORT_VERSION',
    'RMMIRROR_TRANSPORT_SCHEMA',
    'RMMIRROR_USB_CONNECTION_POLICY',
    'RMMIRROR_REQUIRED_EXTENSIONS'
)
$actualPrerequisiteContractKeys =
    ($prerequisiteContract.Keys | Sort-Object) -join "`n"
$sortedExpectedPrerequisiteContractKeys =
    ($expectedPrerequisiteContractKeys | Sort-Object) -join "`n"
if ($actualPrerequisiteContractKeys -cne $sortedExpectedPrerequisiteContractKeys) {
    throw 'The tablet prerequisite contract has unexpected fields.'
}
$xoviRelease = $prerequisiteContract['RMMIRROR_XOVI_RELEASE']
$xoviArchiveHashExpected = $prerequisiteContract['RMMIRROR_XOVI_ARCHIVE_SHA256']
$mirrorProbeVersion = $prerequisiteContract['RMMIRROR_PROBE_VERSION']
$tabletPrerequisiteComponentNames = @(
    'install-mirror-prerequisites.sh',
    'rmmirror-prerequisites.env',
    'rmmirror-probe',
    'xovi-aarch64.tar.gz',
    'rmmirror-files-loopback.so',
    'rmmirror-transport-wake',
    'rmmirror-transport-wake.service',
    'install-transport-wake.sh',
    'rmmirror-usb-sleep-guard.conf'
)

$hasPrebuiltFilesLoopbackPath = -not [string]::IsNullOrWhiteSpace($PrebuiltFilesLoopbackPath)
$hasPrebuiltFilesLoopbackHash = -not [string]::IsNullOrWhiteSpace($PrebuiltFilesLoopbackSha256)
if ($hasPrebuiltFilesLoopbackPath -ne $hasPrebuiltFilesLoopbackHash) {
    throw 'PrebuiltFilesLoopbackPath and PrebuiltFilesLoopbackSha256 must be supplied together.'
}
$usePrebuiltFilesLoopback = $hasPrebuiltFilesLoopbackPath
if ($usePrebuiltFilesLoopback) {
    $PrebuiltFilesLoopbackPath = [System.IO.Path]::GetFullPath($PrebuiltFilesLoopbackPath)
}

$probeMainSource = [System.IO.File]::ReadAllText($probeMainSourcePath)
$probeVersionMatch = [regex]::Match(
    $probeMainSource,
    'const version = "(?<version>[0-9]+\.[0-9]+\.[0-9]+)"')
if (-not $probeVersionMatch.Success) {
    throw 'Could not read the rmmirror-probe version from the Go source.'
}
$passiveRouteProbeSource = [System.IO.File]::ReadAllText($passiveRouteProbePath)
$windowsVersionMatch = [regex]::Match(
    $passiveRouteProbeSource,
    'ExpectedProbeVersion\s*=\s*"(?<version>[0-9]+\.[0-9]+\.[0-9]+)"')
$capabilityVersionMatch = [regex]::Match(
    $passiveRouteProbeSource,
    'test "\$probe_version" = ''(?<version>[0-9]+\.[0-9]+\.[0-9]+)''')
if (-not $windowsVersionMatch.Success -or -not $capabilityVersionMatch.Success) {
    throw 'Could not read both expected rmmirror-probe versions from the Windows route probe.'
}

$probeVersionConsumers = @(
    $probeVersionMatch.Groups['version'].Value,
    $windowsVersionMatch.Groups['version'].Value,
    $capabilityVersionMatch.Groups['version'].Value
)
if (@($probeVersionConsumers | Where-Object { $_ -cne $mirrorProbeVersion }).Count -ne 0) {
    throw "rmmirror-probe version drift: producer is $mirrorProbeVersion; consumers are $($probeVersionConsumers -join ', ')."
}

$usbPolicySources = [ordered]@{
    Producer = @{
        Text = [System.IO.File]::ReadAllText($transportServiceSourcePath)
        Pattern = 'CurrentUSBConnectionPolicy\s*=\s*"(?<policy>[^"]+)"'
    }
    WindowsExpected = @{
        Text = $passiveRouteProbeSource
        Pattern = 'ExpectedUsbConnectionPolicy\s*=\s*"(?<policy>[^"]+)"'
    }
    WindowsProbe = @{
        Text = $passiveRouteProbeSource
        Pattern = 'test "\$usb_connection_policy" = ''(?<policy>[^'']+)'' \|\| mismatch=1'
    }
    Contract = @{
        Text = "RMMIRROR_USB_CONNECTION_POLICY=$($prerequisiteContract['RMMIRROR_USB_CONNECTION_POLICY'])"
        Pattern = 'RMMIRROR_USB_CONNECTION_POLICY=(?<policy>[^\r\n]+)'
    }
    MacExpected = @{
        Text = [System.IO.File]::ReadAllText($macPassiveRouteProbePath)
        Pattern = 'expectedUSBConnectionPolicy\s*=\s*"(?<policy>[^"]+)"'
    }
    MacProbe = @{
        Text = [System.IO.File]::ReadAllText($macPassiveRouteProbePath)
        Pattern = 'test "\$usb_connection_policy" = ''(?<policy>[^'']+)'' \|\| mismatch=1'
    }
    TabletInstaller = @{
        Text = [System.IO.File]::ReadAllText($transportInstallPath)
        Pattern = '"usb_connection_policy":"(?<policy>[^"]+)"'
    }
}
$usbPolicyValues = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $usbPolicySources.GetEnumerator()) {
    $match = [regex]::Match($entry.Value.Text, $entry.Value.Pattern)
    if (-not $match.Success) {
        throw "Could not read the USB connection-policy capability from $($entry.Key)."
    }
    $usbPolicyValues.Add($match.Groups['policy'].Value)
}
if (@($usbPolicyValues | Select-Object -Unique).Count -ne 1) {
    throw "USB connection-policy capability drift: $($usbPolicyValues -join ', ')."
}

. $releaseProvenancePath
. $filesLoopbackArtifactHelperPath
$releaseProvenance = Get-RemarkableReleaseProvenance `
    -RepositoryRoot $repositoryRoot `
    -Publisher $publisher `
    -OfficialPublisher $officialPublisher `
    -AllowDirtyOfficialDevelopmentBuild:$AllowDirtyOfficialDevelopmentBuild
$sourceCommit = $releaseProvenance.SourceCommit
$sourceDirty = $releaseProvenance.SourceDirty

if ([string]::IsNullOrWhiteSpace($Version)) {
    $now = [DateTime]::UtcNow
    $Version = '1.{0}.{1}.{2}' -f `
        [int]$now.ToString('yyMM'), `
        [int]$now.ToString('ddHH'), `
        [int]$now.ToString('mmss')
}

$versionParts = $Version -split '\.'
if ($versionParts.Count -ne 4) {
    throw "MSIX version must contain four numeric parts: $Version"
}
$canonicalVersionParts = [System.Collections.Generic.List[string]]::new()
foreach ($versionPart in $versionParts) {
    [uint16]$component = 0
    if (-not [uint16]::TryParse($versionPart, [ref]$component)) {
        throw "Every MSIX version part must be an integer from 0 through 65535: $Version"
    }
    $canonicalVersionParts.Add($component.ToString([Globalization.CultureInfo]::InvariantCulture))
}
$Version = $canonicalVersionParts -join '.'

$expectedDotnetSdkVersion = '10.0.303'
$dotnet = (Get-Command dotnet.exe -ErrorAction Stop).Source
Push-Location $repositoryRoot
try {
    $dotnetSdkVersion = ((& $dotnet --version 2>&1) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $dotnetSdkVersion -cne $expectedDotnetSdkVersion) {
        throw "This verified package build requires .NET SDK $expectedDotnetSdkVersion; found '$dotnetSdkVersion'."
    }
    $dotnetInfo = (& $dotnet --info 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read the .NET SDK and host runtime information.'
    }
}
finally {
    Pop-Location
}
$dotnetHostMatch = [regex]::Match(
    $dotnetInfo,
    '(?ms)^Host:\s*\r?\n\s*Version:\s*(?<version>[^\r\n]+)\r?\n\s*Architecture:\s*(?<architecture>[^\r\n]+)')
if (-not $dotnetHostMatch.Success) {
    throw 'Could not parse the .NET host runtime version and architecture from dotnet --info.'
}
$dotnetHostVersion = $dotnetHostMatch.Groups['version'].Value.Trim()
$dotnetHostArchitecture = $dotnetHostMatch.Groups['architecture'].Value.Trim()

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'artifacts\remarkable-mirror'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

function Find-WindowsSdkTool {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitsRoot -PathType Container)) {
        throw "Windows SDK tools directory was not found: $kitsRoot"
    }

    $tool = Get-ChildItem -LiteralPath $kitsRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\$Name" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($tool)) {
        throw "$Name was not found. Install the Windows 10 or 11 SDK."
    }
    return $tool
}

function Get-AppxArchiveIdentity {
    param([Parameter(Mandatory)][string]$Path)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifestEntry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $manifestEntry) {
            throw "AppxManifest.xml was not found in $Path"
        }
        $manifestStream = $manifestEntry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($manifestStream)
            try {
                [xml]$manifest = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $manifestStream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    $identity = $manifest.Package.Identity
    foreach ($requiredAttribute in @('Name', 'Publisher', 'Version', 'ProcessorArchitecture')) {
        if ([string]::IsNullOrWhiteSpace([string]$identity.$requiredAttribute)) {
            throw "Runtime package identity is missing $requiredAttribute in $Path"
        }
    }
    [pscustomobject]@{
        Name = [string]$identity.Name
        Publisher = [string]$identity.Publisher
        Version = [string]$identity.Version
        Architecture = [string]$identity.ProcessorArchitecture
    }
}

function Assert-AppOwnedPackageBinaryPrivacy {
    param(
        [Parameter(Mandatory)][string]$UnpackDirectory,
        [Parameter(Mandatory)][string[]]$SensitiveRoots
    )

    $normalizedSensitiveRoots = @(
        $SensitiveRoots |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') } |
            Sort-Object -Unique
    )

    foreach ($binaryName in @('ReMarkableMirror.dll', 'ReMarkableMirror.exe')) {
        $binaryPath = Join-Path $UnpackDirectory $binaryName
        if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
            throw "Finished MSIX is missing app-owned binary: $binaryName"
        }

        $stream = [System.IO.File]::OpenRead($binaryPath)
        try {
            $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
            try {
                foreach ($entry in $peReader.ReadDebugDirectory()) {
                    if ($entry.Type -ne [System.Reflection.PortableExecutable.DebugDirectoryEntryType]::CodeView) {
                        continue
                    }
                    $codeViewPath = $peReader.ReadCodeViewDebugDirectoryData($entry).Path
                    if (-not [System.IO.Path]::IsPathRooted($codeViewPath)) {
                        continue
                    }

                    # The SDK-provided native apphost carries the .NET runtime build's
                    # own apphost.pdb provenance. It is not produced from this checkout.
                    $normalizedCodeViewPath = $codeViewPath.Replace('/', '\')
                    $isFrameworkAppHost =
                        $binaryName -ceq 'ReMarkableMirror.exe' -and
                        [System.IO.Path]::GetFileName($normalizedCodeViewPath) -ieq 'apphost.pdb' -and
                        $normalizedCodeViewPath -match '(?i)\\src\\runtime\\artifacts\\obj\\.+\\corehost\\apphost\\standalone\\apphost\.pdb$'
                    if (-not $isFrameworkAppHost) {
                        throw "Finished MSIX contains a rooted application CodeView PDB path in $binaryName."
                    }
                }
            }
            finally {
                $peReader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }

        $binaryBytes = [System.IO.File]::ReadAllBytes($binaryPath)
        $binaryTextViews = [System.Collections.Generic.List[string]]::new()
        $binaryTextViews.Add([System.Text.Encoding]::ASCII.GetString($binaryBytes))
        $binaryTextViews.Add([System.Text.Encoding]::UTF8.GetString($binaryBytes))
        $binaryTextViews.Add([System.Text.Encoding]::Unicode.GetString($binaryBytes))
        if ($binaryBytes.Length -gt 1) {
            $binaryTextViews.Add(
                [System.Text.Encoding]::Unicode.GetString(
                    $binaryBytes,
                    1,
                    $binaryBytes.Length - 1
                )
            )
        }

        foreach ($sensitiveRoot in $normalizedSensitiveRoots) {
            foreach ($sensitiveVariant in @(
                    $sensitiveRoot,
                    $sensitiveRoot.Replace('\', '/')
                ) | Sort-Object -Unique) {
                foreach ($binaryText in $binaryTextViews) {
                    if ($binaryText.IndexOf(
                            $sensitiveVariant,
                            [StringComparison]::OrdinalIgnoreCase
                        ) -ge 0) {
                        throw "Finished MSIX embeds the package build's repository or user-profile path in $binaryName."
                    }
                }
            }
        }
    }
}

function Assert-TabletPrerequisiteComponents {
    param(
        [Parameter(Mandatory)][string]$ComponentDirectory,
        [Parameter(Mandatory)][hashtable]$ExpectedSources,
        [Parameter(Mandatory)][string]$ArtifactName
    )

    if (-not (Test-Path -LiteralPath $ComponentDirectory -PathType Container)) {
        throw "$ArtifactName is missing its tablet prerequisite components directory."
    }

    $expectedNames = [string[]]$tabletPrerequisiteComponentNames.Clone()
    $actualFiles = @(Get-ChildItem -LiteralPath $ComponentDirectory -File)
    $actualNames = [string[]]@($actualFiles | ForEach-Object Name)
    [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
    [Array]::Sort($actualNames, [StringComparer]::Ordinal)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw "$ArtifactName has an unexpected tablet prerequisite component set: $($actualNames -join ', ')."
    }

    foreach ($componentName in $tabletPrerequisiteComponentNames) {
        if (-not $ExpectedSources.ContainsKey($componentName)) {
            throw "No audited source was supplied for tablet prerequisite component: $componentName"
        }

        $componentPath = Join-Path $ComponentDirectory $componentName
        $component = Get-Item -LiteralPath $componentPath
        if ($component.Length -le 0) {
            throw "$ArtifactName contains an empty tablet prerequisite component: $componentName"
        }

        $expectedHash = (Get-FileHash -LiteralPath $ExpectedSources[$componentName] -Algorithm SHA256).Hash
        $actualHash = (Get-FileHash -LiteralPath $componentPath -Algorithm SHA256).Hash
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHash, $expectedHash)) {
            throw "$ArtifactName tablet prerequisite hash mismatch: $componentName"
        }
    }
}

function Assert-TabletPrerequisiteBundle {
    param(
        [Parameter(Mandatory)][string]$BundleDirectory,
        [Parameter(Mandatory)][hashtable]$ExpectedSources,
        [Parameter(Mandatory)][string]$ArtifactName
    )

    $expectedRelativePaths = [string[]]@(
        'Install-RemarkableMirrorPrerequisites.ps1',
        'lib\RemarkableRmctlCapture.ps1'
        $tabletPrerequisiteComponentNames |
            ForEach-Object { "components\$_" }
    )
    $actualRelativePaths = [string[]]@(
        Get-ChildItem -LiteralPath $BundleDirectory -File -Recurse |
            ForEach-Object {
                [System.IO.Path]::GetRelativePath($BundleDirectory, $_.FullName).Replace('/', '\')
            }
    )
    [Array]::Sort($expectedRelativePaths, [StringComparer]::Ordinal)
    [Array]::Sort($actualRelativePaths, [StringComparer]::Ordinal)
    if (($actualRelativePaths -join "`n") -cne ($expectedRelativePaths -join "`n")) {
        throw "$ArtifactName has an unexpected TabletPrerequisites bundle: $($actualRelativePaths -join ', ')."
    }

    $rootFiles = @(
        Get-ChildItem -LiteralPath $BundleDirectory -File |
            ForEach-Object Name
    )
    if ($rootFiles.Count -ne 1 -or
        $rootFiles[0] -cne 'Install-RemarkableMirrorPrerequisites.ps1') {
        throw "$ArtifactName must contain only the prerequisite adapter at the TabletPrerequisites root."
    }

    $adapterPath = Join-Path $BundleDirectory 'Install-RemarkableMirrorPrerequisites.ps1'
    $capturePath = Join-Path $BundleDirectory 'lib\RemarkableRmctlCapture.ps1'
    foreach ($filePair in @(
            @{ Actual = $adapterPath; Expected = $prerequisiteScriptPath; Name = 'prerequisite adapter' },
            @{ Actual = $capturePath; Expected = $captureHelperPath; Name = 'capture helper' }
        )) {
        $actualHash = (Get-FileHash -LiteralPath $filePair.Actual -Algorithm SHA256).Hash
        $expectedHash = (Get-FileHash -LiteralPath $filePair.Expected -Algorithm SHA256).Hash
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualHash, $expectedHash)) {
            throw "$ArtifactName $($filePair.Name) hash does not match its audited source."
        }
    }

    Assert-TabletPrerequisiteComponents `
        -ComponentDirectory (Join-Path $BundleDirectory 'components') `
        -ExpectedSources $ExpectedSources `
        -ArtifactName $ArtifactName
}

function Copy-TabletPrerequisiteBundle {
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][hashtable]$ExpectedSources,
        [Parameter(Mandatory)][string]$ArtifactName
    )

    $bundleDirectory = Join-Path $DestinationRoot 'TabletPrerequisites'
    if (Test-Path -LiteralPath $bundleDirectory) {
        throw "Refusing to overwrite an existing TabletPrerequisites bundle: $bundleDirectory"
    }

    $libDirectory = Join-Path $bundleDirectory 'lib'
    $componentDirectory = Join-Path $bundleDirectory 'components'
    New-Item -ItemType Directory -Path $libDirectory, $componentDirectory -Force | Out-Null
    Copy-Item -LiteralPath $prerequisiteScriptPath -Destination $bundleDirectory
    Copy-Item -LiteralPath $captureHelperPath -Destination $libDirectory
    foreach ($componentName in $tabletPrerequisiteComponentNames) {
        Copy-Item -LiteralPath $ExpectedSources[$componentName] -Destination $componentDirectory
    }

    Assert-TabletPrerequisiteBundle `
        -BundleDirectory $bundleDirectory `
        -ExpectedSources $ExpectedSources `
        -ArtifactName $ArtifactName
    return $bundleDirectory
}

function Assert-PortableTabletPrerequisiteBundle {
    param(
        [Parameter(Mandatory)][string]$PortableExecutable,
        [Parameter(Mandatory)][string]$ExtractionRoot,
        [Parameter(Mandatory)][hashtable]$ExpectedSources
    )

    New-Item -ItemType Directory -Path $ExtractionRoot -Force | Out-Null
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PortableExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = $ExtractionRoot
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Could not start the portable executable for its local bundle audit.'
    }

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $bundleDirectory = $null
        $mainWindowReady = $false
        do {
            $process.Refresh()
            if ($process.HasExited) {
                throw "Portable executable exited during its bundle audit with code $($process.ExitCode)."
            }
            $mainWindowReady = $process.MainWindowHandle -ne [IntPtr]::Zero
            $bundleDirectory = @(
                Get-ChildItem -LiteralPath $ExtractionRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ceq 'TabletPrerequisites' }
            ) | Select-Object -First 1
            if ($null -ne $bundleDirectory) {
                $requiredFiles = @(
                    Get-ChildItem -LiteralPath $bundleDirectory.FullName -File -Recurse -ErrorAction SilentlyContinue
                )
                if ($requiredFiles.Count -eq ($tabletPrerequisiteComponentNames.Count + 2) -and
                    $mainWindowReady) {
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)

        if ($null -eq $bundleDirectory) {
            throw 'Portable executable did not extract its TabletPrerequisites bundle within 30 seconds.'
        }
        $process.Refresh()
        if ($process.HasExited) {
            throw "Portable executable exited during its bundle audit with code $($process.ExitCode)."
        }
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
            throw 'Portable executable did not open its main window within 30 seconds.'
        }
        Assert-TabletPrerequisiteBundle `
            -BundleDirectory $bundleDirectory.FullName `
            -ExpectedSources $ExpectedSources `
            -ArtifactName 'Portable executable'
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-OrCreateSigningCertificate {
    $codeSigningOid = '1.3.6.1.5.5.7.3.3'
    $minimumExpiry = (Get-Date).AddDays(30)
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object {
            $ekuOids = @($_.EnhancedKeyUsageList | ForEach-Object { [string]$_.ObjectId })
            $_.Subject -eq $publisher -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt $minimumExpiry -and
            ($ekuOids -contains $codeSigningOid)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $certificate) {
        $certificate = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $publisher `
            -FriendlyName 'reMarkable Mirror local package signing' `
            -KeyAlgorithm RSA `
            -KeyLength 3072 `
            -HashAlgorithm SHA256 `
            -KeyUsage DigitalSignature `
            -KeyExportPolicy NonExportable `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotAfter (Get-Date).AddYears(5) `
            -TextExtension @(
                '2.5.29.37={text}1.3.6.1.5.5.7.3.3',
                '2.5.29.19={text}'
            )
    }

    if ($certificate.Subject -ne $publisher) {
        throw "Signing certificate subject must exactly match the MSIX publisher: $publisher"
    }
    return $certificate
}

$signTool = Find-WindowsSdkTool -Name 'signtool.exe'
$makeAppx = Find-WindowsSdkTool -Name 'makeappx.exe'
$certificate = Get-OrCreateSigningCertificate

$temporaryParent = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'tmp'))
New-Item -ItemType Directory -Path $temporaryParent -Force | Out-Null
$temporaryRoot = [System.IO.Path]::GetFullPath((Join-Path $temporaryParent ("mirror-package-{0}" -f [Guid]::NewGuid().ToString('N'))))
$temporaryPrefix = $temporaryParent.TrimEnd('\') + '\'
if (-not $temporaryRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary package path escaped the repository tmp directory: $temporaryRoot"
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

$releaseName = "ReMarkableMirror-$Version-x64"
$releaseDirectory = Join-Path $OutputDirectory $releaseName
$zipPath = Join-Path $OutputDirectory "$releaseName.zip"
$portablePath = Join-Path $OutputDirectory 'ReMarkableMirror.exe'
if (Test-Path -LiteralPath $releaseDirectory) {
    throw "Release directory already exists: $releaseDirectory"
}
if (Test-Path -LiteralPath $zipPath) {
    throw "Release archive already exists: $zipPath"
}
if (Test-Path -LiteralPath $portablePath) {
    throw "Portable executable already exists: $portablePath"
}

try {
    $prerequisiteAssetDirectory = Join-Path $temporaryRoot 'tablet-prerequisite-assets'
    New-Item -ItemType Directory -Path $prerequisiteAssetDirectory | Out-Null
    foreach ($staticAssetPath in @(
            $prerequisiteInstallPath,
            $prerequisiteContractPath,
            $transportUnitPath,
            $transportInstallPath,
            $transportSleepGuardPath
        )) {
        Copy-Item -LiteralPath $staticAssetPath -Destination $prerequisiteAssetDirectory
    }

    $probeBuildDirectory = Join-Path $temporaryRoot 'mirror-agent'
    $probeBuild = & $probeBuildScriptPath -OutputDirectory $probeBuildDirectory -Force
    if ($null -eq $probeBuild -or
        -not (Test-Path -LiteralPath $probeBuild.OutputPath -PathType Leaf)) {
        throw 'The mirror-agent build did not return a usable ARM64 binary.'
    }
    Copy-Item `
        -LiteralPath $probeBuild.OutputPath `
        -Destination (Join-Path $prerequisiteAssetDirectory 'rmmirror-probe')

    $transportBuildDirectory = Join-Path $temporaryRoot 'transport-wake'
    $transportBuild = & $transportBuildScriptPath -OutputDirectory $transportBuildDirectory -Force
    if ($null -eq $transportBuild -or
        -not (Test-Path -LiteralPath $transportBuild.OutputPath -PathType Leaf)) {
        throw 'The transport-wake build did not return a usable ARM64 binary.'
    }
    if ($transportBuild.GoVersion -cne $probeBuild.GoVersion) {
        throw "ARM64 companion Go toolchain drift: probe used '$($probeBuild.GoVersion)'; transport wake used '$($transportBuild.GoVersion)'."
    }
    Copy-Item `
        -LiteralPath $transportBuild.OutputPath `
        -Destination (Join-Path $prerequisiteAssetDirectory 'rmmirror-transport-wake')

    $filesLoopbackBuild = if ($usePrebuiltFilesLoopback) {
        Get-VerifiedRemarkableFilesLoopbackArtifact `
            -Path $PrebuiltFilesLoopbackPath `
            -ExpectedSha256 $PrebuiltFilesLoopbackSha256
    }
    else {
        $filesLoopbackBuildDirectory = Join-Path $temporaryRoot 'files-loopback'
        & $filesLoopbackBuildScriptPath `
            -OutputDirectory $filesLoopbackBuildDirectory `
            -Force
    }
    if ($null -eq $filesLoopbackBuild -or
        -not (Test-Path -LiteralPath $filesLoopbackBuild.OutputPath -PathType Leaf)) {
        throw 'The Files loopback build did not return a usable ARM64 shared object.'
    }
    Copy-Item `
        -LiteralPath $filesLoopbackBuild.OutputPath `
        -Destination (Join-Path $prerequisiteAssetDirectory 'rmmirror-files-loopback.so')

    $xoviArchivePath = Join-Path $temporaryRoot 'xovi-aarch64.tar.gz'
    $cachedXoviArchive = Join-Path $repositoryRoot "tmp\mirror\xovi-$xoviRelease\xovi-aarch64.tar.gz"
    if (Test-Path -LiteralPath $cachedXoviArchive -PathType Leaf) {
        Copy-Item -LiteralPath $cachedXoviArchive -Destination $xoviArchivePath
    }
    else {
        Invoke-WebRequest `
            -Uri "https://github.com/asivery/rm-xovi-extensions/releases/download/$xoviRelease/xovi-aarch64.tar.gz" `
            -OutFile $xoviArchivePath
    }
    $xoviArchiveHash = (Get-FileHash -LiteralPath $xoviArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($xoviArchiveHash -ne $xoviArchiveHashExpected) {
        throw "Unexpected Xovi archive hash: $xoviArchiveHash"
    }
    Copy-Item `
        -LiteralPath $xoviArchivePath `
        -Destination (Join-Path $prerequisiteAssetDirectory 'xovi-aarch64.tar.gz')

    $tabletPrerequisiteSources = @{}
    foreach ($componentName in $tabletPrerequisiteComponentNames) {
        $tabletPrerequisiteSources[$componentName] = Join-Path $prerequisiteAssetDirectory $componentName
    }
    Assert-TabletPrerequisiteComponents `
        -ComponentDirectory $prerequisiteAssetDirectory `
        -ExpectedSources $tabletPrerequisiteSources `
        -ArtifactName 'Prerequisite staging directory'

    $temporaryWindowsDirectory = Join-Path $temporaryRoot 'windows'
    & robocopy.exe $windowsSourceDirectory $temporaryWindowsDirectory /E /XD bin obj AppPackages /XF '*.user' /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) {
        throw "Could not stage the isolated Windows packaging source. Robocopy exit code: $LASTEXITCODE."
    }

    $buildProjectPath = Join-Path $temporaryWindowsDirectory 'ReMarkableMirror\ReMarkableMirror.csproj'
    $buildNugetConfigPath = Join-Path $temporaryWindowsDirectory 'NuGet.config'
    $buildManifestPath = Join-Path $temporaryWindowsDirectory 'ReMarkableMirror\Package.appxmanifest'
    [xml]$buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw
    $buildManifest.Package.Identity.Name = $identityName
    $buildManifest.Package.Identity.Publisher = $publisher
    $buildManifest.Package.Identity.Version = $Version
    $buildManifest.Package.PhoneIdentity.PhoneProductId = $identityName
    $buildManifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName
    $xmlSettings = [System.Xml.XmlWriterSettings]::new()
    $xmlSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $xmlSettings.Indent = $true
    $manifestWriter = [System.Xml.XmlWriter]::Create($buildManifestPath, $xmlSettings)
    try {
        $buildManifest.Save($manifestWriter)
    }
    finally {
        $manifestWriter.Dispose()
    }

    $buildProjectDirectory = Split-Path -Parent $buildProjectPath
    $buildLegalDirectory = Join-Path $buildProjectDirectory 'Legal'
    $buildMicrosoftNoticesDirectory = Join-Path $buildProjectDirectory 'ThirdParty\Microsoft'
    New-Item -ItemType Directory -Path $buildLegalDirectory, $buildMicrosoftNoticesDirectory -Force | Out-Null
    Copy-Item -LiteralPath $projectLicensePath -Destination (Join-Path $buildLegalDirectory 'LICENSE')
    Copy-Item -LiteralPath $projectNoticePath -Destination (Join-Path $buildLegalDirectory 'NOTICE')
    Copy-Item -LiteralPath $projectThirdPartyNoticesPath -Destination (Join-Path $buildLegalDirectory 'THIRD_PARTY_NOTICES.md')
    Copy-Item -Path (Join-Path $microsoftNoticesDirectoryPath '*') `
        -Destination $buildMicrosoftNoticesDirectory `
        -Recurse
    $stagedTabletPrerequisiteBundle = Copy-TabletPrerequisiteBundle `
        -DestinationRoot $buildProjectDirectory `
        -ExpectedSources $tabletPrerequisiteSources `
        -ArtifactName 'Staged Windows project'

    $packageBuildDirectory = Join-Path $temporaryRoot 'AppPackages\'
    $restoreArguments = @(
        'restore',
        $buildProjectPath,
        '--runtime', 'win-x64',
        '--configfile', $buildNugetConfigPath,
        '--locked-mode',
        '-p:Platform=x64',
        '-p:SelfContained=true',
        '-p:PublishReadyToRun=true'
    )
    $publishArguments = @(
        'publish',
        $buildProjectPath,
        '--configuration', 'Release',
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--configfile', $buildNugetConfigPath,
        '--no-restore',
        '-p:Platform=x64',
        '-p:PublishReadyToRun=true',
        '-p:GenerateAppxPackageOnBuild=true',
        '-p:AppxPackageSigningEnabled=false',
        '-p:AppxBundle=Never',
        '-p:UapAppxPackageBuildMode=SideloadOnly',
        '-p:PublishTrimmed=false',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        "-p:AppxPackageDir=$packageBuildDirectory"
    )
    $portableBuildDirectory = Join-Path $temporaryRoot 'portable'
    $portableRestoreArguments = @(
        'restore',
        $buildProjectPath,
        '--configfile', $buildNugetConfigPath,
        '--locked-mode',
        '-p:Configuration=Release',
        '-p:PublishReadyToRun=false',
        '-p:PublishProfile=win-x64-portable.pubxml'
    )
    $portablePublishArguments = @(
        'publish',
        $buildProjectPath,
        '--configuration', 'Release',
        '--no-restore',
        '-p:PublishReadyToRun=false',
        '-p:PublishProfile=win-x64-portable.pubxml',
        '-o', $portableBuildDirectory
    )
    Push-Location $repositoryRoot
    try {
        & $dotnet @restoreArguments
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet restore --locked-mode failed with exit code $LASTEXITCODE."
        }
        & $dotnet @publishArguments
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish failed with exit code $LASTEXITCODE."
        }
        & $dotnet @portableRestoreArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Portable dotnet restore --locked-mode failed with exit code $LASTEXITCODE."
        }
        & $dotnet @portablePublishArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Portable dotnet publish failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    $portableFiles = @(Get-ChildItem -LiteralPath $portableBuildDirectory -File)
    $portableExecutable = Join-Path $portableBuildDirectory 'ReMarkableMirror.exe'
    if ($portableFiles.Count -ne 1 -or
        -not (Test-Path -LiteralPath $portableExecutable -PathType Leaf)) {
        throw 'Portable publish did not produce exactly one ReMarkableMirror.exe.'
    }
    Assert-PortableTabletPrerequisiteBundle `
        -PortableExecutable $portableExecutable `
        -ExtractionRoot (Join-Path $temporaryRoot 'portable-extract') `
        -ExpectedSources $tabletPrerequisiteSources

    $appPackages = @(
        Get-ChildItem -LiteralPath $packageBuildDirectory -Recurse -Filter '*.msix' -File |
            Where-Object { $_.FullName -notmatch '[\\/]Dependencies[\\/]' }
    )
    if ($appPackages.Count -ne 1) {
        throw "Expected exactly one application MSIX, found $($appPackages.Count)."
    }

    $runtimePackages = @(
        Get-ChildItem -LiteralPath $packageBuildDirectory -Recurse -Filter 'Microsoft.WindowsAppRuntime*.msix' -File |
            Where-Object { $_.FullName -match '[\\/]Dependencies[\\/]x64[\\/]' }
    )
    if ($runtimePackages.Count -ne 1) {
        throw "Expected exactly one x64 Windows App Runtime dependency, found $($runtimePackages.Count)."
    }

    New-Item -ItemType Directory -Path $releaseDirectory | Out-Null
    $dependencyDirectory = Join-Path $releaseDirectory 'Dependencies\x64'
    New-Item -ItemType Directory -Path $dependencyDirectory -Force | Out-Null

    $packagePath = Join-Path $releaseDirectory "$releaseName.msix"
    Copy-Item -LiteralPath $appPackages[0].FullName -Destination $packagePath
    Copy-Item -LiteralPath $runtimePackages[0].FullName -Destination $dependencyDirectory
    Copy-Item -LiteralPath $installerScriptPath -Destination $releaseDirectory
    Copy-Item -LiteralPath $installerLauncherPath -Destination (Join-Path $releaseDirectory 'Install.cmd')
    Copy-Item -LiteralPath $publicOnboardingGuidePath -Destination (Join-Path $releaseDirectory 'ONBOARDING.md')
    Copy-Item -LiteralPath $publicGettingStartedGuidePath -Destination (Join-Path $releaseDirectory 'GETTING_STARTED.md')
    Copy-Item -LiteralPath $publicTroubleshootingGuidePath -Destination (Join-Path $releaseDirectory 'TROUBLESHOOTING.md')
    Copy-Item -LiteralPath $publicPlatformSupportGuidePath -Destination (Join-Path $releaseDirectory 'PLATFORM_SUPPORT.md')
    Copy-Item -LiteralPath $publicTabletChangesGuidePath -Destination (Join-Path $releaseDirectory 'TABLET_CHANGES.md')
    Copy-Item -LiteralPath $publicUninstallGuidePath -Destination (Join-Path $releaseDirectory 'UNINSTALL.md')
    $releaseImagesDirectory = Join-Path $releaseDirectory 'images'
    New-Item -ItemType Directory -Path $releaseImagesDirectory | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $publicOnboardingImagesDirectory 'remarkable-mirror-live-wifi.png') `
        -Destination $releaseImagesDirectory
    Copy-Item `
        -LiteralPath (Join-Path $publicOnboardingImagesDirectory 'remarkable-mirror-preparing.png') `
        -Destination $releaseImagesDirectory
    Copy-Item -LiteralPath $projectLicensePath -Destination (Join-Path $releaseDirectory 'LICENSE')
    Copy-Item -LiteralPath $projectNoticePath -Destination (Join-Path $releaseDirectory 'NOTICE')
    Copy-Item -LiteralPath $projectThirdPartyNoticesPath -Destination (Join-Path $releaseDirectory 'THIRD_PARTY_NOTICES.md')

    $releaseNoticeDirectory = Join-Path $releaseDirectory 'ThirdParty\XOVI'
    $releaseMicrosoftNoticesDirectory = Join-Path $releaseDirectory 'ThirdParty\Microsoft'
    New-Item -ItemType Directory -Path $releaseNoticeDirectory, $releaseMicrosoftNoticesDirectory -Force | Out-Null
    Copy-Item -LiteralPath $xoviNoticePath -Destination $releaseNoticeDirectory
    Copy-Item -LiteralPath $xoviLicensePath -Destination $releaseNoticeDirectory
    Copy-Item -Path (Join-Path $microsoftNoticesDirectoryPath '*') `
        -Destination $releaseMicrosoftNoticesDirectory `
        -Recurse

    & $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint /s My $packagePath
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool failed to sign the MSIX with exit code $LASTEXITCODE."
    }

    $certificatePath = Join-Path $releaseDirectory 'ReMarkableMirror.cer'
    Export-Certificate -Cert $certificate -FilePath $certificatePath -Type CERT | Out-Null

    $signature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint -or
        $signature.Status -notin @(
            [System.Management.Automation.SignatureStatus]::Valid,
            [System.Management.Automation.SignatureStatus]::UnknownError
        )) {
        throw "The finished MSIX signature did not match the local signing certificate: $($signature.StatusMessage)"
    }

    $unpackDirectory = Join-Path $temporaryRoot 'unpacked'
    & $makeAppx unpack /p $packagePath /d $unpackDirectory /o | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx could not unpack the finished MSIX. Exit code: $LASTEXITCODE."
    }
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $unpackDirectory 'AppxManifest.xml') -Raw
    $manifestIdentity = $manifest.Package.Identity
    if ($manifestIdentity.Name -ne $identityName -or
        $manifestIdentity.Publisher -ne $publisher -or
        $manifestIdentity.Version -ne $Version -or
        $manifestIdentity.ProcessorArchitecture -ne 'x64') {
        throw "Finished MSIX identity does not match the requested name, publisher, version, and architecture."
    }
    Assert-TabletPrerequisiteBundle `
        -BundleDirectory (Join-Path $unpackDirectory 'TabletPrerequisites') `
        -ExpectedSources $tabletPrerequisiteSources `
        -ArtifactName 'Finished MSIX'
    Assert-AppOwnedPackageBinaryPrivacy `
        -UnpackDirectory $unpackDirectory `
        -SensitiveRoots @(
            $repositoryRoot,
            [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        )

    $requiredDotnetRuntimeFiles = @(
        'coreclr.dll',
        'hostfxr.dll',
        'hostpolicy.dll',
        'System.Private.CoreLib.dll'
    )
    foreach ($requiredDotnetRuntimeFile in $requiredDotnetRuntimeFiles) {
        $requiredDotnetRuntimePath = Join-Path $unpackDirectory $requiredDotnetRuntimeFile
        if (-not (Test-Path -LiteralPath $requiredDotnetRuntimePath -PathType Leaf)) {
            throw "Finished MSIX is missing its self-contained .NET runtime file: $requiredDotnetRuntimeFile"
        }
    }

    $runtimeConfigPath = Join-Path $unpackDirectory 'ReMarkableMirror.runtimeconfig.json'
    if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
        throw 'Finished MSIX is missing ReMarkableMirror.runtimeconfig.json.'
    }
    $runtimeConfig = [System.IO.File]::ReadAllText($runtimeConfigPath) | ConvertFrom-Json
    $includedFrameworksProperty = $runtimeConfig.runtimeOptions.PSObject.Properties['includedFrameworks']
    $externalFrameworkProperty = $runtimeConfig.runtimeOptions.PSObject.Properties['framework']
    $includedDotnetRuntime = @(
        if ($null -ne $includedFrameworksProperty) {
            $includedFrameworksProperty.Value |
                Where-Object { $_.name -ceq 'Microsoft.NETCore.App' }
        }
    )
    if ($includedDotnetRuntime.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$includedDotnetRuntime[0].version)) {
        throw 'Finished MSIX does not declare one included Microsoft.NETCore.App runtime.'
    }
    if ($null -ne $externalFrameworkProperty -and
        $externalFrameworkProperty.Value.name -ceq 'Microsoft.NETCore.App') {
        throw 'Finished MSIX still declares Microsoft.NETCore.App as an external framework.'
    }
    $embeddedDotnetRuntimeVersion = [string]$includedDotnetRuntime[0].version

    $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableHash = (Get-FileHash -LiteralPath $portableExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableLength = (Get-Item -LiteralPath $portableExecutable).Length
    $certificateHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimePackage = Get-ChildItem -LiteralPath $dependencyDirectory -Filter '*.msix' -File | Select-Object -First 1
    $runtimeHash = (Get-FileHash -LiteralPath $runtimePackage.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimeIdentity = Get-AppxArchiveIdentity -Path $runtimePackage.FullName
    $probeHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['rmmirror-probe'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $transportHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['rmmirror-transport-wake'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $transportSleepGuardHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['rmmirror-usb-sleep-guard.conf'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $filesLoopbackHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['rmmirror-files-loopback.so'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $prerequisiteInstallerHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['install-mirror-prerequisites.sh'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $prerequisiteContractHash = (Get-FileHash -LiteralPath $tabletPrerequisiteSources['rmmirror-prerequisites.env'] -Algorithm SHA256).Hash.ToLowerInvariant()
    $hostPrerequisiteAdapterHash = (Get-FileHash -LiteralPath $prerequisiteScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $captureHelperHash = (Get-FileHash -LiteralPath $captureHelperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimeComponentMetadata = @(
        foreach ($componentName in $tabletPrerequisiteComponentNames) {
            [ordered]@{
                file = "TabletPrerequisites/components/$componentName"
                sha256 = (Get-FileHash -LiteralPath $tabletPrerequisiteSources[$componentName] -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )

    $readme = @"
reMarkable Mirror $Version for 64-bit Windows

To install this release:
1. Extract this entire folder.
2. Double-click Install.cmd.
3. Open Mirror and choose Start Setup when you are ready to prepare the tablet.

The included installer reads the exact package identity, publisher, version and
SHA-256 from release.json before trusting the certificate or installing the
MSIX. release.json also records the exact Git commit and whether the source tree
was dirty. Official iFixRobots packages require clean source unless the builder
explicitly opts into a local development artifact marked source_dirty=true.

The installer requests one Windows administrator prompt to trust the included
local signing certificate, installs the Windows App Runtime, and installs
Mirror with its matching .NET runtime and tablet prerequisite payload built in.
It never contacts or changes the tablet. Tablet setup begins only after you open
Mirror and explicitly choose Start Setup.

Mirror then guides Developer Mode owners through authorizing this computer and
installing the package-matching tablet probe, pinned XOVI release, Files
loopback extension, and USB transport wake support. Enabling Developer Mode
factory-resets the tablet and removes its saved Wi-Fi networks and credentials;
read ONBOARDING.md before starting with a fresh tablet.

The Files view uses the tablet's stock web interface through the pinned SSH
connection. The loopback extension keeps that service off the Wi-Fi network.
XOVI is started only when Mirror connects and is not configured to start at
tablet boot.

Upstream XOVI notices, exact source links and GPL v3 terms are under
ThirdParty\XOVI.

Tablet setup and repair are always visible, owner-started actions inside Mirror.
"@
    Set-Content -LiteralPath (Join-Path $releaseDirectory 'README.txt') -Value $readme -Encoding UTF8

    $metadata = [ordered]@{
        schema = 'remarkable-mirror.release/v1'
        created_utc = [DateTime]::UtcNow.ToString('o')
        source_commit = $sourceCommit
        source_dirty = $sourceDirty
        build_environment = [ordered]@{
            dotnet_sdk = [ordered]@{
                version = $dotnetSdkVersion
            }
            dotnet_host_runtime = [ordered]@{
                version = $dotnetHostVersion
                architecture = $dotnetHostArchitecture
            }
            go_toolchain = $probeBuild.GoVersion
            files_toolchain = [ordered]@{
                image = $filesLoopbackBuild.ToolchainImage
                environment = $filesLoopbackBuild.ToolchainEnvironment
            }
        }
        package = [ordered]@{
            file = [System.IO.Path]::GetFileName($packagePath)
            identity = $identityName
            publisher = $publisher
            version = $Version
            architecture = 'x64'
            sha256 = $packageHash
            dotnet = [ordered]@{
                deployment = 'self-contained'
                runtime = 'Microsoft.NETCore.App'
                version = $embeddedDotnetRuntimeVersion
            }
        }
        portable = [ordered]@{
            file = [System.IO.Path]::GetFileName($portablePath)
            architecture = 'x64'
            sha256 = $portableHash
            bytes = $portableLength
            deployment = 'self-contained-single-file'
            tablet_prerequisites_embedded = $true
        }
        certificate = [ordered]@{
            file = [System.IO.Path]::GetFileName($certificatePath)
            thumbprint = $certificate.Thumbprint
            not_after = $certificate.NotAfter.ToUniversalTime().ToString('o')
            sha256 = $certificateHash
        }
        dependency = [ordered]@{
            file = "Dependencies/x64/$($runtimePackage.Name)"
            identity = $runtimeIdentity.Name
            publisher = $runtimeIdentity.Publisher
            version = $runtimeIdentity.Version
            architecture = $runtimeIdentity.Architecture
            sha256 = $runtimeHash
        }
        legal = [ordered]@{
            license = 'LICENSE'
            notice = 'NOTICE'
            third_party_notices = 'THIRD_PARTY_NOTICES.md'
            xovi_notice = 'ThirdParty/XOVI/NOTICE.txt'
            xovi_license = 'ThirdParty/XOVI/LICENSE-GPL-3.0.txt'
            microsoft_notices = 'ThirdParty/Microsoft/README.md'
        }
        tablet_prerequisites = [ordered]@{
            runtime_bundle = [ordered]@{
                root = 'TabletPrerequisites'
                adapter = [ordered]@{
                    file = 'TabletPrerequisites/Install-RemarkableMirrorPrerequisites.ps1'
                    sha256 = $hostPrerequisiteAdapterHash
                }
                capture_helper = [ordered]@{
                    file = 'TabletPrerequisites/lib/RemarkableRmctlCapture.ps1'
                    sha256 = $captureHelperHash
                }
                components = $runtimeComponentMetadata
            }
            transaction = [ordered]@{
                file = 'TabletPrerequisites/components/install-mirror-prerequisites.sh'
                sha256 = $prerequisiteInstallerHash
                contract = [ordered]@{
                    file = 'TabletPrerequisites/components/rmmirror-prerequisites.env'
                    schema = $prerequisiteContract['RMMIRROR_PREREQUISITES_SCHEMA']
                    tablet_model = $prerequisiteContract['RMMIRROR_TABLET_MODEL']
                    tablet_install_targets = @(
                        $prerequisiteContract['RMMIRROR_TABLET_INSTALL_TARGETS'] -split ','
                    )
                    sha256 = $prerequisiteContractHash
                }
            }
            installer_contacts_tablet = $false
            owner_started_in_app = $true
            installed_by_default = $false
            developer_mode_required = $true
            first_unlock_required = $true
            ssh_identity_and_host_trust_created_in_app = $true
            developer_mode_password_stored = $false
            probe = [ordered]@{
                file = 'TabletPrerequisites/components/rmmirror-probe'
                version = $mirrorProbeVersion
                sha256 = $probeHash
            }
            xovi = [ordered]@{
                file = 'TabletPrerequisites/components/xovi-aarch64.tar.gz'
                release = $xoviRelease
                release_commit = '7874154dba6793cc68a15fae0fb9dd272c4ed20a'
                sha256 = $xoviArchiveHash
                runtime_release = 'v0.3.3'
                runtime_commit = '0c8d5269b55c851901d4e4a754dc2d7deab40b17'
                runtime_sha256 = 'd4df820c25c634c511de11067279d8310fa4f656dc52bd4540db6beac4ffd446'
                required_extensions = @(
                    'framebuffer-spy',
                    'xovi-message-broker',
                    'rmmirror-files-loopback'
                )
                connection_time_activation = $true
                boot_start = $false
                notice = 'ThirdParty/XOVI/NOTICE.txt'
            }
            files_loopback = [ordered]@{
                file = 'TabletPrerequisites/components/rmmirror-files-loopback.so'
                version = '0.1.0'
                sha256 = $filesLoopbackHash
                toolchain_image = $filesLoopbackBuild.ToolchainImage
                xovi_generator_commit = $filesLoopbackBuild.XoviGeneratorCommit
                listener_scope = 'tablet-loopback-via-authenticated-ssh-forward'
            }
            transport_wake = [ordered]@{
                file = 'TabletPrerequisites/components/rmmirror-transport-wake'
                sha256 = $transportHash
                system_sleep_guard = [ordered]@{
                    file = 'TabletPrerequisites/components/rmmirror-usb-sleep-guard.conf'
                    sha256 = $transportSleepGuardHash
                    executor = 'systemd-suspend-then-hibernate.service'
                    condition = 'hold-while-live-usb-carrier'
                }
                install_scope = 'current-active-root-slot'
                enabled_at_boot = $true
            }
        }
        tablet_prerequisite_included = $true
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $releaseDirectory 'release.json') -Encoding UTF8

    Copy-Item -LiteralPath $portableExecutable -Destination $portablePath
    Compress-Archive -LiteralPath $releaseDirectory -DestinationPath $zipPath -CompressionLevel Optimal

    Write-Host "Package: $packagePath"
    Write-Host "Portable: $portablePath"
    Write-Host "Shareable ZIP: $zipPath"
    Write-Host "Version: $Version"
    Write-Host "SHA-256: $packageHash"
    Write-Host "Signing certificate: $($certificate.Thumbprint)"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected temporary path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
