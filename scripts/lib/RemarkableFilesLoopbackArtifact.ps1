Set-StrictMode -Version Latest

function Get-RemarkableFilesLoopbackBuildConfiguration {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        BinaryName = 'rmmirror-files-loopback.so'
        ToolchainImage = 'eeems/remarkable-toolchain@sha256:893ad3bc55d0ef23603a2fcef05572694cadc8ce9410ada9c28e4879e859d9ce'
        ToolchainEnvironment = '/opt/codex/ferrari/5.7.119/environment-setup-cortexa53-crypto-remarkable-linux'
        XoviRepository = 'https://github.com/asivery/xovi.git'
        XoviGeneratorCommit = '0c8d5269b55c851901d4e4a754dc2d7deab40b17'
    }
}

function Get-VerifiedRemarkableFilesLoopbackArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256
    )

    $configuration = Get-RemarkableFilesLoopbackBuildConfiguration
    $artifactPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Prebuilt Files loopback artifact does not exist: $artifactPath"
    }

    $expectedHash = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($expectedHash -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Prebuilt Files loopback SHA-256 must contain exactly 64 hexadecimal characters.'
    }

    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $expectedHash) {
        throw "Prebuilt Files loopback SHA-256 mismatch: expected $expectedHash; found $actualHash."
    }

    $bytes = [System.IO.File]::ReadAllBytes($artifactPath)
    if ($bytes.Length -lt 64 -or
        $bytes[0] -ne 0x7f -or
        $bytes[1] -ne 0x45 -or
        $bytes[2] -ne 0x4c -or
        $bytes[3] -ne 0x46 -or
        $bytes[4] -ne 2 -or
        $bytes[5] -ne 1 -or
        [BitConverter]::ToUInt16($bytes, 16) -ne 3 -or
        [BitConverter]::ToUInt16($bytes, 18) -ne 183) {
        throw 'Prebuilt Files loopback artifact is not a 64-bit little-endian AArch64 shared object.'
    }

    [pscustomobject]@{
        BinaryName = $configuration.BinaryName
        OutputPath = $artifactPath
        Sha256 = $actualHash
        Bytes = $bytes.Length
        Format = 'ELF64 little-endian AArch64 shared object'
        ToolchainImage = $configuration.ToolchainImage
        ToolchainEnvironment = $configuration.ToolchainEnvironment
        XoviGeneratorCommit = $configuration.XoviGeneratorCommit
        Prebuilt = $true
    }
}
