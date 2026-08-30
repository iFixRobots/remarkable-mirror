Set-StrictMode -Version Latest

$script:RemarkableGoRepositoryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..')
)

function Assert-RemarkablePathHasNoReparsePoints {
    param(
        [Parameter(Mandatory)]
        [string]$CandidatePath,

        [Parameter(Mandatory)]
        [string]$BoundaryPath,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
    $boundaryFull = [System.IO.Path]::GetFullPath($BoundaryPath)
    $current = $candidateFull

    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label must not traverse a junction or symbolic link: $current"
            }
        }

        if ($current.Equals($boundaryFull, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "$Label does not resolve beneath $boundaryFull"
        }
        $current = $parent.FullName
    }
}

function Build-RemarkableGoProgram {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')]
        [string]$BinaryName,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [ValidatePattern('^(\.|\./[A-Za-z0-9._/-]+)$')]
        [string]$Package = '.',

        [switch]$Force,

        [string]$ExpectedGoVersion = 'go version go1.26.5 windows/amd64'
    )

    $repositoryRoot = $script:RemarkableGoRepositoryRoot
    if ($Package -match '(^|/)\.\.($|/)') {
        throw 'Package must not traverse outside SourceDirectory.'
    }
    $allowedSourceRoots = @(
        [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'development'))
        [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'mirror'))
    )
    $allowedOutputRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot 'tmp')
    )

    $sourceCandidate = if ([System.IO.Path]::IsPathRooted($SourceDirectory)) {
        $SourceDirectory
    }
    else {
        Join-Path $repositoryRoot $SourceDirectory
    }
    $sourceDirectoryFull = [System.IO.Path]::GetFullPath($sourceCandidate)
    $allowedSourceRoot = $allowedSourceRoots | Where-Object {
        $prefix = $_.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
            [System.IO.Path]::DirectorySeparatorChar
        $sourceDirectoryFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($null -eq $allowedSourceRoot) {
        throw "SourceDirectory must remain under one of: $($allowedSourceRoots -join ', ')"
    }
    Assert-RemarkablePathHasNoReparsePoints `
        -CandidatePath $sourceDirectoryFull `
        -BoundaryPath $allowedSourceRoot `
        -Label 'SourceDirectory'
    if (-not (Test-Path -LiteralPath $sourceDirectoryFull -PathType Container)) {
        throw "SourceDirectory does not exist: $sourceDirectoryFull"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectoryFull 'go.mod') -PathType Leaf)) {
        throw "SourceDirectory does not contain go.mod: $sourceDirectoryFull"
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
    Assert-RemarkablePathHasNoReparsePoints `
        -CandidatePath $outputDirectoryFull `
        -BoundaryPath $allowedOutputRoot `
        -Label 'OutputDirectory'

    $goCommand = Get-Command go -ErrorAction Stop
    $goExecutable = $goCommand.Source
    $hostGoVersion = (& $goExecutable version) -join "`n"
    $pinnedToolchain = $null
    if ($hostGoVersion -ne $ExpectedGoVersion) {
        # Run the pinned toolchain even when the host Go is newer. GOTOOLCHAIN
        # provisions it inside the environment-guarded block below; the
        # isolated builds then invoke that exact toolchain binary with
        # GOTOOLCHAIN=local so nothing re-selects.
        $pinnedToolchainMatch = [regex]::Match(
            $ExpectedGoVersion,
            '^go version (go[0-9][A-Za-z0-9.]*) '
        )
        if (-not $pinnedToolchainMatch.Success) {
            throw "Cannot derive a pinned Go toolchain from '$ExpectedGoVersion'."
        }
        $pinnedToolchain = $pinnedToolchainMatch.Groups[1].Value
    }

    New-Item -ItemType Directory -Path $outputDirectoryFull -Force | Out-Null
    Assert-RemarkablePathHasNoReparsePoints `
        -CandidatePath $outputDirectoryFull `
        -BoundaryPath $allowedOutputRoot `
        -Label 'OutputDirectory'

    $buildToken = [guid]::NewGuid().ToString('N')
    $buildRoot = Join-Path $outputDirectoryFull ".build-$buildToken"
    $firstCache = Join-Path $buildRoot 'cache-first'
    $secondCache = Join-Path $buildRoot 'cache-second'
    $moduleCache = Join-Path $buildRoot 'module-cache'
    $firstBuild = Join-Path $buildRoot "$BinaryName.first"
    $secondBuild = Join-Path $buildRoot "$BinaryName.second"
    $finalBuild = Join-Path $outputDirectoryFull $BinaryName
    if (Test-Path -LiteralPath $finalBuild) {
        if (Test-Path -LiteralPath $finalBuild -PathType Container) {
            throw "Output path is a directory: $finalBuild"
        }
        Assert-RemarkablePathHasNoReparsePoints `
            -CandidatePath $finalBuild `
            -BoundaryPath $allowedOutputRoot `
            -Label 'Output path'
        if (-not $Force) {
            throw "Output already exists at $finalBuild. Pass -Force to replace it."
        }
    }

    $savedEnvironment = @{
        GOOS = $env:GOOS
        GOARCH = $env:GOARCH
        CGO_ENABLED = $env:CGO_ENABLED
        GOTOOLCHAIN = $env:GOTOOLCHAIN
        GOWORK = $env:GOWORK
        GOENV = $env:GOENV
        GOFLAGS = $env:GOFLAGS
        GOEXPERIMENT = $env:GOEXPERIMENT
        GOARM64 = $env:GOARM64
        GOPROXY = $env:GOPROXY
        GOSUMDB = $env:GOSUMDB
        GOCACHE = $env:GOCACHE
        GOMODCACHE = $env:GOMODCACHE
    }

    try {
        if ($null -ne $pinnedToolchain) {
            # Provisioning uses the caller's proxy and module cache; only the
            # verified builds below get the hermetic overrides.
            $env:GOTOOLCHAIN = $pinnedToolchain
            & $goExecutable version | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw ("Could not provision the pinned Go toolchain " +
                    "'$pinnedToolchain' with the host Go at $goExecutable.")
            }
            $pinnedGoRoot = ((& $goExecutable env GOROOT) -join "`n").Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pinnedGoRoot)) {
                throw "Could not resolve GOROOT for the pinned Go toolchain '$pinnedToolchain'."
            }
            $pinnedGoExecutable = Join-Path $pinnedGoRoot 'bin\go.exe'
            if (-not (Test-Path -LiteralPath $pinnedGoExecutable -PathType Leaf)) {
                throw "The provisioned Go toolchain has no executable at $pinnedGoExecutable."
            }
            $goExecutable = $pinnedGoExecutable
        }

        New-Item -ItemType Directory -Path $firstCache, $secondCache, $moduleCache -Force | Out-Null

        $env:GOOS = 'linux'
        $env:GOARCH = 'arm64'
        $env:CGO_ENABLED = '0'
        $env:GOTOOLCHAIN = 'local'
        $env:GOWORK = 'off'
        $env:GOENV = 'off'
        $env:GOFLAGS = ''
        $env:GOEXPERIMENT = ''
        $env:GOARM64 = 'v8.0'
        $env:GOPROXY = 'off'
        $env:GOSUMDB = 'off'
        $env:GOMODCACHE = $moduleCache

        $actualGoVersion = (& $goExecutable version) -join "`n"
        if ($actualGoVersion -ne $ExpectedGoVersion) {
            throw "This verified build requires '$ExpectedGoVersion'; found '$actualGoVersion'."
        }

        Push-Location $sourceDirectoryFull
        try {
            $env:GOCACHE = $firstCache
            & $goExecutable build -a -mod=readonly -trimpath -buildvcs=false `
                -ldflags '-s -w -buildid=' -o $firstBuild $Package
            if ($LASTEXITCODE -ne 0) {
                throw "First Go build failed with exit code $LASTEXITCODE"
            }

            $env:GOCACHE = $secondCache
            & $goExecutable build -a -mod=readonly -trimpath -buildvcs=false `
                -ldflags '-s -w -buildid=' -o $secondBuild $Package
            if ($LASTEXITCODE -ne 0) {
                throw "Second Go build failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }

        $firstHash = (Get-FileHash -LiteralPath $firstBuild -Algorithm SHA256).Hash.ToLowerInvariant()
        $secondHash = (Get-FileHash -LiteralPath $secondBuild -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($firstHash -ne $secondHash) {
            throw 'The two clean builds produced different SHA-256 hashes.'
        }

        $bytes = [System.IO.File]::ReadAllBytes($firstBuild)
        if ($bytes.Length -lt 64 -or
            $bytes[0] -ne 0x7f -or
            $bytes[1] -ne 0x45 -or
            $bytes[2] -ne 0x4c -or
            $bytes[3] -ne 0x46) {
            throw 'Build output is not an ELF file.'
        }
        if ($bytes[4] -ne 2 -or $bytes[5] -ne 1) {
            throw 'Build output is not 64-bit little-endian ELF.'
        }

        $machine = [BitConverter]::ToUInt16($bytes, 18)
        if ($machine -ne 183) {
            throw "Build output has ELF machine $machine instead of AArch64 183."
        }

        $programHeaderOffset = [BitConverter]::ToUInt64($bytes, 32)
        $programHeaderEntrySize = [BitConverter]::ToUInt16($bytes, 54)
        $programHeaderCount = [BitConverter]::ToUInt16($bytes, 56)
        $hasInterpreter = $false
        for ($index = 0; $index -lt $programHeaderCount; $index++) {
            $entryOffset = [int]($programHeaderOffset + ($index * $programHeaderEntrySize))
            if (($entryOffset + 4) -gt $bytes.Length) {
                throw 'ELF program header extends beyond the file.'
            }
            if ([BitConverter]::ToUInt32($bytes, $entryOffset) -eq 3) {
                $hasInterpreter = $true
                break
            }
        }
        if ($hasInterpreter) {
            throw 'Build output unexpectedly depends on a dynamic ELF interpreter.'
        }

        [System.IO.File]::Copy($firstBuild, $finalBuild, [bool]$Force)
        $publishedHash = (Get-FileHash -LiteralPath $finalBuild -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($publishedHash -ne $firstHash) {
            throw 'Published binary hash does not match the verified build.'
        }

        [pscustomobject]@{
            BinaryName = $BinaryName
            SourceDirectory = $sourceDirectoryFull
            Package = $Package
            OutputPath = $finalBuild
            Sha256 = $firstHash
            Bytes = (Get-Item -LiteralPath $finalBuild).Length
            Format = 'ELF64 little-endian AArch64'
            DynamicInterpreter = $false
            TwoCleanBuildsHashIdentical = $true
            TwoIsolatedBuildCachesHashIdentical = $true
            IsolatedBuildCaches = $true
            GoVersion = $actualGoVersion
        }
    }
    finally {
        foreach ($name in $savedEnvironment.Keys) {
            $value = $savedEnvironment[$name]
            if ($null -eq $value) {
                Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path "Env:$name" -Value $value
            }
        }

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
            Assert-RemarkablePathHasNoReparsePoints `
                -CandidatePath $buildRootFull `
                -BoundaryPath $outputDirectoryFull `
                -Label 'Build cleanup path'
            Remove-Item -LiteralPath $buildRootFull -Recurse -Force
        }
    }
}
