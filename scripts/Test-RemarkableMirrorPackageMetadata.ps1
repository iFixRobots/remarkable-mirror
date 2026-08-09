#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageBuilderPath = Join-Path $repositoryRoot 'scripts\Build-RemarkableMirrorPackage.ps1'
$packageInstallerPath = Join-Path $repositoryRoot 'scripts\Install-RemarkableMirror.ps1'
$releaseProvenancePath = Join-Path $repositoryRoot 'scripts\lib\RemarkableReleaseProvenance.ps1'
$captureHelperPath = Join-Path $repositoryRoot 'scripts\lib\RemarkableRmctlCapture.ps1'
$filesLoopbackBuilderPath = Join-Path $repositoryRoot 'scripts\Build-RemarkableFilesLoopback.ps1'
$filesLoopbackArtifactHelperPath = Join-Path $repositoryRoot 'scripts\lib\RemarkableFilesLoopbackArtifact.ps1'
$projectPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj'
$mainWindowPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\MainWindow.xaml.cs'
$appIconPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\Assets\AppIcon.ico'
$manifestPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\Package.appxmanifest'
$globalJsonPath = Join-Path $repositoryRoot 'global.json'
$goModPath = Join-Path $repositoryRoot 'mirror\agent\go.mod'
$packageOnboardingPath = Join-Path $repositoryRoot 'docs\PACKAGE_ONBOARDING.md'
$gettingStartedPath = Join-Path $repositoryRoot 'docs\GETTING_STARTED.md'

. $releaseProvenancePath

$globalJson = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json
if ($globalJson.sdk.version -cne '10.0.302' -or
    $globalJson.sdk.rollForward -cne 'disable' -or
    $globalJson.sdk.allowPrerelease -ne $false) {
    throw 'global.json must pin stable .NET SDK 10.0.302 without roll-forward.'
}
$goMod = [System.IO.File]::ReadAllText($goModPath)
if ($goMod -notmatch '(?m)^go 1\.26\.5\s*$' -or
    $goMod -match '(?m)^toolchain\s+') {
    throw 'mirror/agent/go.mod must require Go 1.26.5 without a redundant toolchain directive.'
}

[xml]$project = Get-Content -LiteralPath $projectPath -Raw
$releasePrivacyGroups = @(
    $project.Project.PropertyGroup |
        Where-Object {
            $debugTypeNode = $_.SelectSingleNode('DebugType')
            $debugSymbolsNode = $_.SelectSingleNode('DebugSymbols')
            $_.GetAttribute('Condition') -ceq "'`$(Configuration)' == 'Release'" -and
            $null -ne $debugTypeNode -and
            $debugTypeNode.InnerText -ceq 'None' -and
            $null -ne $debugSymbolsNode -and
            $debugSymbolsNode.InnerText -ceq 'false'
        }
)
$allDebugTypeGroups = @(
    $project.Project.PropertyGroup |
        Where-Object { $null -ne $_.SelectSingleNode('DebugType') }
)
if ($releasePrivacyGroups.Count -ne 1 -or $allDebugTypeGroups.Count -ne 1) {
    throw 'Release must disable CodeView/PDB output without changing Debug build symbols.'
}

$applicationIconNodes = @($project.SelectNodes('/Project/PropertyGroup/ApplicationIcon'))
if ($applicationIconNodes.Count -ne 1 -or
    $applicationIconNodes[0].InnerText -cne 'Assets\AppIcon.ico' -or
    -not (Test-Path -LiteralPath $appIconPath -PathType Leaf)) {
    throw 'The Windows executable must embed the packaged AppIcon.ico resource.'
}
$appIconContentNodes = @(
    $project.SelectNodes('/Project/ItemGroup/Content[@Include="Assets\AppIcon.ico"]')
)
$appIconContentConditions = @(
    $appIconContentNodes |
        ForEach-Object { $_.ParentNode.GetAttribute('Condition') }
)
if ($appIconContentNodes.Count -ne 2 -or
    $appIconContentConditions -cnotcontains
        "'`$(PortablePublishProfileSelected)' == 'true'" -or
    $appIconContentConditions -cnotcontains
        "'`$(PortablePublishProfileSelected)' != 'true'") {
    throw 'Both portable and packaged builds must bundle Assets\AppIcon.ico.'
}
$mainWindowSource = [System.IO.File]::ReadAllText($mainWindowPath)
$absoluteWindowIconCall =
    'AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));'
