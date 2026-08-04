[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\tmp\mirror\files-loopback'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceDirectory = Join-Path $repositoryRoot 'mirror\agent\xovi\rmmirror-files-loopback'
$allowedOutputRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'tmp'))
$toolchainImage = 'eeems/remarkable-toolchain@sha256:893ad3bc55d0ef23603a2fcef05572694cadc8ce9410ada9c28e4879e859d9ce'
$toolchainEnvironment = '/opt/codex/ferrari/5.7.119/environment-setup-cortexa53-crypto-remarkable-linux'
$xoviRepository = 'https://github.com/asivery/xovi.git'
$xoviGeneratorCommit = '0c8d5269b55c851901d4e4a754dc2d7deab40b17'
$binaryName = 'rmmirror-files-loopback.so'

foreach ($sourceName in @(
        'main.cpp',
        'Makefile',
        'rmmirror-files-loopback.xovi'
    )) {
    $sourcePath = Join-Path $sourceDirectory $sourceName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required Files loopback source does not exist: $sourcePath"
    }
}

$outputCandidate = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory
}
else {
    Join-Path $repositoryRoot $OutputDirectory
}
$outputDirectoryFull = [System.IO.Path]::GetFullPath($outputCandidate)
$allowedOutputPrefix = $allowedOutputRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if ($outputDirectoryFull -ne $allowedOutputRoot -and
    -not $outputDirectoryFull.StartsWith(
        $allowedOutputPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "OutputDirectory must remain under $allowedOutputRoot"
}

$docker = (Get-Command docker.exe -ErrorAction Stop).Source
$git = (Get-Command git.exe -ErrorAction Stop).Source

& $docker image inspect $toolchainImage *> $null
if ($LASTEXITCODE -ne 0) {
    & $docker pull $toolchainImage | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Could not pull the pinned reMarkable toolchain image: $toolchainImage"
    }
}
$repoDigestsJson = (& $docker image inspect $toolchainImage --format '{{json .RepoDigests}}') -join ''
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the pinned reMarkable toolchain image.'
}
$repoDigests = @($repoDigestsJson | ConvertFrom-Json)
if ($toolchainImage -notin $repoDigests) {
    throw "The local toolchain image does not expose the required digest: $toolchainImage"
}

$generatorRepository = Join-Path $repositoryRoot "tmp\mirror\xovi-generator-$xoviGeneratorCommit"
if (-not (Test-Path -LiteralPath $generatorRepository)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $generatorRepository) -Force | Out-Null
    & $git init --quiet $generatorRepository
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not initialize the pinned Xovi generator cache.'
    }
    & $git -C $generatorRepository remote add origin $xoviRepository
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not configure the pinned Xovi generator cache.'
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $generatorRepository '.git') -PathType Container)) {
    throw "The Xovi generator cache is not a Git repository: $generatorRepository"
}
$generatorOrigin = (& $git -C $generatorRepository remote get-url origin) -join ''
if ($LASTEXITCODE -ne 0 -or $generatorOrigin -cne $xoviRepository) {
    throw 'The Xovi generator cache has an unexpected origin.'
}
& $git -C $generatorRepository cat-file -e "$xoviGeneratorCommit^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    & $git -C $generatorRepository fetch --quiet --depth 1 origin $xoviGeneratorCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fetch Xovi generator commit $xoviGeneratorCommit."
    }
}
$resolvedGeneratorCommit = (& $git -C $generatorRepository rev-parse "$xoviGeneratorCommit^{commit}") -join ''
if ($LASTEXITCODE -ne 0 -or $resolvedGeneratorCommit -cne $xoviGeneratorCommit) {
    throw 'The Xovi generator cache did not resolve to the pinned commit.'
}

New-Item -ItemType Directory -Path $outputDirectoryFull -Force | Out-Null
$finalBuild = Join-Path $outputDirectoryFull $binaryName
if (Test-Path -LiteralPath $finalBuild) {
    if (Test-Path -LiteralPath $finalBuild -PathType Container) {
        throw "Output path is a directory: $finalBuild"
    }
    if (-not $Force) {
        throw "Output already exists at $finalBuild. Pass -Force to replace it."
    }
}

