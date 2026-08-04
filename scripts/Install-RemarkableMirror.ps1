[CmdletBinding()]
param(
    [switch]$SkipTabletSetup,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredReleaseMetadataValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "release.json is missing the required '$Name' value."
    }
    return $property.Value
}

function Get-RequiredReleaseMetadataString {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-RequiredReleaseMetadataValue -Object $Object -Name $Name
    if ($value -isnot [string] -or
        [string]::IsNullOrWhiteSpace($value) -or
        $value -match "[`r`n]") {
        throw "release.json '$Name' must be a non-empty single-line string."
    }
    return $value
}

if (-not $SkipTabletSetup -and
    ($PSVersionTable.PSVersion.Major -lt 7 -or
        ($PSVersionTable.PSVersion.Major -eq 7 -and
            $PSVersionTable.PSVersion.Minor -lt 5))) {
    throw 'Tablet setup requires PowerShell 7.5 or newer. Install PowerShell 7 and rerun Install.cmd. -SkipTabletSetup is only for an app-only reinstall of a release whose tablet probe already matches.'
}

$officialIdentityName = 'A184FD6B-E071-4B75-A3B4-DF4397457284'
$officialPublisher = 'CN=iFixRobots'
$identityName = $officialIdentityName
$expectedPublisher = $officialPublisher
$expectedVersion = $null
$packageFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'ReMarkableMirror-*-x64.msix' -File)
if ($packageFiles.Count -ne 1) {
    throw "Expected exactly one reMarkable Mirror x64 MSIX next to this installer, found $($packageFiles.Count)."
}
$packagePath = $packageFiles[0].FullName
$releaseMetadataPath = Join-Path $PSScriptRoot 'release.json'
if (Test-Path -LiteralPath $releaseMetadataPath -PathType Leaf) {
    try {
        $releaseMetadata = [System.IO.File]::ReadAllText($releaseMetadataPath) |
            ConvertFrom-Json
    }
    catch {
        throw "release.json could not be read: $($_.Exception.Message)"
    }

    $releaseSchema = Get-RequiredReleaseMetadataString `
        -Object $releaseMetadata `
        -Name 'schema'
    if ($releaseSchema -cne 'remarkable-mirror.release/v1') {
        throw "Unsupported release.json schema: $releaseSchema"
    }

    $packageMetadata = Get-RequiredReleaseMetadataValue `
        -Object $releaseMetadata `
        -Name 'package'
    $metadataPackageFile = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'file'
    $metadataIdentity = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'identity'
    $metadataPublisher = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'publisher'
    $metadataVersion = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'version'
    $metadataArchitecture = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'architecture'
    $metadataPackageHash = Get-RequiredReleaseMetadataString -Object $packageMetadata -Name 'sha256'

    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $metadataPackageFile,
            [System.IO.Path]::GetFileName($packagePath))) {
        throw "release.json describes '$metadataPackageFile', not '$([System.IO.Path]::GetFileName($packagePath))'."
    }
    if ($metadataIdentity -notmatch '^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$') {
        throw "release.json contains an invalid package identity: $metadataIdentity"
    }
    if ($metadataVersion -notmatch '^\d{1,5}(?:\.\d{1,5}){3}$') {
        throw "release.json contains an invalid package version: $metadataVersion"
    }
    foreach ($versionPart in ($metadataVersion -split '\.')) {
        [uint16]$versionComponent = 0
        if (-not [uint16]::TryParse($versionPart, [ref]$versionComponent)) {
            throw "release.json contains an invalid package version: $metadataVersion"
        }
    }
    if ($metadataArchitecture -cne 'x64') {
        throw "release.json describes unsupported package architecture: $metadataArchitecture"
    }
    if ($metadataPackageHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'release.json contains an invalid package SHA-256.'
    }

    $actualPackageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $metadataPackageHash,
            $actualPackageHash)) {
        throw 'The reMarkable Mirror MSIX does not match the SHA-256 recorded in release.json.'
    }

    $identityName = $metadataIdentity
    $expectedPublisher = $metadataPublisher
    $expectedVersion = $metadataVersion
}
$certificatePath = Join-Path $PSScriptRoot 'ReMarkableMirror.cer'
if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
    throw "The package certificate is missing: $certificatePath"
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
if ($certificate.Subject -ne $expectedPublisher) {
    throw "The included certificate publisher is '$($certificate.Subject)', not '$expectedPublisher'."
}