if (-not $mainWindowSource.Contains(
        $absoluteWindowIconCall,
        [StringComparison]::Ordinal) -or
    $mainWindowSource.Contains(
        'AppWindow.SetIcon("Assets/AppIcon.ico");',
        [StringComparison]::Ordinal)) {
    throw 'The live Windows taskbar icon must use the bundled AppIcon.ico by absolute path.'
}

if (-not (Test-Path -LiteralPath $packageOnboardingPath -PathType Leaf)) {
    throw 'The self-contained package onboarding guide is missing.'
}
if (-not (Test-Path -LiteralPath $gettingStartedPath -PathType Leaf)) {
    throw 'The complete Getting started guide is missing.'
}
$packageOnboardingText = [System.IO.File]::ReadAllText($packageOnboardingPath)
foreach ($requiredMarker in @(
        'You already have a reMarkable Mirror installer package.',
        'Developer Mode, which factory-resets the',
        '`3.28.0.164`, OS build `5.8.199`',
        'Windows has',
        'the complete installer and setup path.',
        'native macOS app is currently an',
        'unsigned development build',
        '[GETTING_STARTED.md](GETTING_STARTED.md)',
        '%USERPROFILE%\.ssh\remarkable_chiappa_ed25519',
        '%USERPROFILE%\.ssh\remarkable_known_hosts',
        'grep -qxF "$key" /home/root/.ssh/authorized_keys ||',
        '[Troubleshooting guide](TROUBLESHOOTING.md)',
        'double-click `Install.cmd`.',
        'Launch waits without contacting the tablet.',
        '**Connect USB-C**',
        'It never switches or reconnects by',
        'Live over USB',
        'Only then does the IP address field appear.',
        'Live over Wi-Fi',
        'There is no complete tested one-click stock-restoration workflow yet.'
    )) {
    if (-not $packageOnboardingText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Package onboarding is missing a first-run marker: $requiredMarker"
    }
}

$gettingStartedText = [System.IO.File]::ReadAllText($gettingStartedPath)
foreach ($requiredMarker in @(
        'This is the complete first-time path for a reMarkable Paper Pro Move',
        'Enabling reMarkable Developer Mode factory-resets the tablet',
        'has not yet completed an independent',
        'clean-Windows/fresh-reset acceptance run',
        'The Windows app has the complete installer and setup path.',
        'macOS app is currently an unsigned development build',
        'ARM64 Linux components run on the',
        'remarkable_chiappa_ed25519',
        'remarkable_known_hosts',
        'StrictHostKeyChecking=yes',
        'grep -qxF "$key" /home/root/.ssh/authorized_keys ||',
        'remarkable-mirror-windows-installer',
        'The portable `ReMarkableMirror.exe` is not a first-time installer.',
        'double-click `Install.cmd`.',
        'Launching Mirror waits for you and does not contact the tablet.',
        '**Connect USB-C**',
        'Live over USB',
        'click **Live over USB**',
        'Live over Wi-Fi',
        'Click **Live over Wi-Fi**',
        '[What Mirror changes](TABLET_CHANGES.md)',
        '[Platform support](PLATFORM_SUPPORT.md)',
        'Automatic root-slot repair is not implemented.'
    )) {
    if (-not $gettingStartedText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Getting started is missing a durable first-run marker: $requiredMarker"
    }
}