$buildToken = [guid]::NewGuid().ToString('N')
$buildRoot = Join-Path $outputDirectoryFull ".build-$buildToken"
$firstBuildRoot = Join-Path $buildRoot 'first'
$secondBuildRoot = Join-Path $buildRoot 'second'
$containerCommand = @"
set -eu
. '$toolchainEnvironment'
export LC_ALL=C
export SOURCE_DATE_EPOCH=0
export TZ=UTC
cd /work/source
make clean >/dev/null
make -j1 XOVI_REPO=/work/xovi
test -f '$binaryName'
`$READELF -h '$binaryName' | grep -Eq 'Type:[[:space:]]+DYN'
`$READELF -h '$binaryName' | grep -Eq 'Machine:[[:space:]]+AArch64'
`$READELF -SW '$binaryName' | grep -q '\.xovi'
"@.Replace("`r`n", "`n").Trim()

try {
    foreach ($isolatedBuildRoot in @($firstBuildRoot, $secondBuildRoot)) {
        $isolatedSource = Join-Path $isolatedBuildRoot 'source'
        $isolatedGenerator = Join-Path $isolatedBuildRoot 'xovi'
        New-Item -ItemType Directory -Path $isolatedSource, $isolatedGenerator -Force | Out-Null
        foreach ($sourceName in @(
                'main.cpp',
                'Makefile',
                'rmmirror-files-loopback.xovi'
            )) {
            Copy-Item -LiteralPath (Join-Path $sourceDirectory $sourceName) -Destination $isolatedSource
        }

        $generatorArchive = Join-Path $isolatedBuildRoot 'xovi-generator.tar'
        & $git -C $generatorRepository archive `
            --format=tar `
            "--output=$generatorArchive" `
            $xoviGeneratorCommit `
            -- `
            util/xovigen.py `
            src/external.h
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not export the pinned Xovi generator sources.'
        }
        & tar.exe -xf $generatorArchive -C $isolatedGenerator
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not extract the pinned Xovi generator sources.'
        }

        $isolatedBuildFull = [System.IO.Path]::GetFullPath($isolatedBuildRoot)
        & $docker run `
            --rm `
            --network none `
            --mount "type=bind,source=$isolatedBuildFull,destination=/work" `
            $toolchainImage `
            bash -lc $containerCommand | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Files loopback extension build failed with exit code $LASTEXITCODE."
        }
    }

    $firstBuild = Join-Path $firstBuildRoot "source\$binaryName"
    $secondBuild = Join-Path $secondBuildRoot "source\$binaryName"
    $firstHash = (Get-FileHash -LiteralPath $firstBuild -Algorithm SHA256).Hash.ToLowerInvariant()
    $secondHash = (Get-FileHash -LiteralPath $secondBuild -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($firstHash -cne $secondHash) {
        throw 'The two clean Files loopback builds produced different SHA-256 hashes.'
    }

    $bytes = [System.IO.File]::ReadAllBytes($firstBuild)
    if ($bytes.Length -lt 64 -or
        $bytes[0] -ne 0x7f -or
        $bytes[1] -ne 0x45 -or
        $bytes[2] -ne 0x4c -or
        $bytes[3] -ne 0x46 -or
        $bytes[4] -ne 2 -or
        $bytes[5] -ne 1 -or
        [BitConverter]::ToUInt16($bytes, 16) -ne 3 -or
        [BitConverter]::ToUInt16($bytes, 18) -ne 183) {
        throw 'Build output is not a 64-bit little-endian AArch64 shared object.'
    }

    [System.IO.File]::Copy($firstBuild, $finalBuild, [bool]$Force)
    $publishedHash = (Get-FileHash -LiteralPath $finalBuild -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($publishedHash -cne $firstHash) {
        throw 'Published Files loopback extension hash does not match the verified build.'
    }

    [pscustomobject]@{
        BinaryName = $binaryName
        SourceDirectory = $sourceDirectory
        OutputPath = $finalBuild
        Sha256 = $publishedHash
        Bytes = (Get-Item -LiteralPath $finalBuild).Length
        Format = 'ELF64 little-endian AArch64 shared object'
        ToolchainImage = $toolchainImage
        ToolchainEnvironment = $toolchainEnvironment
        XoviGeneratorCommit = $xoviGeneratorCommit
        TwoCleanBuildsHashIdentical = $true
        NetworkDisabledDuringCompilation = $true
    }
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        $buildRootFull = [System.IO.Path]::GetFullPath($buildRoot)
        $outputPrefix = $outputDirectoryFull.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $buildRootFull.StartsWith(
                $outputPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing to clean build path outside $outputDirectoryFull"
        }
        Remove-Item -LiteralPath $buildRootFull -Recurse -Force
    }
}
