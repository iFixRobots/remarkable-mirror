#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildPath = Join-Path $repositoryRoot 'scripts\Build-RemarkableFilesLoopback.ps1'
$packagePath = Join-Path $repositoryRoot 'scripts\Build-RemarkableMirrorPackage.ps1'
$installerPath = Join-Path $repositoryRoot 'scripts\Install-RemarkableMirrorPrerequisites.ps1'
$definitionPath = Join-Path $repositoryRoot 'mirror\agent\xovi\rmmirror-files-loopback\rmmirror-files-loopback.xovi'

$texts = @{}
foreach ($path in @($buildPath, $packagePath, $installerPath)) {
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
        'eeems/remarkable-toolchain@sha256:893ad3bc55d0ef23603a2fcef05572694cadc8ce9410ada9c28e4879e859d9ce',
        '0c8d5269b55c851901d4e4a754dc2d7deab40b17',
        'mirror\agent\xovi\rmmirror-files-loopback',
        "`$binaryName = 'rmmirror-files-loopback.so'",
        '--network none',
        'TwoCleanBuildsHashIdentical = $true'
    )) {
    if (-not $buildText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Files loopback builder is missing marker: $marker"
    }
}

$packageText = $texts[$packagePath]
foreach ($marker in @(
        "`$filesLoopbackBuildScriptPath = Join-Path `$PSScriptRoot 'Build-RemarkableFilesLoopback.ps1'",
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
        '(?m)^publish_extension (?<name>[a-z0-9-]+\.so)$'
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
if ($definitionText -cnotmatch '(?m)^version 0\.1\.0$' -or
    $packageText -cnotmatch "version = '0\.1\.0'") {
    throw 'Files loopback source and package metadata versions do not match.'
}

Write-Host 'PASS: Files loopback build, package, and installer integration are pinned and consistent.'