foreach ($staleAutomaticMarker in @(
        'retries automatically',
        'reconnects automatically',
        'wait for the app to reconnect'
    )) {
    if ($packageOnboardingText.Contains(
            $staleAutomaticMarker,
            [StringComparison]::OrdinalIgnoreCase) -or
        $gettingStartedText.Contains(
            $staleAutomaticMarker,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Bundled onboarding still promises automatic connection behavior: $staleAutomaticMarker"
    }
}

$publicNarrativeFiles = @(
    'README.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'SUPPORT.md',
    'docs\ARCHITECTURE.md',
    'docs\DEVELOPMENT.md',
    'docs\DEVICE_SETUP.md',
    'docs\GETTING_STARTED.md',
    'docs\PACKAGE_ONBOARDING.md',
    'docs\PLATFORM_SUPPORT.md',
    'docs\PRIVACY.md',
    'docs\RELEASING.md',
    'docs\TABLET_CHANGES.md',
    'docs\TROUBLESHOOTING.md',
    'docs\UNINSTALL.md',
    'docs\macos\GETTING_STARTED.md',
    'docs\macos\PACKAGING.md',
    'docs\macos\PORT_STATUS.md',
    'docs\macos\TROUBLESHOOTING.md',
    'mirror\agent\INPUT_PROTOCOL.md',
    'mirror\agent\deploy\README.md'
)
foreach ($relativeNarrativePath in $publicNarrativeFiles) {
    $narrativePath = Join-Path $repositoryRoot $relativeNarrativePath
    if (-not (Test-Path -LiteralPath $narrativePath -PathType Leaf)) {
        throw "A public product document is missing: $relativeNarrativePath"
    }
    $narrativeText = [System.IO.File]::ReadAllText($narrativePath)
    foreach ($internalLedgerMarker in @(
            'installed local candidate',
            'private candidate',
            'Gold remains',
            'installed Gold',
            'technical proof',
            'technical validation',
            'accepted baseline',
            '16.3 seconds',
            '12m02.7s',
            '1.2608.',
            'trusted network',
            'private network you control'
        )) {
        if ($narrativeText.Contains($internalLedgerMarker, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$relativeNarrativePath contains private validation history or deprecated network wording: $internalLedgerMarker"
        }
    }
}

$tokens = $null
$parseErrors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $packageBuilderPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Package builder did not parse: $($parseErrors[0].Message)"
}

$parameterNames = @(
    $builderAst.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath }
)
foreach ($requiredParameter in @(
        'Publisher',
        'PackageIdentity',
        'PublisherDisplayName',
        'PrebuiltFilesLoopbackPath',
        'PrebuiltFilesLoopbackSha256',
        'AllowDirtyOfficialDevelopmentBuild'
    )) {
    if ($requiredParameter -cnotin $parameterNames) {
        throw "Package builder is missing parameter: $requiredParameter"
    }
}

