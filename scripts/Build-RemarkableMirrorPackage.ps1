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
$xoviRelease = 'v19-23052026'
$xoviArchiveHashExpected = '32d64d1262ddc984e3235c7d0340a398fe6d5b3efa6a979865f5977b32630d27'

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
$mirrorProbeVersion = $probeVersionMatch.Groups['version'].Value

$prerequisiteSource = [System.IO.File]::ReadAllText($prerequisiteScriptPath)
$prerequisiteVersionMatch = [regex]::Match(
    $prerequisiteSource,
    '\$mirrorProbeVersion\s*=\s*''(?<version>[0-9]+\.[0-9]+\.[0-9]+)''')
if (-not $prerequisiteVersionMatch.Success) {
    throw 'Could not read the expected rmmirror-probe version from the prerequisite installer.'
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
    $prerequisiteVersionMatch.Groups['version'].Value,
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
    WindowsInstallerPostInstall = @{
        Text = $prerequisiteSource
        Pattern = 'grep -q ''"usb_connection_policy":"(?<policy>[^"]+)"'' /run/rmmirror-transport-wake\.json'
    }
    WindowsInstallerPairing = @{
        Text = $prerequisiteSource
        Pattern = '\$capabilityMetadata\[''USB_CONNECTION_POLICY''\]\s+-cne\s+''(?<policy>[^'']+)'''
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

$expectedDotnetSdkVersion = '10.0.302'
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
if (Test-Path -LiteralPath $releaseDirectory) {
    throw "Release directory already exists: $releaseDirectory"
}
if (Test-Path -LiteralPath $zipPath) {
    throw "Release archive already exists: $zipPath"
}

try {
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
    }
    finally {
        Pop-Location
    }

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
    Copy-Item -LiteralPath $prerequisiteScriptPath -Destination $releaseDirectory
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

    $releaseLibraryDirectory = Join-Path $releaseDirectory 'lib'
    $releaseComponentDirectory = Join-Path $releaseDirectory 'components'
    New-Item -ItemType Directory -Path $releaseLibraryDirectory, $releaseComponentDirectory -Force | Out-Null
    Copy-Item -LiteralPath $captureHelperPath -Destination $releaseLibraryDirectory
    Copy-Item -LiteralPath $transportUnitPath -Destination $releaseComponentDirectory
    Copy-Item -LiteralPath $transportInstallPath -Destination $releaseComponentDirectory
    Copy-Item -LiteralPath $transportSleepGuardPath -Destination $releaseComponentDirectory

    $probeBuildDirectory = Join-Path $temporaryRoot 'mirror-agent'
    $probeBuild = & $probeBuildScriptPath -OutputDirectory $probeBuildDirectory -Force
    if ($null -eq $probeBuild -or
        -not (Test-Path -LiteralPath $probeBuild.OutputPath -PathType Leaf)) {
        throw 'The mirror-agent build did not return a usable ARM64 binary.'
    }
    $releaseProbePath = Join-Path $releaseComponentDirectory 'rmmirror-probe'
    Copy-Item -LiteralPath $probeBuild.OutputPath -Destination $releaseProbePath

    $transportBuildDirectory = Join-Path $temporaryRoot 'transport-wake'
    $transportBuild = & $transportBuildScriptPath -OutputDirectory $transportBuildDirectory -Force
    if ($null -eq $transportBuild -or
        -not (Test-Path -LiteralPath $transportBuild.OutputPath -PathType Leaf)) {
        throw 'The transport-wake build did not return a usable ARM64 binary.'
    }
    if ($transportBuild.GoVersion -cne $probeBuild.GoVersion) {
        throw "ARM64 companion Go toolchain drift: probe used '$($probeBuild.GoVersion)'; transport wake used '$($transportBuild.GoVersion)'."
    }
    $releaseTransportPath = Join-Path $releaseComponentDirectory 'rmmirror-transport-wake'
    Copy-Item -LiteralPath $transportBuild.OutputPath -Destination $releaseTransportPath

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
    $releaseFilesLoopbackPath = Join-Path $releaseComponentDirectory 'rmmirror-files-loopback.so'
    Copy-Item -LiteralPath $filesLoopbackBuild.OutputPath -Destination $releaseFilesLoopbackPath

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
    $releaseXoviPath = Join-Path $releaseComponentDirectory 'xovi-aarch64.tar.gz'
    Copy-Item -LiteralPath $xoviArchivePath -Destination $releaseXoviPath

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
    $certificateHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimePackage = Get-ChildItem -LiteralPath $dependencyDirectory -Filter '*.msix' -File | Select-Object -First 1
    $runtimeHash = (Get-FileHash -LiteralPath $runtimePackage.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimeIdentity = Get-AppxArchiveIdentity -Path $runtimePackage.FullName
    $probeHash = (Get-FileHash -LiteralPath $releaseProbePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $transportHash = (Get-FileHash -LiteralPath $releaseTransportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $transportSleepGuardHash = (Get-FileHash -LiteralPath (Join-Path $releaseComponentDirectory 'rmmirror-usb-sleep-guard.conf') -Algorithm SHA256).Hash.ToLowerInvariant()
    $filesLoopbackHash = (Get-FileHash -LiteralPath $releaseFilesLoopbackPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $readme = @"
reMarkable Mirror $Version for 64-bit Windows

To install this release:
1. Extract this entire folder.
2. Connect the reMarkable tablet. If it just rebooted, complete its first unlock;
   an ordinary screen lock is supported.
3. Double-click Install.cmd.

The included installer reads the exact package identity, publisher, version and
SHA-256 from release.json before trusting the certificate or installing the
MSIX. release.json also records the exact Git commit and whether the source tree
was dirty. Official iFixRobots packages require clean source unless the builder
explicitly opts into a local development artifact marked source_dirty=true.

Default tablet setup requires PowerShell 7.5 or newer and these existing SSH
files under %USERPROFILE%\.ssh:
  remarkable_chiappa_ed25519
  remarkable_known_hosts

The installer requests one Windows administrator prompt to trust the included
local signing certificate, installs the Windows App Runtime and Mirror with its
matching .NET runtime built in, then installs the package-matching tablet probe,
pinned XOVI release and three required
extensions, plus USB transport wake support. XOVI is started only when Mirror
connects. It is never configured to start at tablet boot.

For another PC or tablet, Developer Mode, the first post-boot unlock, an
authorized SSH identity and host trust must already be set up. This installer
does not enable Developer Mode, bypass the tablet passcode, or create SSH trust.
Enabling Developer Mode performs a factory reset and removes saved Wi-Fi
networks and credentials. After the reset, reconnect the tablet to Wi-Fi from
the tablet UI and wait until it explicitly says Connected. Enter that password
only on the tablet. The Files view uses the tablet's stock web interface through the
pinned SSH connection; the package-matching loopback extension makes it
available for either USB or Wi-Fi without exposing it directly on the Wi-Fi
network. Read ONBOARDING.md
before setting up a fresh tablet.

Wi-Fi Files requires the package-matching tablet components.

Upstream XOVI notices, exact source links and GPL v3 terms are under
ThirdParty\XOVI.

For an app-only reinstall of an already matching release, run:
  powershell -ExecutionPolicy Bypass -File .\Install-RemarkableMirror.ps1 -SkipTabletSetup
App-only install does not update the tablet probe and cannot add Wi-Fi Files to
an older tablet setup.
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
            installer = 'Install-RemarkableMirrorPrerequisites.ps1'
            installed_by_default = $true
            developer_mode_required = $true
            first_unlock_required = $true
            ssh_identity_and_host_trust_required = $true
            probe = [ordered]@{
                file = 'components/rmmirror-probe'
                version = $mirrorProbeVersion
                sha256 = $probeHash
            }
            xovi = [ordered]@{
                file = 'components/xovi-aarch64.tar.gz'
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
                file = 'components/rmmirror-files-loopback.so'
                version = '0.1.0'
                sha256 = $filesLoopbackHash
                toolchain_image = $filesLoopbackBuild.ToolchainImage
                xovi_generator_commit = $filesLoopbackBuild.XoviGeneratorCommit
                listener_scope = 'tablet-loopback-via-authenticated-ssh-forward'
            }
            transport_wake = [ordered]@{
                file = 'components/rmmirror-transport-wake'
                sha256 = $transportHash
                system_sleep_guard = [ordered]@{
                    file = 'components/rmmirror-usb-sleep-guard.conf'
                    sha256 = $transportSleepGuardHash
                    executor = 'systemd-suspend-then-hibernate.service'
                    condition = 'hold-while-live-usb-carrier'
                }
                install_scope = 'current-active-root-slot'
                enabled_at_boot = $true
            }
        }
        tablet_prerequisite_included = $true
        full_fresh_tablet_onboarding = $false
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $releaseDirectory 'release.json') -Encoding UTF8

    Compress-Archive -LiteralPath $releaseDirectory -DestinationPath $zipPath -CompressionLevel Optimal

    Write-Host "Package: $packagePath"
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
