#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildPath = Join-Path $repositoryRoot 'scripts\Build-RemarkableFilesLoopback.ps1'
$packagePath = Join-Path $repositoryRoot 'scripts\Build-RemarkableMirrorPackage.ps1'
$installerPath = Join-Path $repositoryRoot 'scripts\Install-RemarkableMirrorPrerequisites.ps1'
$artifactHelperPath = Join-Path $repositoryRoot 'scripts\lib\RemarkableFilesLoopbackArtifact.ps1'
$packageWorkflowPath = Join-Path $repositoryRoot '.github\workflows\package.yml'
$definitionPath = Join-Path $repositoryRoot 'mirror\agent\xovi\rmmirror-files-loopback\rmmirror-files-loopback.xovi'

$texts = @{}
foreach ($path in @($buildPath, $packagePath, $installerPath, $artifactHelperPath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -ne 0) {
        throw "PowerShell source did not parse: $path"
    }
    $texts[$path] = [System.IO.File]::ReadAllText($path)
}

$buildText = $texts[$buildPath]
foreach ($marker in @(
        "`$artifactHelperPath = Join-Path `$PSScriptRoot 'lib/RemarkableFilesLoopbackArtifact.ps1'",
        "`$sourceDirectory = Join-Path `$repositoryRoot 'mirror/agent/xovi/rmmirror-files-loopback'",
        'Get-Command docker -CommandType Application',
        'Get-Command git -CommandType Application',
        'Get-Command tar -CommandType Application',
        '[System.Runtime.InteropServices.OSPlatform]::Windows',
        '--network none',
        'TwoCleanBuildsHashIdentical = $true'
    )) {
    if (-not $buildText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Files loopback builder is missing marker: $marker"
    }
}

$artifactHelperText = $texts[$artifactHelperPath]
foreach ($marker in @(
        "BinaryName = 'rmmirror-files-loopback.so'",
        'eeems/remarkable-toolchain@sha256:893ad3bc55d0ef23603a2fcef05572694cadc8ce9410ada9c28e4879e859d9ce',
        '0c8d5269b55c851901d4e4a754dc2d7deab40b17',
        'function Get-VerifiedRemarkableFilesLoopbackArtifact',
        "`$expectedHash -cnotmatch '^[0-9a-f]{64}$'",
        '[BitConverter]::ToUInt16($bytes, 18) -ne 183'
    )) {
    if (-not $artifactHelperText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Files loopback artifact helper is missing marker: $marker"
    }
}

$packageText = $texts[$packagePath]
foreach ($marker in @(
        "`$filesLoopbackBuildScriptPath = Join-Path `$PSScriptRoot 'Build-RemarkableFilesLoopback.ps1'",
        '[string]$PrebuiltFilesLoopbackPath',
        '[string]$PrebuiltFilesLoopbackSha256',
        'PrebuiltFilesLoopbackPath and PrebuiltFilesLoopbackSha256 must be supplied together.',
        'Get-VerifiedRemarkableFilesLoopbackArtifact',
        "`$releaseFilesLoopbackPath = Join-Path `$releaseComponentDirectory 'rmmirror-files-loopback.so'",
        "file = 'components/rmmirror-files-loopback.so'",
        'sha256 = $filesLoopbackHash',
        'toolchain_image = $filesLoopbackBuild.ToolchainImage',
        'xovi_generator_commit = $filesLoopbackBuild.XoviGeneratorCommit'
    )) {
    if (-not $packageText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Mirror package builder is missing Files loopback marker: $marker"
    }
}

if (-not (Test-Path -LiteralPath $packageWorkflowPath -PathType Leaf)) {
    throw 'The GitHub Actions Windows installer workflow is missing.'
}
$packageWorkflowText = [System.IO.File]::ReadAllText($packageWorkflowPath)
foreach ($marker in @(
        'runs-on: ubuntu-24.04',
        'runs-on: windows-2025',
        './scripts/Build-RemarkableFilesLoopback.ps1 -Force',
        '-PrebuiltFilesLoopbackPath $prebuilt',
        '-PrebuiltFilesLoopbackSha256 $env:FILES_LOOPBACK_SHA256',
        'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1',
        'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1',
        '-p:Configuration=Release',
        '-p:PublishReadyToRun=false',
        '-p:PublishProfile=win-x64-portable.pubxml',
        'Portable EXE is unexpectedly large:',
        'Start-Process -FilePath $portableExe -PassThru -WindowStyle Hidden',
        "path: `${{ runner.temp }}/remarkable-mirror-package/ReMarkableMirror-*-x64.zip",
        'name: remarkable-mirror-portable-windows-x64',
        'name: remarkable-mirror-windows-installer'
    )) {
    if (-not $packageWorkflowText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "GitHub Actions package workflow is missing marker: $marker"
    }
}
$unpinnedAction = [regex]::Match(
    $packageWorkflowText,
    '(?m)^\s*uses:\s+actions/[a-z0-9-]+@(?![0-9a-f]{40}(?:\s|$))'
)
if ($unpinnedAction.Success) {
    throw "GitHub Actions package workflow contains an action that is not pinned by commit: $($unpinnedAction.Value.Trim())"
}
$requiredExtensions = [regex]::Match(
    $packageText,
    '(?s)required_extensions\s*=\s*@\((?<body>.*?)\)'
)
if (-not $requiredExtensions.Success) {
    throw 'Mirror package metadata is missing required_extensions.'
}
$requiredExtensionNames = @(
    [regex]::Matches($requiredExtensions.Groups['body'].Value, "'(?<name>[^']+)'") |
        ForEach-Object { $_.Groups['name'].Value }
)
$expectedExtensions = @(
    'framebuffer-spy',
    'xovi-message-broker',
    'rmmirror-files-loopback'
)
if (($requiredExtensionNames -join "`n") -cne ($expectedExtensions -join "`n")) {
    throw 'Mirror package metadata does not contain the exact three runtime extensions.'
}