$builderText = [System.IO.File]::ReadAllText($packageBuilderPath)
foreach ($requiredMarker in @(
        "[string]`$Publisher = 'CN=iFixRobots'",
        "[Guid]`$PackageIdentity = [Guid]'A184FD6B-E071-4B75-A3B4-DF4397457284'",
        "`$releaseProvenancePath = Join-Path `$PSScriptRoot 'lib\RemarkableReleaseProvenance.ps1'",
        "`$filesLoopbackArtifactHelperPath = Join-Path `$PSScriptRoot 'lib\RemarkableFilesLoopbackArtifact.ps1'",
        'Get-RemarkableReleaseProvenance',
        'PrebuiltFilesLoopbackPath and PrebuiltFilesLoopbackSha256 must be supplied together.',
        'Get-VerifiedRemarkableFilesLoopbackArtifact',
        "`$expectedDotnetSdkVersion = '10.0.302'",
        "'-p:SelfContained=true'",
        "'--self-contained', 'true'",
        "'-p:PublishReadyToRun=true'",
        "`$publicOnboardingGuidePath = Join-Path `$repositoryRoot 'docs\PACKAGE_ONBOARDING.md'",
        "`$publicGettingStartedGuidePath = Join-Path `$repositoryRoot 'docs\GETTING_STARTED.md'",
        "`$publicTroubleshootingGuidePath = Join-Path `$repositoryRoot 'docs\TROUBLESHOOTING.md'",
        "`$publicPlatformSupportGuidePath = Join-Path `$repositoryRoot 'docs\PLATFORM_SUPPORT.md'",
        "`$publicTabletChangesGuidePath = Join-Path `$repositoryRoot 'docs\TABLET_CHANGES.md'",
        "`$publicUninstallGuidePath = Join-Path `$repositoryRoot 'docs\UNINSTALL.md'",
        "`$publicOnboardingImagesDirectory = Join-Path `$repositoryRoot 'docs\images'",
        "'--locked-mode'",
        "'--no-restore'",
        "'-p:DebugType=None'",
        "'-p:DebugSymbols=false'",
        'function Assert-AppOwnedPackageBinaryPrivacy',
        'ReadCodeViewDebugDirectoryData',
        'Finished MSIX contains a rooted application CodeView PDB path',
        "[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)",
        "Finished MSIX embeds the package build's repository or user-profile path",
        "`$buildManifest.Package.Identity.Name = `$identityName",
        "`$buildManifest.Package.Identity.Publisher = `$publisher",
        "`$buildManifest.Package.PhoneIdentity.PhoneProductId = `$identityName",
        "`$buildManifest.Package.Properties.PublisherDisplayName = `$PublisherDisplayName",
        'Copy-Item -LiteralPath $installerScriptPath -Destination $releaseDirectory',
        "Copy-Item -LiteralPath `$publicOnboardingGuidePath -Destination (Join-Path `$releaseDirectory 'ONBOARDING.md')",
        "Copy-Item -LiteralPath `$publicGettingStartedGuidePath -Destination (Join-Path `$releaseDirectory 'GETTING_STARTED.md')",
        "Copy-Item -LiteralPath `$publicTroubleshootingGuidePath -Destination (Join-Path `$releaseDirectory 'TROUBLESHOOTING.md')",
        "Copy-Item -LiteralPath `$publicPlatformSupportGuidePath -Destination (Join-Path `$releaseDirectory 'PLATFORM_SUPPORT.md')",
        "Copy-Item -LiteralPath `$publicTabletChangesGuidePath -Destination (Join-Path `$releaseDirectory 'TABLET_CHANGES.md')",
        "Copy-Item -LiteralPath `$publicUninstallGuidePath -Destination (Join-Path `$releaseDirectory 'UNINSTALL.md')",
        "`$releaseImagesDirectory = Join-Path `$releaseDirectory 'images'",
        "-LiteralPath (Join-Path `$publicOnboardingImagesDirectory 'remarkable-mirror-live-wifi.png')",
        "-LiteralPath (Join-Path `$publicOnboardingImagesDirectory 'remarkable-mirror-preparing.png')",
        "Copy-Item -LiteralPath `$projectLicensePath -Destination (Join-Path `$releaseDirectory 'LICENSE')",
        "Copy-Item -LiteralPath `$projectNoticePath -Destination (Join-Path `$releaseDirectory 'NOTICE')",
        "Copy-Item -LiteralPath `$projectThirdPartyNoticesPath -Destination (Join-Path `$releaseDirectory 'THIRD_PARTY_NOTICES.md')",
        'Copy-Item -LiteralPath $captureHelperPath -Destination $releaseLibraryDirectory',
        "`$buildLegalDirectory = Join-Path `$buildProjectDirectory 'Legal'",
        "`$buildMicrosoftNoticesDirectory = Join-Path `$buildProjectDirectory 'ThirdParty\Microsoft'",
        "`$releaseMicrosoftNoticesDirectory = Join-Path `$releaseDirectory 'ThirdParty\Microsoft'",
        "Copy-Item -Path (Join-Path `$microsoftNoticesDirectoryPath '*')",
        '-Destination $releaseMicrosoftNoticesDirectory',
        'source_commit = $sourceCommit',
        'source_dirty = $sourceDirty',
        'build_environment = [ordered]@{',
        'dotnet_host_runtime = [ordered]@{',
        "deployment = 'self-contained'",
        "runtime = 'Microsoft.NETCore.App'",
        'version = $embeddedDotnetRuntimeVersion',
        'go_toolchain = $probeBuild.GoVersion',
        'environment = $filesLoopbackBuild.ToolchainEnvironment',
        'version = $runtimeIdentity.Version',
        "legal = [ordered]@{",
        "microsoft_notices = 'ThirdParty/Microsoft/README.md'",
        'The included installer reads the exact package identity, publisher, version and',
        'explicitly opts into a local development artifact marked source_dirty=true.',
        'After the reset, reconnect the tablet to Wi-Fi from'
    )) {
    if (-not $builderText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Package builder is missing source metadata/identity marker: $requiredMarker"
    }
}
if ($builderText.Contains('$workspaceOnboardingGuidePath', [StringComparison]::Ordinal) -or
    $builderText.Contains('$onboardingGuidePath', [StringComparison]::Ordinal)) {
    throw 'Package builder must not fall back from the complete public onboarding guide.'
}

