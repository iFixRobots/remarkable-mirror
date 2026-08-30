#Requires -Version 7.5

[CmdletBinding()]
param(
    [ValidateSet('10.11.99.1')]
    [string]$TabletAddress = '10.11.99.1',
    [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'),
    [string]$KnownHostsFile = (Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'),
    [string]$TransportWakeBinary,
    [string]$MirrorProbeBinary,
    [string]$XoviArchive,
    [string]$FilesLoopbackExtension,
    [switch]$RecognizeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\RemarkableRmctlCapture.ps1')

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseComponentDirectory = Join-Path $PSScriptRoot 'components'
$deployDirectory = Join-Path $repositoryRoot 'mirror\agent\deploy'
$releaseContract = Join-Path $releaseComponentDirectory 'rmmirror-prerequisites.env'
$contractSource = if (Test-Path -LiteralPath $releaseContract -PathType Leaf) {
    $releaseContract
}
else {
    Join-Path $deployDirectory 'rmmirror-prerequisites.env'
}
if (-not (Test-Path -LiteralPath $contractSource -PathType Leaf)) {
    throw "The tablet prerequisite contract is missing: $contractSource"
}
$contractValues = @{}
foreach ($line in [System.IO.File]::ReadAllLines($contractSource)) {
    if ($line -cnotmatch '^([A-Z0-9_]+)=([A-Za-z0-9.,/+_-]+)$' -or
        $contractValues.ContainsKey($Matches[1])) {
        throw 'The tablet prerequisite contract is malformed.'
    }
    $contractValues[$Matches[1]] = $Matches[2]
}
$expectedContractKeys = @(
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
if ((($contractValues.Keys | Sort-Object) -join "`n") -cne
    (($expectedContractKeys | Sort-Object) -join "`n")) {
    throw 'The tablet prerequisite contract has unexpected fields.'
}
$runToken = [guid]::NewGuid().ToString('N')
$buildDirectory = Join-Path $repositoryRoot "tmp\mirror\transport-wake-$runToken"
$remoteStage = "/home/root/.rmmirror-transport-stage-$runToken"
$usbTabletAddress = '10.11.99.1'
$usbHostAddress = '10.11.99.11'
$usbPrefixLength = 27
$stageCreated = $false
$wakeTokenFile = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_wake_token'
$sshHostKeyAlias = '10.11.99.1'
$xoviRelease = $contractValues['RMMIRROR_XOVI_RELEASE']
$xoviArchiveHashExpected = $contractValues['RMMIRROR_XOVI_ARCHIVE_SHA256']

function Get-DirectUsbTabletRoute {
    [CmdletBinding()]
    param(
        [ValidateSet('10.11.99.1')]
        [string]$TabletAddress = '10.11.99.1',
        [ValidateSet('10.11.99.11')]
        [string]$HostAddress = '10.11.99.11',
        [ValidateSet(27)]
        [byte]$PrefixLength = 27
    )

    try {
        $addresses = @(Get-NetIPAddress `
            -IPAddress $HostAddress `
            -AddressFamily IPv4 `
            -ErrorAction Stop)
        if ($addresses.Count -ne 1) {
            throw 'missing or ambiguous USB source address'
        }

        $address = $addresses[0]
        if ($address.IPAddress -cne $HostAddress -or
            [int]$address.PrefixLength -ne $PrefixLength -or
            [string]$address.AddressState -cne 'Preferred' -or
            [bool]$address.SkipAsSource -or
            [int]$address.InterfaceIndex -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$address.InterfaceAlias)) {
            throw 'USB source address is not usable'
        }

        $adapters = @(Get-NetAdapter `
            -InterfaceIndex ([int]$address.InterfaceIndex) `
            -ErrorAction Stop)
        if ($adapters.Count -ne 1) {
            throw 'missing or ambiguous USB adapter'
        }

        $adapter = $adapters[0]
        if ([int]$adapter.InterfaceIndex -ne [int]$address.InterfaceIndex -or
            [string]$adapter.InterfaceAlias -cne [string]$address.InterfaceAlias -or
            [string]$adapter.InterfaceAlias -cnotmatch '^[^"\\\x00-\x1F\x7F]{1,128}$' -or
            [string]$adapter.Status -cne 'Up' -or
            -not [bool]$adapter.HardwareInterface -or
            [bool]$adapter.Virtual -or
            [string]$adapter.PnPDeviceID -cnotmatch '^USB\\') {
            throw 'source address is not owned by an active physical USB adapter'
        }

        $routeResult = @(Find-NetRoute `
            -RemoteIPAddress $TabletAddress `
            -LocalIPAddress $HostAddress `
            -ErrorAction Stop)
        $routeSources = @(
            $routeResult |
                Where-Object {
                    $_.PSObject.Properties.Match('IPAddress').Count -eq 1 -and
                        $_.PSObject.Properties.Match('DestinationPrefix').Count -eq 0
                }
        )
        $routes = @(
            $routeResult |
                Where-Object {
                    $_.PSObject.Properties.Match('DestinationPrefix').Count -eq 1
                }
        )
        if ($routeSources.Count -ne 1 -or $routes.Count -ne 1) {
            throw 'missing or ambiguous direct USB route'
        }

        $routeSource = $routeSources[0]
        $route = $routes[0]
        if ($routeSource.IPAddress -cne $HostAddress -or
            [int]$routeSource.PrefixLength -ne $PrefixLength -or
            [int]$routeSource.InterfaceIndex -ne [int]$address.InterfaceIndex -or
            $route.DestinationPrefix -cne '10.11.99.0/27' -or
            [int]$route.InterfaceIndex -ne [int]$address.InterfaceIndex -or
            $route.NextHop -cne '0.0.0.0' -or
            [string]$route.State -cne 'Alive') {
            throw 'the selected route is not the direct USB /27'
        }

        [pscustomobject]@{
            InterfaceIndex = [int]$address.InterfaceIndex
            InterfaceAlias = [string]$address.InterfaceAlias
            SourceAddress = $HostAddress
        }
    }
    catch {
        throw (
            'Connect the reMarkable directly by USB-C before setup. Windows must have the ' +
            'active USB source 10.11.99.11/27 and its direct route to 10.11.99.1. No tablet ' +
            'changes were made.'
        )
    }
}

$usbRoute = Get-DirectUsbTabletRoute
$remoteHost = "root@$usbTabletAddress"

foreach ($credentialPath in @($IdentityFile, $KnownHostsFile)) {
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        throw "Required SSH file does not exist: $credentialPath"
    }
}

$assetHashes = @{}
if (-not $RecognizeOnly) {
$releaseBinary = Join-Path $releaseComponentDirectory 'rmmirror-transport-wake'
$releaseProbe = Join-Path $releaseComponentDirectory 'rmmirror-probe'
$releaseXoviArchive = Join-Path $releaseComponentDirectory 'xovi-aarch64.tar.gz'
$releaseUnit = Join-Path $releaseComponentDirectory 'rmmirror-transport-wake.service'
$releaseInstaller = Join-Path $releaseComponentDirectory 'install-transport-wake.sh'
$releaseSleepGuard = Join-Path $releaseComponentDirectory 'rmmirror-usb-sleep-guard.conf'
$releaseFilesLoopback = Join-Path $releaseComponentDirectory 'rmmirror-files-loopback.so'
$releasePrerequisiteInstaller = Join-Path $releaseComponentDirectory 'install-mirror-prerequisites.sh'

if ([string]::IsNullOrWhiteSpace($TransportWakeBinary) -and
    (Test-Path -LiteralPath $releaseBinary -PathType Leaf)) {
    $TransportWakeBinary = $releaseBinary
}
elseif ([string]::IsNullOrWhiteSpace($TransportWakeBinary)) {
    $build = & (Join-Path $PSScriptRoot 'Build-RemarkableTransportWake.ps1') `
        -OutputDirectory $buildDirectory `
        -Force
    $TransportWakeBinary = $build.OutputPath
}

if ([string]::IsNullOrWhiteSpace($MirrorProbeBinary) -and
    (Test-Path -LiteralPath $releaseProbe -PathType Leaf)) {
    $MirrorProbeBinary = $releaseProbe
}
elseif ([string]::IsNullOrWhiteSpace($MirrorProbeBinary)) {
    $probeBuild = & (Join-Path $PSScriptRoot 'Build-RemarkableMirrorAgent.ps1') `
        -OutputDirectory (Join-Path $buildDirectory 'probe') `
        -Force
    $MirrorProbeBinary = $probeBuild.OutputPath
}

if ([string]::IsNullOrWhiteSpace($XoviArchive) -and
    (Test-Path -LiteralPath $releaseXoviArchive -PathType Leaf)) {
    $XoviArchive = $releaseXoviArchive
}
elseif ([string]::IsNullOrWhiteSpace($XoviArchive)) {
    $cachedXoviArchive = Join-Path $repositoryRoot "tmp\mirror\xovi-$xoviRelease\xovi-aarch64.tar.gz"
    if (-not (Test-Path -LiteralPath $cachedXoviArchive -PathType Leaf)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cachedXoviArchive) -Force | Out-Null
        Invoke-WebRequest `
            -Uri "https://github.com/asivery/rm-xovi-extensions/releases/download/$xoviRelease/xovi-aarch64.tar.gz" `
            -OutFile $cachedXoviArchive
    }
    $XoviArchive = $cachedXoviArchive
}

if ([string]::IsNullOrWhiteSpace($FilesLoopbackExtension) -and
    (Test-Path -LiteralPath $releaseFilesLoopback -PathType Leaf)) {
    $FilesLoopbackExtension = $releaseFilesLoopback
}
elseif ([string]::IsNullOrWhiteSpace($FilesLoopbackExtension)) {
    $filesLoopbackBuild = & (Join-Path $PSScriptRoot 'Build-RemarkableFilesLoopback.ps1') `
        -OutputDirectory (Join-Path $buildDirectory 'files-loopback') `
        -Force
    if ($null -eq $filesLoopbackBuild -or
        -not (Test-Path -LiteralPath $filesLoopbackBuild.OutputPath -PathType Leaf)) {
        throw 'The Files loopback build did not return a usable ARM64 shared object.'
    }
    $FilesLoopbackExtension = $filesLoopbackBuild.OutputPath
}

$binaryFull = [System.IO.Path]::GetFullPath($TransportWakeBinary)
$probeFull = [System.IO.Path]::GetFullPath($MirrorProbeBinary)
$xoviArchiveFull = [System.IO.Path]::GetFullPath($XoviArchive)
$filesLoopbackFull = [System.IO.Path]::GetFullPath($FilesLoopbackExtension)
$unitSource = if (Test-Path -LiteralPath $releaseUnit -PathType Leaf) {
    $releaseUnit
}
else {
    Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-transport-wake.service'
}
$installerSource = if (Test-Path -LiteralPath $releaseInstaller -PathType Leaf) {
    $releaseInstaller
}
else {
    Join-Path $repositoryRoot 'mirror\agent\deploy\install-transport-wake.sh'
}
$sleepGuardSource = if (Test-Path -LiteralPath $releaseSleepGuard -PathType Leaf) {
    $releaseSleepGuard
}
else {
    Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-usb-sleep-guard.conf'
}
$prerequisiteInstallerSource = if (
    Test-Path -LiteralPath $releasePrerequisiteInstaller -PathType Leaf
) {
    $releasePrerequisiteInstaller
}
else {
    Join-Path $deployDirectory 'install-mirror-prerequisites.sh'
}
$unitFull = [System.IO.Path]::GetFullPath($unitSource)
$installerFull = [System.IO.Path]::GetFullPath($installerSource)
$sleepGuardFull = [System.IO.Path]::GetFullPath($sleepGuardSource)
$prerequisiteInstallerFull = [System.IO.Path]::GetFullPath($prerequisiteInstallerSource)
$contractFull = [System.IO.Path]::GetFullPath($contractSource)
foreach ($assetPath in @(
        $binaryFull,
        $probeFull,
        $xoviArchiveFull,
        $filesLoopbackFull,
        $unitFull,
        $installerFull,
        $sleepGuardFull,
        $prerequisiteInstallerFull,
        $contractFull
    )) {
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Required tablet prerequisite asset does not exist: $assetPath"
    }
    $item = Get-Item -LiteralPath $assetPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Tablet prerequisite assets must not be symbolic links: $assetPath"
    }
}

$filesLoopbackItem = Get-Item -LiteralPath $filesLoopbackFull
$filesLoopbackBytes = [byte[]]::new(20)
$filesLoopbackStream = [System.IO.File]::OpenRead($filesLoopbackFull)
try {
    $filesLoopbackHeaderLength = $filesLoopbackStream.Read($filesLoopbackBytes, 0, $filesLoopbackBytes.Length)
}
finally {
    $filesLoopbackStream.Dispose()
}
if ($filesLoopbackItem.Length -lt 64 -or
    $filesLoopbackHeaderLength -ne $filesLoopbackBytes.Length -or
    $filesLoopbackBytes[0] -ne 0x7f -or
    $filesLoopbackBytes[1] -ne 0x45 -or
    $filesLoopbackBytes[2] -ne 0x4c -or
    $filesLoopbackBytes[3] -ne 0x46 -or
    $filesLoopbackBytes[4] -ne 2 -or
    $filesLoopbackBytes[5] -ne 1 -or
    [BitConverter]::ToUInt16($filesLoopbackBytes, 16) -ne 3 -or
    [BitConverter]::ToUInt16($filesLoopbackBytes, 18) -ne 183) {
    throw 'Files loopback extension is not a 64-bit little-endian AArch64 shared object.'
}

$xoviArchiveHash = (Get-FileHash -LiteralPath $xoviArchiveFull -Algorithm SHA256).Hash.ToLowerInvariant()
if ($xoviArchiveHash -ne $xoviArchiveHashExpected) {
    throw "Unexpected Xovi archive hash: $xoviArchiveHash"
}

$assetHashes = @{
    'rmmirror-transport-wake' =
        (Get-FileHash -LiteralPath $binaryFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'rmmirror-transport-wake.service' =
        (Get-FileHash -LiteralPath $unitFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'install-transport-wake.sh' =
        (Get-FileHash -LiteralPath $installerFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'rmmirror-usb-sleep-guard.conf' =
        (Get-FileHash -LiteralPath $sleepGuardFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'rmmirror-probe' =
        (Get-FileHash -LiteralPath $probeFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'xovi-aarch64.tar.gz' = $xoviArchiveHash
    'rmmirror-files-loopback.so' =
        (Get-FileHash -LiteralPath $filesLoopbackFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'install-mirror-prerequisites.sh' =
        (Get-FileHash -LiteralPath $prerequisiteInstallerFull -Algorithm SHA256).Hash.ToLowerInvariant()
    'rmmirror-prerequisites.env' =
        (Get-FileHash -LiteralPath $contractFull -Algorithm SHA256).Hash.ToLowerInvariant()
}
$scp = (Get-Command scp.exe -ErrorAction Stop).Source
}

$ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
$identityFull = [System.IO.Path]::GetFullPath($IdentityFile)
$knownHostsFull = [System.IO.Path]::GetFullPath($KnownHostsFile)
$sshOptions = @(
    '-F', 'NUL',
    '-i', $identityFull,
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$knownHostsFull",
    '-o', 'GlobalKnownHostsFile=NUL',
    '-o', "HostKeyAlias=$sshHostKeyAlias",
    '-o', 'UpdateHostKeys=no',
    '-o', "BindAddress=$usbHostAddress",
    '-o', 'ConnectTimeout=5',
    '-o', 'ServerAliveInterval=5',
    '-o', 'ServerAliveCountMax=2'
)

function Invoke-CheckedExternalProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $result = Invoke-RemarkableExternalProcess `
        -FilePath $FilePath `
        -Arguments $Arguments `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.ExitCode -ne 0) {
        throw "$FailureMessage (exit $($result.ExitCode)): $($result.Stderr.Trim())"
    }
    $result
}

function Invoke-RedactedCheckedExternalProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $result = Invoke-RemarkableExternalProcess `
        -FilePath $FilePath `
        -Arguments $Arguments `
        -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.ExitCode -ne 0) {
        throw "$FailureMessage (exit $($result.ExitCode))."
    }
    $result
}

function ConvertFrom-StrictPairingOutput {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$ExpectedKeys
    )

    $values = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -cnotmatch '^([A-Z_]+)=(.*)$') {
            throw 'Tablet pairing metadata was malformed.'
        }
        $key = $Matches[1]
        if ($key -notin $ExpectedKeys -or $values.ContainsKey($key)) {
            throw 'Tablet pairing metadata contained an unexpected field.'
        }
        $values[$key] = $Matches[2]
    }

    foreach ($key in $ExpectedKeys) {
        if (-not $values.ContainsKey($key)) {
            throw 'Tablet pairing metadata was incomplete.'
        }
    }
    $values
}

function Set-CurrentUserOnlyAcl {
    param(
        [Parameter(Mandatory)][System.IO.FileSystemInfo]$Item
    )

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $sid) {
        throw 'Could not determine the current Windows user SID.'
    }

    $currentAcl = Get-Acl -LiteralPath $Item.FullName
    $currentOwner = $currentAcl.GetOwner(
        [System.Security.Principal.SecurityIdentifier]
    )
    if ($currentOwner -ne $sid) {
        throw 'Mirror refuses to change an item owned by another user.'
    }

    if ($Item -is [System.IO.DirectoryInfo]) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        )
        [System.IO.FileSystemAclExtensions]::SetAccessControl($Item, $acl)
    }
    else {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        )
        [System.IO.FileSystemAclExtensions]::SetAccessControl($Item, $acl)
    }
}