$installerText = $texts[$installerPath]
foreach ($marker in @(
        "[string]`$FilesLoopbackExtension",
        "`$releaseFilesLoopback = Join-Path `$releaseComponentDirectory 'rmmirror-files-loopback.so'",
        "@{ Local = `$filesLoopbackFull; Remote = 'rmmirror-files-loopback.so' }",
        "[BitConverter]::ToUInt16(`$filesLoopbackBytes, 18) -ne 183",
        "publish_extension rmmirror-files-loopback.so",
        'for retired_extension in qt-resource-rebuilder.so webserver-remote.so; do',
        '/home/root/xovi/inactive-extensions/`$retired_extension',
        '/home/root/xovi/services/xochitl.service/qt-resource-rebuilder.conf'
    )) {
    if (-not $installerText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Prerequisite installer is missing Files loopback marker: $marker"
    }
}
$publishedExtensions = @(
    [regex]::Matches(
        $installerText,
        '(?m)^publish_extension (?<name>[a-z0-9-]+\.so)\r?$'
    ) |
        ForEach-Object { $_.Groups['name'].Value }
)
$expectedPublishedExtensions = @(
    'framebuffer-spy.so',
    'xovi-message-broker.so',
    'rmmirror-files-loopback.so'
)
if (($publishedExtensions -join "`n") -cne ($expectedPublishedExtensions -join "`n")) {
    throw 'Prerequisite installer does not publish the exact three runtime extensions.'
}
foreach ($forbiddenMarker in @(
        'publish_extension qt-resource-rebuilder.so',
        'publish_extension webserver-remote.so',
        'qt-resource-rebuilder.so.pinned',
        'qt-resource-rebuilder.conf.pinned'
    )) {
    if ($installerText.Contains($forbiddenMarker, [StringComparison]::Ordinal)) {
        throw "Prerequisite installer still publishes a retired extension: $forbiddenMarker"
    }
}

$definitionText = [System.IO.File]::ReadAllText($definitionPath)
if ($definitionText -cnotmatch '(?m)^version 0\.1\.0\r?$' -or
    $packageText -cnotmatch "version = '0\.1\.0'") {
    throw 'Files loopback source and package metadata versions do not match.'
}

. $artifactHelperPath
$testTemporaryParent = Join-Path $repositoryRoot 'tmp'
New-Item -ItemType Directory -Path $testTemporaryParent -Force | Out-Null
$testTemporaryRoot = Join-Path $testTemporaryParent ("files-loopback-artifact-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTemporaryRoot | Out-Null
try {
    $fixturePath = Join-Path $testTemporaryRoot 'rmmirror-files-loopback.so'
    $fixtureBytes = [byte[]]::new(64)
    $fixtureBytes[0] = 0x7f
    $fixtureBytes[1] = 0x45
    $fixtureBytes[2] = 0x4c
    $fixtureBytes[3] = 0x46
    $fixtureBytes[4] = 2
    $fixtureBytes[5] = 1
    [BitConverter]::GetBytes([uint16]3).CopyTo($fixtureBytes, 16)
    [BitConverter]::GetBytes([uint16]183).CopyTo($fixtureBytes, 18)
    [System.IO.File]::WriteAllBytes($fixturePath, $fixtureBytes)
    $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $verifiedFixture = Get-VerifiedRemarkableFilesLoopbackArtifact `
        -Path $fixturePath `
        -ExpectedSha256 $fixtureHash
    if ($verifiedFixture.Sha256 -cne $fixtureHash -or
        -not $verifiedFixture.Prebuilt -or
        $verifiedFixture.Format -cne 'ELF64 little-endian AArch64 shared object') {
        throw 'A valid pinned Files loopback fixture did not produce verified artifact metadata.'
    }

    $hashMismatchError = $null
    try {
        Get-VerifiedRemarkableFilesLoopbackArtifact `
            -Path $fixturePath `
            -ExpectedSha256 ('0' * 64) | Out-Null
    }
    catch {
        $hashMismatchError = $_.Exception.Message
    }
    if ($hashMismatchError -notmatch 'SHA-256 mismatch') {
        throw 'A Files loopback artifact with the wrong expected hash was not rejected.'
    }

    $fixtureBytes[18] = 0
    [System.IO.File]::WriteAllBytes($fixturePath, $fixtureBytes)
    $invalidElfHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $invalidElfError = $null
    try {
        Get-VerifiedRemarkableFilesLoopbackArtifact `
            -Path $fixturePath `
            -ExpectedSha256 $invalidElfHash | Out-Null
    }
    catch {
        $invalidElfError = $_.Exception.Message
    }
    if ($invalidElfError -notmatch 'not a 64-bit little-endian AArch64 shared object') {
        throw 'A hashed non-AArch64 Files loopback artifact was not rejected.'
    }
}
finally {
    if (Test-Path -LiteralPath $testTemporaryRoot) {
        Remove-Item -LiteralPath $testTemporaryRoot -Recurse -Force
    }
}

Write-Host 'PASS: Files loopback build, package, and installer integration are pinned and consistent.'