$captureHelperText = [System.IO.File]::ReadAllText($captureHelperPath)
foreach ($requiredMarker in @(
        '[Console]::In.ReadToEnd()',
        '$startInfo.RedirectStandardInput = $true',
        '$process.StandardInput.Write($payloadBase64)',
        '$process.StandardInput.Close()'
    )) {
    if (-not $captureHelperText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Process capture helper is missing bounded launcher-payload transport: $requiredMarker"
    }
}
if ($captureHelperText.Contains(
        "FromBase64String('`$payloadBase64')",
        [StringComparison]::Ordinal)) {
    throw 'Process capture helper must not interpolate launcher payload into the outer encoded command.'
}

$readyToRunPropertyCount = [regex]::Matches(
    $builderText,
    [regex]::Escape("'-p:PublishReadyToRun=true'")
).Count
if ($readyToRunPropertyCount -ne 2) {
    throw 'Package restore and publish must both set PublishReadyToRun=true.'
}

if ($builderText.Contains('trusted network', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package builder must use plain Wi-Fi wording instead of trusted-network language.'
}

$releaseProvenanceText = [System.IO.File]::ReadAllText($releaseProvenancePath)
foreach ($requiredMarker in @(
        '-AllowDirtyOfficialDevelopmentBuild only for a local development artifact.',
        'Packaging source has no committed HEAD.',
        'SourceCommit = $sourceCommit',
        'SourceDirty = $sourceDirty'
    )) {
    if (-not $releaseProvenanceText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Release provenance helper is missing required behavior: $requiredMarker"
    }
}

$filesLoopbackBuilderText = [System.IO.File]::ReadAllText($filesLoopbackBuilderPath)
if (-not $filesLoopbackBuilderText.Contains(
        'ToolchainEnvironment = $toolchainEnvironment',
        [StringComparison]::Ordinal)) {
    throw 'Files loopback build result does not report its exact toolchain environment.'
}

$artifactHelperTokens = $null
$artifactHelperParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $filesLoopbackArtifactHelperPath,
    [ref]$artifactHelperTokens,
    [ref]$artifactHelperParseErrors
)
if ($artifactHelperParseErrors.Count -ne 0) {
    throw "Files loopback artifact helper did not parse: $($artifactHelperParseErrors[0].Message)"
}
$filesLoopbackArtifactHelperText = [System.IO.File]::ReadAllText($filesLoopbackArtifactHelperPath)
foreach ($requiredMarker in @(
        'function Get-RemarkableFilesLoopbackBuildConfiguration',
        'function Get-VerifiedRemarkableFilesLoopbackArtifact',
        'Prebuilt Files loopback SHA-256 mismatch:',
        'Prebuilt Files loopback artifact is not a 64-bit little-endian AArch64 shared object.'
    )) {
    if (-not $filesLoopbackArtifactHelperText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Files loopback artifact helper is missing required validation: $requiredMarker"
    }
}

$installerTokens = $null
$installerParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $packageInstallerPath,
    [ref]$installerTokens,
    [ref]$installerParseErrors
)
if ($installerParseErrors.Count -ne 0) {
    throw "Package installer did not parse: $($installerParseErrors[0].Message)"
}

$installerText = [System.IO.File]::ReadAllText($packageInstallerPath)
foreach ($requiredMarker in @(
        "`$releaseMetadataPath = Join-Path `$PSScriptRoot 'release.json'",
        "if (`$releaseSchema -cne 'remarkable-mirror.release/v1')",
        "-Name 'identity'",
        "-Name 'publisher'",
        "-Name 'version'",
        "-Name 'sha256'",
        'does not match the SHA-256 recorded in release.json.',
        '[StringComparer]::OrdinalIgnoreCase.Equals($installed.Name, $identityName)',
        '$installed.Publisher -ne $expectedPublisher',
        '[string]$installed.Version -cne $expectedVersion'
    )) {
    if (-not $installerText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "Package installer is missing release-metadata validation marker: $requiredMarker"
    }
}

foreach ($forbiddenMarker in @(
        'ConvertTo-PowerShellSingleQuotedLiteral',
        'release installer package identity markers changed unexpectedly'
    )) {
    if ($builderText.Contains($forbiddenMarker, [StringComparison]::Ordinal)) {
        throw "Package builder still rewrites installer source: $forbiddenMarker"
    }
}