$signature = Get-AuthenticodeSignature -LiteralPath $packagePath
if ($null -eq $signature.SignerCertificate) {
    throw 'The reMarkable Mirror MSIX is not signed.'
}
if ($signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
    throw 'The included certificate does not match the MSIX signature.'
}

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host 'Windows will ask for permission to trust the private release certificate and install Mirror.'
    $shellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    $elevatedArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    if ($SkipTabletSetup) {
        $elevatedArguments += '-SkipTabletSetup'
    }
    if ($NoLaunch) {
        $elevatedArguments += '-NoLaunch'
    }
    $elevated = Start-Process `
        -FilePath $shellPath `
        -ArgumentList $elevatedArguments `
        -Verb RunAs `
        -Wait `
        -PassThru
    exit $elevated.ExitCode
}

$trustedCertificate = Get-ChildItem Cert:\LocalMachine\TrustedPeople |
    Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
    Select-Object -First 1
if ($null -eq $trustedCertificate) {
    Write-Host 'Trusting the reMarkable Mirror package certificate in Local Machine > Trusted People...'
    Import-Certificate -FilePath $certificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
}

$trustedSignature = Get-AuthenticodeSignature -LiteralPath $packagePath
if ($null -eq $trustedSignature.SignerCertificate -or
    $trustedSignature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint -or
    $trustedSignature.Status -notin @(
        [System.Management.Automation.SignatureStatus]::Valid,
        [System.Management.Automation.SignatureStatus]::UnknownError
    )) {
    throw "Windows did not accept the package signature: $($trustedSignature.StatusMessage)"
}

$dependencyDirectory = Join-Path $PSScriptRoot 'Dependencies\x64'
$dependencies = @()
if (Test-Path -LiteralPath $dependencyDirectory -PathType Container) {
    $dependencies = @(Get-ChildItem -LiteralPath $dependencyDirectory -Filter '*.msix' -File)
}

Write-Host 'Installing reMarkable Mirror...'
$installArguments = @{
    Path = $packagePath
    ForceApplicationShutdown = $true
    ForceUpdateFromAnyVersion = $true
}
if ($dependencies.Count -gt 0) {
    $installArguments.DependencyPath = $dependencies.FullName
}

$developmentPackages = @(
    Get-AppxPackage -Name $identityName |
        Where-Object { $_.IsDevelopmentMode }
)
foreach ($developmentPackage in $developmentPackages) {
    Write-Host 'Replacing the local development registration with the packaged app...'
    Remove-AppxPackage `
        -Package $developmentPackage.PackageFullName `
        -PreserveApplicationData
}

Add-AppxPackage @installArguments

$installed = Get-AppxPackage -Name $identityName | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $installed) {
    throw 'Windows reported success, but the reMarkable Mirror package is not registered.'
}
if ($installed.IsDevelopmentMode) {
    throw 'Windows kept the development registration instead of installing the packaged app.'
}
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($installed.Name, $identityName)) {
    throw "Windows registered package '$($installed.Name)', not '$identityName'."
}
if ($installed.Publisher -ne $expectedPublisher) {
    throw "Windows registered publisher '$($installed.Publisher)', not '$expectedPublisher'."
}
if ($null -ne $expectedVersion -and
    [string]$installed.Version -cne $expectedVersion) {
    throw "Windows registered version '$($installed.Version)', not '$expectedVersion'."
}

if (-not $SkipTabletSetup) {
    $tabletSetupPath = Join-Path $PSScriptRoot 'Install-RemarkableMirrorPrerequisites.ps1'
    if (-not (Test-Path -LiteralPath $tabletSetupPath -PathType Leaf)) {
        throw 'The app is installed, but the tablet prerequisite installer is missing. Rebuild the complete release or rerun with -SkipTabletSetup.'
    }

    Write-Host 'Setting up the connected reMarkable tablet...'
    try {
        & $tabletSetupPath
    }
    catch {
        throw "The Windows app is installed, but tablet setup did not finish. The current setup path requires Developer Mode and the existing trusted SSH identity. $($_.Exception.Message)"
    }
}

Write-Host "Installed reMarkable Mirror $($installed.Version)."
if (-not $NoLaunch) {
    Start-Process explorer.exe "shell:AppsFolder\$($installed.PackageFamilyName)!App"
}