function Test-CurrentUserOnlyAcl {
    param(
        [Parameter(Mandatory)][System.IO.FileSystemInfo]$Item
    )

    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($null -eq $sid) {
            return $false
        }

        $acl = Get-Acl -LiteralPath $Item.FullName
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
        if (-not $acl.AreAccessRulesProtected -or $owner -ne $sid) {
            return $false
        }

        $rules = @($acl.GetAccessRules(
            $true,
            $false,
            [System.Security.Principal.SecurityIdentifier]
        ))
        if ($rules.Count -ne 1) {
            return $false
        }

        $rule = $rules[0]
        return $rule.AccessControlType -eq
                [System.Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference -eq $sid -and
            ($rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl
    }
    catch {
        return $false
    }
}

function Set-PrivateDeviceProfile {
    param(
        [Parameter(Mandatory)][string]$SshHostKeyAlias,
        [Parameter(Mandatory)][string]$SshFingerprint,
        # A USB-only profile records no Wi-Fi route or paired Windows network.
        [Parameter(Mandatory)][AllowEmptyString()][string]$WifiHost,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WindowsInterfaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WindowsNetworkIdentity,
        [Parameter(Mandatory)][string]$TokenFileReference,
        [Parameter(Mandatory)][string]$BootId,
        [Parameter(Mandatory)][string]$ActiveRoot,
        [Parameter(Mandatory)][string]$OsVersion,
        [Parameter(Mandatory)][string]$KernelRelease,
        [Parameter(Mandatory)][string]$WakeCapabilitySchema,
        [Parameter(Mandatory)][string]$CompanionVersion
    )

    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData,
        [Environment+SpecialFolderOption]::DoNotVerify
    )
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LocalAppData is unavailable.'
    }

    $profileDirectory = Join-Path $localAppData 'ReMarkableMirror'
    $profilePath = Join-Path $profileDirectory 'device-profile.json'
    if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $profileDirectory | Out-Null
    }
    $directoryItem = Get-Item -LiteralPath $profileDirectory -Force
    if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The Mirror profile directory cannot be a reparse point.'
    }
    Set-CurrentUserOnlyAcl -Item $directoryItem

    if (Test-Path -LiteralPath $profilePath) {
        $existing = Get-Item -LiteralPath $profilePath -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The Mirror device profile cannot be a reparse point.'
        }
        Set-CurrentUserOnlyAcl -Item $existing
    }

    $profile = [ordered]@{
        schema = 'rmmirror.device-profile/v1'
        sshHostKeyAlias = $SshHostKeyAlias
        sshFingerprint = $SshFingerprint
        lastVerifiedWifiHost = $WifiHost
        pairedWindowsInterfaceId = $WindowsInterfaceId
        pairedWindowsNetworkIdentity = $WindowsNetworkIdentity
        filesTarget = [ordered]@{
            host = '127.0.0.1'
            port = 80
        }
        tokenFileReference = [System.IO.Path]::GetFullPath($TokenFileReference)
        lastVerified = [ordered]@{
            verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            bootId = $BootId
            activeRoot = $ActiveRoot
            osVersion = $OsVersion
            kernelRelease = $KernelRelease
            wakeCapabilitySchema = $WakeCapabilitySchema
            companionVersion = $CompanionVersion
        }
    }
    $json = $profile | ConvertTo-Json -Depth 6
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -le 0 -or $bytes.Length -gt (16 * 1024)) {
        throw 'The Mirror device profile has an invalid size.'
    }

    $temporaryPath = Join-Path $profileDirectory (
        '.device-profile.json.' + [guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        $stream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        Set-CurrentUserOnlyAcl -Item (Get-Item -LiteralPath $temporaryPath -Force)

        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            [System.IO.File]::Move($temporaryPath, $profilePath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $profilePath)
        }
        Set-CurrentUserOnlyAcl -Item (Get-Item -LiteralPath $profilePath -Force)

        $published = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json -Depth 10
        $publishedFields = @($published.PSObject.Properties.Name | Sort-Object)
        $expectedFields = @(
            'filesTarget',
            'lastVerified',
            'lastVerifiedWifiHost',
            'pairedWindowsInterfaceId',
            'pairedWindowsNetworkIdentity',
            'schema',
            'sshFingerprint',
            'sshHostKeyAlias',
            'tokenFileReference'
        ) | Sort-Object
        if (($publishedFields -join "`n") -cne ($expectedFields -join "`n") -or
            $published.schema -cne 'rmmirror.device-profile/v1' -or
            $published.tokenFileReference -cne [System.IO.Path]::GetFullPath($TokenFileReference)) {
            throw 'The Mirror device profile did not round-trip exactly.'
        }
        $profilePath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Set-PrivateTokenFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Token
    )

    if ($Token -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'The paired wake token is invalid.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $parentItem = Get-Item -LiteralPath $parent -Force
    if (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The wake-token directory cannot be a reparse point.'
    }

    if (Test-Path -LiteralPath $fullPath) {
        $existing = Get-Item -LiteralPath $fullPath -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The wake-token path cannot be a reparse point.'
        }
        Set-CurrentUserOnlyAcl -Item $existing
        if (-not (Test-CurrentUserOnlyAcl -Item $existing)) {
            throw 'Could not secure the existing wake-token file.'
        }
    }

    $temporaryPath = Join-Path $parent (
        '.' + [System.IO.Path]::GetFileName($fullPath) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        $emptyStream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $emptyStream.Dispose()

        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force
        if (($temporaryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The wake-token temporary file cannot be a reparse point.'
        }
        Set-CurrentUserOnlyAcl -Item $temporaryItem
        if (-not (Test-CurrentUserOnlyAcl -Item $temporaryItem)) {
            throw 'Could not secure the wake-token temporary file.'
        }

        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Token)
        $stream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            64,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if (-not (Test-CurrentUserOnlyAcl -Item $temporaryItem) -or
            [System.IO.File]::ReadAllText($temporaryPath) -cne $Token) {
            throw 'The secured wake-token temporary file did not verify.'
        }

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Move($temporaryPath, $fullPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }

        $publishedItem = Get-Item -LiteralPath $fullPath -Force
        if (($publishedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The published wake-token file cannot be a reparse point.'
        }
        Set-CurrentUserOnlyAcl -Item $publishedItem
        if (-not (Test-CurrentUserOnlyAcl -Item $publishedItem) -or
            [System.IO.File]::ReadAllText($fullPath) -cne $Token) {
            throw 'The paired wake token did not publish securely.'
        }

        $fullPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

try {
    $tabletIdentityCommand = (@"
set -eu
test "`$(tr -d '\000' < /sys/firmware/devicetree/base/model)" = 'reMarkable Chiappa'
printf '%s\n' 'RMMIRROR_TABLET_SUPPORTED=1'
"@).Replace("`r`n", "`n").Trim()
    $tabletIdentity = Invoke-CheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $tabletIdentityCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'The connected tablet model is not supported by this Mirror build'
    if ($tabletIdentity.Stdout -notmatch '(?m)^RMMIRROR_TABLET_SUPPORTED=1\r?$') {
        throw 'Tablet support verification did not return its completion marker.'
    }

    if (-not $RecognizeOnly) {
        $create = Invoke-CheckedExternalProcess `
            -FilePath $ssh `
            -Arguments ($sshOptions + @(
                $remoteHost,
                "set -eu; umask 077; test ! -e '$remoteStage'; mkdir '$remoteStage'; date +%s > '$remoteStage/.rmmirror-stage-created'"
            )) `
            -TimeoutMilliseconds 15000 `
            -FailureMessage 'Could not create the tablet prerequisite stage'
        $stageCreated = $true

        foreach ($upload in @(
                @{ Local = $binaryFull; Remote = 'rmmirror-transport-wake' },
                @{ Local = $probeFull; Remote = 'rmmirror-probe' },
                @{ Local = $xoviArchiveFull; Remote = 'xovi-aarch64.tar.gz' },
                @{ Local = $filesLoopbackFull; Remote = 'rmmirror-files-loopback.so' },
                @{ Local = $unitFull; Remote = 'rmmirror-transport-wake.service' },
                @{ Local = $installerFull; Remote = 'install-transport-wake.sh' },
                @{ Local = $sleepGuardFull; Remote = 'rmmirror-usb-sleep-guard.conf' },
                @{ Local = $prerequisiteInstallerFull; Remote = 'install-mirror-prerequisites.sh' },
                @{ Local = $contractFull; Remote = 'rmmirror-prerequisites.env' }
            )) {
            Invoke-CheckedExternalProcess `
                -FilePath $scp `
                -Arguments (@('-O', '-q') + $sshOptions + @(
                    $upload.Local,
                    "${remoteHost}:$remoteStage/$($upload.Remote)"
                )) `
                -TimeoutMilliseconds 60000 `
                -FailureMessage "Could not upload $($upload.Remote)" | Out-Null
        }

        $installCommand = (@"
set -eu
stage='$remoteStage'
test "`$(sha256sum "`$stage/install-mirror-prerequisites.sh" | cut -d' ' -f1)" = '$($assetHashes['install-mirror-prerequisites.sh'])'
chmod 0700 "`$stage/install-mirror-prerequisites.sh"
RMMIRROR_CONTRACT_SHA256='$($assetHashes['rmmirror-prerequisites.env'])' \
RMMIRROR_TRANSPORT_WAKE_SHA256='$($assetHashes['rmmirror-transport-wake'])' \
RMMIRROR_TRANSPORT_SERVICE_SHA256='$($assetHashes['rmmirror-transport-wake.service'])' \
RMMIRROR_TRANSPORT_INSTALLER_SHA256='$($assetHashes['install-transport-wake.sh'])' \
RMMIRROR_SLEEP_GUARD_SHA256='$($assetHashes['rmmirror-usb-sleep-guard.conf'])' \
RMMIRROR_PROBE_SHA256='$($assetHashes['rmmirror-probe'])' \
RMMIRROR_FILES_LOOPBACK_SHA256='$($assetHashes['rmmirror-files-loopback.so'])' \
"`$stage/install-mirror-prerequisites.sh"
"@).Replace("`r`n", "`n").Trim()
        $install = Invoke-CheckedExternalProcess `
            -FilePath $ssh `
            -Arguments ($sshOptions + @($remoteHost, $installCommand)) `
            -TimeoutMilliseconds 60000 `
            -FailureMessage 'Could not install the Mirror tablet prerequisites'
        if ($install.Stdout -notmatch '(?m)^RMMIRROR_PREREQUISITES=installed\r?$') {
            throw 'Tablet prerequisite install did not return its completion marker.'
        }
        foreach ($installStderrLine in ($install.Stderr -split "`r?`n")) {
            if ($installStderrLine -clike 'rmmirror-prerequisite: tablet_software_untested:*') {
                # Re-emit the tablet script's disclaimer on this process's own
                # stderr so the app can record it in its diagnostics.
                [Console]::Error.WriteLine($installStderrLine)
            }
        }
    }

    $endpointStatusCommand = @'
set -eu
test "$(wc -c < /data/rmmirror/wake-token)" -eq 64
LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' /data/rmmirror/wake-token
command -v busybox >/dev/null 2>&1
token=$(cat /data/rmmirror/wake-token)
{
  printf 'GET /v1/status HTTP/1.1\r\n'
  printf 'Host: 127.0.0.1:51337\r\n'
  printf 'Authorization: Bearer %s\r\n' "$token"
  printf 'Connection: close\r\n\r\n'
} | busybox nc 127.0.0.1 51337
'@.Replace("`r`n", "`n").Trim()
    $endpointStatusResult = Invoke-RedactedCheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $endpointStatusCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'Could not verify the tablet wake endpoint over trusted USB'
    $endpointResponse = $endpointStatusResult.Stdout
    if ([string]::IsNullOrWhiteSpace($endpointResponse) -or
        $endpointResponse.Length -gt 8192) {
        throw 'Wake endpoint returned an invalid response.'
    }
    $headerBoundary = $endpointResponse.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
    $headerBoundaryLength = 4
    if ($headerBoundary -lt 0) {
        $headerBoundary = $endpointResponse.IndexOf("`n`n", [StringComparison]::Ordinal)
        $headerBoundaryLength = 2
    }
    if ($headerBoundary -le 0) {
        throw 'Wake endpoint returned an invalid HTTP response.'
    }
    $responseHeaders = $endpointResponse.Substring(0, $headerBoundary)
    if (-not $responseHeaders.StartsWith('HTTP/1.1 200 ', [StringComparison]::Ordinal)) {
        throw 'Wake endpoint did not return HTTP 200.'
    }
    $responseBody = $endpointResponse.Substring($headerBoundary + $headerBoundaryLength)
    if ([string]::IsNullOrWhiteSpace($responseBody) -or $responseBody.Length -gt 4096) {
        throw 'Wake endpoint returned an invalid response body.'
    }
    try {
        $wakeState = $responseBody | ConvertFrom-Json -Depth 10
    }
    catch {
        throw 'Wake endpoint returned an invalid response.'
    }
    if ($wakeState.schema -ne 'rmmirror.wake/v1' -or
        $wakeState.state -notin @('unlock_required', 'sleeping', 'ready', 'starting')) {
        throw 'Wake endpoint returned an unexpected response.'
    }

    $tokenReadCommand = @'
set -eu
test "$(wc -c < /data/rmmirror/wake-token)" -eq 64
LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' /data/rmmirror/wake-token
cat /data/rmmirror/wake-token
'@.Replace("`r`n", "`n").Trim()
    $tokenResult = Invoke-CheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $tokenReadCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'Could not pair the tablet wake prerequisite'
    $wakeToken = $tokenResult.Stdout.Trim()
    if ($wakeToken -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'Tablet returned an invalid wake token.'
    }
    $wakeTokenPath = Set-PrivateTokenFile -Path $wakeTokenFile -Token $wakeToken

    # Setup completes entirely over the verified cable; no Wi-Fi network is
    # needed for the profile.
    $capabilityDiscoveryCommand = @'
set -eu
boot_id=$(cat /proc/sys/kernel/random/boot_id)
active_root=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
image_version=$(sed -n 's/^IMG_VERSION=//p' /etc/os-release | head -n 1 | tr -d '"')
os_build=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
kernel_release=$(uname -r)
companion_version=$(/usr/libexec/rmmirror-transport-wake --version)
usb_connection_policy=$(sed -n 's/.*"usb_connection_policy":"\([^"]*\)".*/\1/p' /run/rmmirror-transport-wake.json | head -n 1)
printf '%s\n' \
  "BOOT_ID=$boot_id" \
  "ACTIVE_ROOT=$active_root" \
  "IMAGE_VERSION=$image_version" \
  "OS_BUILD=$os_build" \
  "KERNEL_RELEASE=$kernel_release" \
  "COMPANION_VERSION=$companion_version" \
  "USB_CONNECTION_POLICY=$usb_connection_policy"
'@.Replace("`r`n", "`n").Trim()
    $capabilityDiscovery = Invoke-RedactedCheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $capabilityDiscoveryCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'Could not inspect the tablet capability state'
    $capabilityMetadata = ConvertFrom-StrictPairingOutput `
        -Text $capabilityDiscovery.Stdout `
        -ExpectedKeys @(
            'BOOT_ID',
            'ACTIVE_ROOT',
            'IMAGE_VERSION',
            'OS_BUILD',
            'KERNEL_RELEASE',
            'COMPANION_VERSION',
            'USB_CONNECTION_POLICY'
        )
    if ($capabilityMetadata['COMPANION_VERSION'] -cne
        $contractValues['RMMIRROR_TRANSPORT_VERSION'] -or
        $capabilityMetadata['USB_CONNECTION_POLICY'] -cne
        $contractValues['RMMIRROR_USB_CONNECTION_POLICY']) {
        throw 'Tablet transport capability does not match this Mirror build.'
    }

    $parsedBootId = [guid]::Empty
    if (-not [guid]::TryParseExact($capabilityMetadata['BOOT_ID'], 'D', [ref]$parsedBootId) -or
        $capabilityMetadata['ACTIVE_ROOT'] -cnotmatch '^/dev/[A-Za-z0-9._/-]{1,240}$' -or
        $capabilityMetadata['IMAGE_VERSION'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$' -or
        $capabilityMetadata['OS_BUILD'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$' -or
        $capabilityMetadata['KERNEL_RELEASE'] -cnotmatch '^[A-Za-z0-9._+-]{1,128}$' -or
        $capabilityMetadata['COMPANION_VERSION'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$') {
        throw 'Tablet capability metadata was malformed.'
    }

    # The pinned tablet identity sits in the dedicated known_hosts file that
    # every SSH call above just verified with StrictHostKeyChecking. Derive
    # the fingerprint from that key blob, the same way the app validates it.
    $pinnedHostKeyBlobs = @(
        foreach ($knownHostsLine in [System.IO.File]::ReadAllLines($knownHostsFull)) {
            $trimmedKnownHostsLine = $knownHostsLine.Trim()
            if ($trimmedKnownHostsLine.Length -eq 0 -or
                $trimmedKnownHostsLine.StartsWith('#')) {
                continue
            }
            $knownHostsFields = $trimmedKnownHostsLine -split '\s+'
            if ($knownHostsFields.Count -lt 3 -or
                $knownHostsFields[1] -cne 'ssh-ed25519') {
                continue
            }
            if ($knownHostsFields[0] -cne $sshHostKeyAlias -and
                $knownHostsFields[0] -cne "[$sshHostKeyAlias]:22") {
                continue
            }
            $knownHostsFields[2]
        }
    )
    if ($pinnedHostKeyBlobs.Count -ne 1) {
        throw 'Could not read the single pinned tablet SSH identity.'
    }
    $sshFingerprint = 'SHA256:' + [Convert]::ToBase64String(
        [System.Security.Cryptography.SHA256]::HashData(
            [Convert]::FromBase64String($pinnedHostKeyBlobs[0])
        )
    ).TrimEnd('=')

    $enableWifiSshCommand = @'
set -eu
rm-ssh-over-wlan on >/dev/null
# Some tablet software enables the socket without starting it.
systemctl start dropbear-wlan.socket
systemctl is-active --quiet dropbear-wlan.socket
'@.Replace("`r`n", "`n").Trim()
    Invoke-RedactedCheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $enableWifiSshCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'Could not enable the tablet Wi-Fi SSH prerequisite' | Out-Null

    # Keep a Wi-Fi pairing the app recorded earlier for this same pinned
    # tablet identity; a changed identity resets the profile to USB-only.
    $carriedWifiHost = ''
    $carriedWindowsInterfaceId = ''
    $carriedWindowsNetworkIdentity = ''
    $existingProfilePath = Join-Path (
        Join-Path (
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::LocalApplicationData,
                [Environment+SpecialFolderOption]::DoNotVerify
            )
        ) 'ReMarkableMirror'
    ) 'device-profile.json'
    if (Test-Path -LiteralPath $existingProfilePath -PathType Leaf) {
        try {
            $existingProfile = [System.IO.File]::ReadAllText($existingProfilePath) |
                ConvertFrom-Json -Depth 10
            if ($existingProfile.schema -ceq 'rmmirror.device-profile/v1' -and
                $existingProfile.sshFingerprint -ceq $sshFingerprint -and
                -not [string]::IsNullOrEmpty([string]$existingProfile.lastVerifiedWifiHost) -and
                -not [string]::IsNullOrEmpty([string]$existingProfile.pairedWindowsInterfaceId) -and
                -not [string]::IsNullOrEmpty([string]$existingProfile.pairedWindowsNetworkIdentity)) {
                $carriedWifiHost = [string]$existingProfile.lastVerifiedWifiHost
                $carriedWindowsInterfaceId = [string]$existingProfile.pairedWindowsInterfaceId
                $carriedWindowsNetworkIdentity = [string]$existingProfile.pairedWindowsNetworkIdentity
            }
        }
        catch {
        }
    }

    $deviceProfilePath = Set-PrivateDeviceProfile `
        -SshHostKeyAlias $sshHostKeyAlias `
        -SshFingerprint $sshFingerprint `
        -WifiHost $carriedWifiHost `
        -WindowsInterfaceId $carriedWindowsInterfaceId `
        -WindowsNetworkIdentity $carriedWindowsNetworkIdentity `
        -TokenFileReference $wakeTokenPath `
        -BootId $capabilityMetadata['BOOT_ID'] `
        -ActiveRoot $capabilityMetadata['ACTIVE_ROOT'] `
        -OsVersion (
            'IMG_VERSION={0};VERSION_ID={1}' -f @(
                $capabilityMetadata['IMAGE_VERSION'],
                $capabilityMetadata['OS_BUILD']
            )
        ) `
        -KernelRelease $capabilityMetadata['KERNEL_RELEASE'] `
        -WakeCapabilitySchema $wakeState.schema `
        -CompanionVersion $capabilityMetadata['COMPANION_VERSION']

    [pscustomobject]@{
        Schema = $contractValues['RMMIRROR_PREREQUISITES_SCHEMA']
        TabletAddress = $TabletAddress
        MirrorProbeSha256 = $assetHashes['rmmirror-probe']
        XoviRelease = $xoviRelease
        XoviArchiveSha256 = $assetHashes['xovi-aarch64.tar.gz']
        FilesLoopbackSha256 = $assetHashes['rmmirror-files-loopback.so']
        XoviBootStart = $false
        TransportWakeSha256 = $assetHashes['rmmirror-transport-wake']
        SystemSleepGuardSha256 = $assetHashes['rmmirror-usb-sleep-guard.conf']
        WakeService = 'active'
        WakeEndpointState = $wakeState.state
        WakeTokenFile = $wakeTokenPath
        WifiPairing = 'prepared_over_usb'
        DeviceProfileFile = $deviceProfilePath
        InputBootDependency = $false
    }
}
finally {
    if ($stageCreated) {
        try {
            Invoke-RemarkableExternalProcess `
                -FilePath $ssh `
                -Arguments ($sshOptions + @($remoteHost, "rm -rf '$remoteStage'")) `
                -TimeoutMilliseconds 15000 | Out-Null
        }
        catch {
        }
    }
}