$testTemporaryParent = Join-Path $repositoryRoot 'tmp'
New-Item -ItemType Directory -Path $testTemporaryParent -Force | Out-Null
$testTemporaryPrefix = [System.IO.Path]::GetFullPath($testTemporaryParent).TrimEnd('\') + '\'
$testTemporaryRoot = [System.IO.Path]::GetFullPath((Join-Path `
            $testTemporaryParent `
            ("package-metadata-test-{0}" -f [Guid]::NewGuid().ToString('N'))))
if (-not $testTemporaryRoot.StartsWith(
        $testTemporaryPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary test path escaped the repository tmp directory: $testTemporaryRoot"
}

New-Item -ItemType Directory -Path $testTemporaryRoot | Out-Null
try {
    $stagedInstallerPath = Join-Path $testTemporaryRoot 'Install-RemarkableMirror.ps1'
    Copy-Item -LiteralPath $packageInstallerPath -Destination $stagedInstallerPath

    $stagedPackageName = 'ReMarkableMirror-9.8.7.6-x64.msix'
    $stagedPackagePath = Join-Path $testTemporaryRoot $stagedPackageName
    [System.IO.File]::WriteAllBytes(
        $stagedPackagePath,
        [byte[]](0x52, 0x4D, 0x4D, 0x49, 0x52, 0x52, 0x4F, 0x52))
    $stagedPackageHash = (Get-FileHash -LiteralPath $stagedPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $customReleaseMetadata = [ordered]@{
        schema = 'remarkable-mirror.release/v1'
        package = [ordered]@{
            file = $stagedPackageName
            identity = '10000000-0000-4000-8000-000000000001'
            publisher = 'CN=Third Party Development'
            version = '9.8.7.6'
            architecture = 'x64'
            sha256 = $stagedPackageHash
        }
    }
    $customReleaseMetadata |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (Join-Path $testTemporaryRoot 'release.json') -Encoding UTF8

    $installerEngines = @('pwsh.exe')
    if ($null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $installerEngines += 'powershell.exe'
    }
    foreach ($installerEngine in $installerEngines) {
        $customMetadataRun = & $installerEngine `
            -NoLogo `
            -NoProfile `
            -File $stagedInstallerPath `
            -SkipTabletSetup `
            -NoLaunch 2>&1
        if ($LASTEXITCODE -eq 0 -or
            ($customMetadataRun -join "`n") -notmatch 'The package certificate is missing:') {
            throw "A valid custom release identity did not pass metadata and package-hash validation under $installerEngine."
        }
    }

    [System.IO.File]::WriteAllBytes(
        $stagedPackagePath,
        [byte[]](0x54, 0x41, 0x4D, 0x50, 0x45, 0x52, 0x45, 0x44))
    foreach ($installerEngine in $installerEngines) {
        $tamperedPackageRun = & $installerEngine `
            -NoLogo `
            -NoProfile `
            -File $stagedInstallerPath `
            -SkipTabletSetup `
            -NoLaunch 2>&1
        if ($LASTEXITCODE -eq 0 -or
            ($tamperedPackageRun -join "`n") -notmatch 'does not match the SHA-256 recorded in release.json') {
            throw "The metadata-driven installer accepted a package whose SHA-256 no longer matched under $installerEngine."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $testTemporaryRoot) {
        $resolvedTestTemporaryRoot = [System.IO.Path]::GetFullPath($testTemporaryRoot)
        if (-not $resolvedTestTemporaryRoot.StartsWith(
                $testTemporaryPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected test path: $resolvedTestTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTestTemporaryRoot -Recurse -Force
    }
}

[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
if ($manifest.Package.Identity.Name -cne 'A184FD6B-E071-4B75-A3B4-DF4397457284' -or
    $manifest.Package.Identity.Publisher -cne 'CN=iFixRobots' -or
    $manifest.Package.PhoneIdentity.PhoneProductId -cne 'A184FD6B-E071-4B75-A3B4-DF4397457284' -or
    $manifest.Package.Properties.PublisherDisplayName -cne 'iFixRobots') {
    throw 'Package manifest no longer preserves the official default identity.'
}

$git = (Get-Command git.exe -ErrorAction Stop).Source
$provenanceFixtureRoot = [System.IO.Path]::GetFullPath((Join-Path `
            $testTemporaryParent `
            ("release-provenance-test-{0}" -f [Guid]::NewGuid().ToString('N'))))
if (-not $provenanceFixtureRoot.StartsWith(
        $testTemporaryPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary provenance fixture escaped the repository tmp directory: $provenanceFixtureRoot"
}

New-Item -ItemType Directory -Path $provenanceFixtureRoot | Out-Null
try {
    $committedFixtureRoot = Join-Path $provenanceFixtureRoot 'committed'
    New-Item -ItemType Directory -Path $committedFixtureRoot | Out-Null
    & $git -C $committedFixtureRoot init --quiet --initial-branch=main
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the committed provenance fixture.' }
    & $git -C $committedFixtureRoot config user.name 'Release Fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the provenance fixture name.' }
    & $git -C $committedFixtureRoot config user.email 'release-fixture@example.invalid'
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the provenance fixture email.' }
    [System.IO.File]::WriteAllText((Join-Path $committedFixtureRoot 'source.txt'), 'committed source')
    & $git -C $committedFixtureRoot add -- source.txt
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the provenance fixture source.' }
    & $git -C $committedFixtureRoot -c commit.gpgsign=false commit --quiet -m 'Create release fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the provenance fixture source.' }

    $expectedCommit = ((& $git -C $committedFixtureRoot rev-parse --verify HEAD) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the provenance fixture commit.' }
    $cleanProvenance = Get-RemarkableReleaseProvenance `
        -RepositoryRoot $committedFixtureRoot `
        -Publisher 'CN=iFixRobots'
    if ($cleanProvenance.SourceCommit -cne $expectedCommit -or $cleanProvenance.SourceDirty) {
        throw 'A clean committed source fixture did not produce exact clean provenance.'
    }

    [System.IO.File]::WriteAllText((Join-Path $committedFixtureRoot 'dirty.txt'), 'uncommitted source')
    $dirtyGateError = $null
    try {
        Get-RemarkableReleaseProvenance `
            -RepositoryRoot $committedFixtureRoot `
            -Publisher 'CN=iFixRobots' | Out-Null
    }
    catch {
        $dirtyGateError = $_.Exception.Message
    }
    if ($dirtyGateError -notmatch 'Official iFixRobots packages require a clean Git working tree') {
        throw 'A dirty official source fixture did not stop at the clean-source gate.'
    }

    $overrideProvenance = Get-RemarkableReleaseProvenance `
        -RepositoryRoot $committedFixtureRoot `
        -Publisher 'CN=iFixRobots' `
        -AllowDirtyOfficialDevelopmentBuild
    if (-not $overrideProvenance.SourceDirty -or
        $overrideProvenance.SourceCommit -cne $expectedCommit) {
        throw 'The explicit dirty official development override did not retain exact dirty provenance.'
    }

    $developmentProvenance = Get-RemarkableReleaseProvenance `
        -RepositoryRoot $committedFixtureRoot `
        -Publisher 'CN=Third Party Development'
    if (-not $developmentProvenance.SourceDirty -or
        $developmentProvenance.SourceCommit -cne $expectedCommit) {
        throw 'A custom development identity did not retain exact dirty provenance.'
    }

    $unbornFixtureRoot = Join-Path $provenanceFixtureRoot 'unborn'
    New-Item -ItemType Directory -Path $unbornFixtureRoot | Out-Null
    & $git -C $unbornFixtureRoot init --quiet --initial-branch=main
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the unborn provenance fixture.' }
    $unbornError = $null
    try {
        Get-RemarkableReleaseProvenance `
            -RepositoryRoot $unbornFixtureRoot `
            -Publisher 'CN=Third Party Development' | Out-Null
    }
    catch {
        $unbornError = $_.Exception.Message
    }
    if ($unbornError -notmatch 'has no committed HEAD') {
        throw 'An unborn Git repository did not report its missing committed HEAD honestly.'
    }
}
finally {
    if (Test-Path -LiteralPath $provenanceFixtureRoot) {
        $resolvedProvenanceFixtureRoot = [System.IO.Path]::GetFullPath($provenanceFixtureRoot)
        if (-not $resolvedProvenanceFixtureRoot.StartsWith(
                $testTemporaryPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected provenance fixture path: $resolvedProvenanceFixtureRoot"
        }
        Remove-Item -LiteralPath $resolvedProvenanceFixtureRoot -Recurse -Force
    }
}

Write-Host 'PASS: package source metadata, Release binary privacy, official dirty gate, and metadata-driven development identities are consistent.'
