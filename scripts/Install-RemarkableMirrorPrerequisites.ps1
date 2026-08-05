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
    [string]$FilesLoopbackExtension
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\RemarkableRmctlCapture.ps1')

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runToken = [guid]::NewGuid().ToString('N')
$buildDirectory = Join-Path $repositoryRoot "tmp\mirror\transport-wake-$runToken"
$remoteStage = "/home/root/.rmmirror-transport-stage-$runToken"
$usbTabletAddress = '10.11.99.1'
$usbHostAddress = '10.11.99.11'
$usbPrefixLength = 27
$stageCreated = $false
$wakeTokenFile = Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_wake_token'
$sshHostKeyAlias = '10.11.99.1'
$xoviRelease = 'v19-23052026'
$xoviArchiveHashExpected = '32d64d1262ddc984e3235c7d0340a398fe6d5b3efa6a979865f5977b32630d27'
$mirrorProbeVersion = '0.4.8'

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

$releaseComponentDirectory = Join-Path $PSScriptRoot 'components'
$releaseBinary = Join-Path $releaseComponentDirectory 'rmmirror-transport-wake'
$releaseProbe = Join-Path $releaseComponentDirectory 'rmmirror-probe'
$releaseXoviArchive = Join-Path $releaseComponentDirectory 'xovi-aarch64.tar.gz'
$releaseUnit = Join-Path $releaseComponentDirectory 'rmmirror-transport-wake.service'
$releaseInstaller = Join-Path $releaseComponentDirectory 'install-transport-wake.sh'
$releaseSleepGuard = Join-Path $releaseComponentDirectory 'rmmirror-usb-sleep-guard.conf'
$releaseFilesLoopback = Join-Path $releaseComponentDirectory 'rmmirror-files-loopback.so'

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
$unitFull = [System.IO.Path]::GetFullPath($unitSource)
$installerFull = [System.IO.Path]::GetFullPath($installerSource)
$sleepGuardFull = [System.IO.Path]::GetFullPath($sleepGuardSource)
foreach ($assetPath in @(
        $binaryFull,
        $probeFull,
        $xoviArchiveFull,
        $filesLoopbackFull,
        $unitFull,
        $installerFull,
        $sleepGuardFull
    )) {
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Required tablet prerequisite asset does not exist: $assetPath"
    }
    $item = Get-Item -LiteralPath $assetPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Tablet prerequisite assets must not be symbolic links: $assetPath"
    }
}

$filesLoopbackBytes = [System.IO.File]::ReadAllBytes($filesLoopbackFull)
if ($filesLoopbackBytes.Length -lt 64 -or
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
}

$ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
$scp = (Get-Command scp.exe -ErrorAction Stop).Source
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
    '-o', "BindInterface=`"$($usbRoute.InterfaceAlias)`"",
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

    if ($Item -is [System.IO.DirectoryInfo]) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($sid)
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
    }
    else {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        )
    }
    Set-Acl -LiteralPath $Item.FullName -AclObject $acl
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
        [Parameter(Mandatory)][string]$WifiHost,
        [Parameter(Mandatory)][string]$WindowsInterfaceId,
        [Parameter(Mandatory)][string]$WindowsNetworkIdentity,
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

function Get-PairedWindowsNetworkIdentity {
    param(
        [Parameter(Mandatory)][string]$RemoteAddress
    )

    try {
        $routeResult = @(Find-NetRoute -RemoteIPAddress $RemoteAddress -ErrorAction Stop)
        $interfaceIndexes = @(
            $routeResult |
                ForEach-Object { [int]$_.InterfaceIndex } |
                Sort-Object -Unique
        )
        if ($interfaceIndexes.Count -ne 1) {
            throw 'ambiguous route'
        }

        $adapter = Get-NetAdapter -InterfaceIndex $interfaceIndexes[0] -ErrorAction Stop
        $interfaceGuid = ([guid]$adapter.InterfaceGuid).ToString('B').ToUpperInvariant()
        $connectionProfiles = @(Get-NetConnectionProfile `
            -InterfaceIndex $interfaceIndexes[0] `
            -ErrorAction Stop)
        if ($connectionProfiles.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace($connectionProfiles[0].Name)) {
            throw 'missing network profile'
        }

        $identityMaterial = "{0}`n{1}" -f @(
            $connectionProfiles[0].Name,
            $connectionProfiles[0].NetworkCategory
        )
        $identityHash = [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($identityMaterial)
        )
        [pscustomobject]@{
            InterfaceId = $interfaceGuid
            NetworkIdentity = 'sha256:' +
                [Convert]::ToHexString($identityHash).ToLowerInvariant()
        }
    }
    catch {
        throw 'Could not pair the Windows network interface for this tablet.'
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
    $create = Invoke-CheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, "umask 077; mkdir $remoteStage")) `
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
            @{ Local = $sleepGuardFull; Remote = 'rmmirror-usb-sleep-guard.conf' }
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
test "`$(sha256sum "`$stage/rmmirror-transport-wake" | cut -d' ' -f1)" = '$($assetHashes['rmmirror-transport-wake'])'
test "`$(sha256sum "`$stage/rmmirror-transport-wake.service" | cut -d' ' -f1)" = '$($assetHashes['rmmirror-transport-wake.service'])'
test "`$(sha256sum "`$stage/install-transport-wake.sh" | cut -d' ' -f1)" = '$($assetHashes['install-transport-wake.sh'])'
test "`$(sha256sum "`$stage/rmmirror-usb-sleep-guard.conf" | cut -d' ' -f1)" = '$($assetHashes['rmmirror-usb-sleep-guard.conf'])'
test "`$(sha256sum "`$stage/rmmirror-probe" | cut -d' ' -f1)" = '$($assetHashes['rmmirror-probe'])'
test "`$(sha256sum "`$stage/xovi-aarch64.tar.gz" | cut -d' ' -f1)" = '$($assetHashes['xovi-aarch64.tar.gz'])'
test "`$(sha256sum "`$stage/rmmirror-files-loopback.so" | cut -d' ' -f1)" = '$($assetHashes['rmmirror-files-loopback.so'])'
test -c /dev/uinput
test -c /dev/input/event2
test "`$(cat /sys/class/input/event2/device/name)" = 'Elan marker input'

mkdir "`$stage/xovi-unpack"
tar -xzf "`$stage/xovi-aarch64.tar.gz" -C "`$stage/xovi-unpack"
pinned_xovi="`$stage/xovi-unpack/xovi"
test -x "`$pinned_xovi/start"
test -x "`$pinned_xovi/stock"
test -f "`$pinned_xovi/xovi.so"
test -f "`$pinned_xovi/inactive-extensions/framebuffer-spy.so"
test -f "`$pinned_xovi/inactive-extensions/xovi-message-broker.so"
if test ! -e /home/root/xovi; then
  printf '%s\n' '$xoviRelease' > "`$pinned_xovi/.rmmirror-version"
  mv "`$pinned_xovi" /home/root/xovi
else
  if ! test -f /home/root/xovi/.rmmirror-version ||
      ! test "`$(cat /home/root/xovi/.rmmirror-version)" = '$xoviRelease'; then
    printf '%s\n' 'rmmirror-prerequisite: xovi_version_mismatch' >&2
    exit 44
  fi
  for asset in \
    xovi.so \
    start \
    stock \
    inactive-extensions/framebuffer-spy.so \
    inactive-extensions/xovi-message-broker.so
  do
    if ! cmp -s "`$pinned_xovi/`$asset" "/home/root/xovi/`$asset"; then
      printf '%s\n' "rmmirror-prerequisite: xovi_asset_mismatch:`$asset" >&2
      exit 45
    fi
  done
fi
test -x /home/root/xovi/start
test -f /home/root/xovi/inactive-extensions/framebuffer-spy.so
test -f /home/root/xovi/inactive-extensions/xovi-message-broker.so
mkdir -p \
  /home/root/xovi/extensions.d \
  /home/root/xovi/inactive-extensions \
  /home/root/xovi/services/xochitl.service
for retired_extension in qt-resource-rebuilder.so webserver-remote.so; do
  if test -f "/home/root/xovi/extensions.d/`$retired_extension"; then
    mv -f \
      "/home/root/xovi/extensions.d/`$retired_extension" \
      "/home/root/xovi/inactive-extensions/`$retired_extension"
  fi
done
rm -f \
  /home/root/xovi/services/xochitl.service/qt-resource-rebuilder.conf \
  /home/root/xovi/services/xochitl.service/99-rmmirror-activation-guard.conf \
  /home/root/xovi/services/xochitl.service/zz-rmmirror-activation-guard.conf
cp "`$stage/rmmirror-files-loopback.so" /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new
chmod 0755 /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new
mv -f /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so.new /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so
cmp -s "`$stage/rmmirror-files-loopback.so" /home/root/xovi/inactive-extensions/rmmirror-files-loopback.so
publish_extension() {
  extension_name="`$1"
  source_path="/home/root/xovi/inactive-extensions/`$extension_name"
  target_path="/home/root/xovi/extensions.d/`$extension_name"
  if test -f "`$target_path" && cmp -s "`$source_path" "`$target_path"; then
    chmod 0755 "`$target_path"
    return 0
  fi
  cp "`$source_path" "`$target_path.new"
  chmod 0755 "`$target_path.new"
  mv -f "`$target_path.new" "`$target_path"
}
publish_extension framebuffer-spy.so
publish_extension xovi-message-broker.so
publish_extension rmmirror-files-loopback.so

mkdir -p /home/root/.local/bin
cp "`$stage/rmmirror-probe" /home/root/.local/bin/rmmirror-probe.new
chmod 0700 /home/root/.local/bin/rmmirror-probe.new
mv -f /home/root/.local/bin/rmmirror-probe.new /home/root/.local/bin/rmmirror-probe
test "`$(sha256sum /home/root/.local/bin/rmmirror-probe | cut -d' ' -f1)" = '$($assetHashes['rmmirror-probe'])'
test "`$(/home/root/.local/bin/rmmirror-probe version)" = '$mirrorProbeVersion'

chmod 0700 "`$stage/install-transport-wake.sh"
"`$stage/install-transport-wake.sh" install
systemctl is-active --quiet rmmirror-transport-wake.service
systemctl is-enabled --quiet rmmirror-transport-wake.service
grep -q '"schema":"rmmirror.transport-wake/v1"' /run/rmmirror-transport-wake.json
grep -q '"state":"holding"' /run/rmmirror-transport-wake.json
grep -q '"usb_carrier":true' /run/rmmirror-transport-wake.json
grep -q '"wake_lock_active":true' /run/rmmirror-transport-wake.json
grep -q '"system_sleep_blocked":true' /run/rmmirror-transport-wake.json
grep -q '"wake_endpoint_healthy":true' /run/rmmirror-transport-wake.json
listener_addresses=`$(netstat -lnt 2>/dev/null | awk '`$4 ~ /:51337`$/ { print `$4 }')
test "`$(printf '%s\n' "`$listener_addresses" | grep -c '^127[.]0[.]0[.]1:51337`$')" -eq 1
test "`$(printf '%s\n' "`$listener_addresses" | grep -c '^10[.]11[.]99[.]1:51337`$')" -eq 1
test "`$(printf '%s\n' "`$listener_addresses" | grep -c ':51337`$')" -eq 2
case ",`$(awk '`$2 == "/" { print `$4; exit }' /proc/mounts)," in
  *,ro,*) ;;
  *) exit 1 ;;
esac
printf '%s\n' 'RMMIRROR_PREREQUISITES=installed'
"@).Replace("`r`n", "`n").Trim()
    $install = Invoke-CheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $installCommand)) `
        -TimeoutMilliseconds 60000 `
        -FailureMessage 'Could not install the Mirror tablet prerequisites'
    if ($install.Stdout -notmatch '(?m)^RMMIRROR_PREREQUISITES=installed\r?$') {
        throw 'Tablet prerequisite install did not return its completion marker.'
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

    $wifiPairingStatus = 'reconnect_required'
    $deviceProfilePath = $null
    $wifiDiscoveryCommand = @'
set -eu
saved_count=$(nmcli -t -f TYPE connection show 2>/dev/null | awk -F: '$1 == "802-11-wireless" || $1 == "wifi" { count++ } END { print count + 0 }')
active_count=$(nmcli -t -f TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '($1 == "802-11-wireless" || $1 == "wifi") && $2 == "wlan0" { count++ } END { print count + 0 }')
wifi_host=$(ip -4 -o address show dev wlan0 scope global 2>/dev/null | awk 'NR == 1 { split($4, address, "/"); print address[1] }')
printf '%s\n' \
  "SAVED_COUNT=$saved_count" \
  "ACTIVE_COUNT=$active_count" \
  "WIFI_HOST=$wifi_host"
'@.Replace("`r`n", "`n").Trim()
    $wifiDiscovery = Invoke-RedactedCheckedExternalProcess `
        -FilePath $ssh `
        -Arguments ($sshOptions + @($remoteHost, $wifiDiscoveryCommand)) `
        -TimeoutMilliseconds 15000 `
        -FailureMessage 'Could not inspect the tablet Wi-Fi pairing state'
    $wifiMetadata = ConvertFrom-StrictPairingOutput `
        -Text $wifiDiscovery.Stdout `
        -ExpectedKeys @(
            'SAVED_COUNT',
            'ACTIVE_COUNT',
            'WIFI_HOST'
        )

    $parsedWifiAddress = $null
    $hasConnectedWifiAddress =
        [System.Net.IPAddress]::TryParse($wifiMetadata['WIFI_HOST'], [ref]$parsedWifiAddress) -and
        $parsedWifiAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    if ($wifiMetadata['SAVED_COUNT'] -cnotmatch '^\d+$' -or
        $wifiMetadata['ACTIVE_COUNT'] -cnotmatch '^\d+$') {
        throw 'Tablet Wi-Fi pairing state was malformed.'
    }

    if ([int]$wifiMetadata['SAVED_COUNT'] -eq 0 -or
        [int]$wifiMetadata['ACTIVE_COUNT'] -eq 0 -or
        -not $hasConnectedWifiAddress) {
        Write-Warning (
            'Wi-Fi pairing paused. A Developer Mode factory reset erases the tablet''s saved ' +
            'Wi-Fi credentials, and wlan0 is not connected with an IPv4 address. On the tablet, ' +
            'open Settings > Wi-Fi, reconnect to your network, wait until it says Connected, ' +
            'then run this installer again. The USB Mirror prerequisites remain installed.'
        )
    }
    else {
        $capabilityDiscoveryCommand = @'
set -eu
boot_id=$(cat /proc/sys/kernel/random/boot_id)
active_root=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
image_version=$(sed -n 's/^IMG_VERSION=//p' /etc/os-release | head -n 1 | tr -d '"')
os_build=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '"')
kernel_release=$(uname -r)
companion_version=$(/usr/libexec/rmmirror-transport-wake --version)
printf '%s\n' \
  "BOOT_ID=$boot_id" \
  "ACTIVE_ROOT=$active_root" \
  "IMAGE_VERSION=$image_version" \
  "OS_BUILD=$os_build" \
  "KERNEL_RELEASE=$kernel_release" \
  "COMPANION_VERSION=$companion_version"
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
                'COMPANION_VERSION'
            )

        $parsedBootId = [guid]::Empty
        if (-not [guid]::TryParseExact($capabilityMetadata['BOOT_ID'], 'D', [ref]$parsedBootId) -or
            $capabilityMetadata['ACTIVE_ROOT'] -cnotmatch '^/dev/[A-Za-z0-9._/-]{1,240}$' -or
            $capabilityMetadata['IMAGE_VERSION'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$' -or
            $capabilityMetadata['OS_BUILD'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$' -or
            $capabilityMetadata['KERNEL_RELEASE'] -cnotmatch '^[A-Za-z0-9._+-]{1,128}$' -or
            $capabilityMetadata['COMPANION_VERSION'] -cnotmatch '^[A-Za-z0-9._+-]{1,64}$') {
            throw 'Tablet capability metadata was malformed.'
        }

        $enableWifiSshCommand = @'
set -eu
rm-ssh-over-wlan on >/dev/null
systemctl is-active --quiet dropbear-wlan.socket
'@.Replace("`r`n", "`n").Trim()
        Invoke-RedactedCheckedExternalProcess `
            -FilePath $ssh `
            -Arguments ($sshOptions + @($remoteHost, $enableWifiSshCommand)) `
            -TimeoutMilliseconds 15000 `
            -FailureMessage 'Could not enable the tablet Wi-Fi SSH prerequisite' | Out-Null

        $windowsPairing = Get-PairedWindowsNetworkIdentity `
            -RemoteAddress $wifiMetadata['WIFI_HOST']
        $wifiSshOptions = @(
            '-F', 'NUL',
            '-i', $identityFull,
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'StrictHostKeyChecking=yes',
            '-o', "UserKnownHostsFile=$knownHostsFull",
            '-o', 'GlobalKnownHostsFile=NUL',
            '-o', "HostKeyAlias=$sshHostKeyAlias",
            '-o', 'UpdateHostKeys=no',
            '-o', 'CheckHostIP=no',
            '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=5',
            '-o', 'ServerAliveCountMax=2'
        )
        $wifiVerificationCommand = (@"
set -eu
test "`$(cat /proc/sys/kernel/random/boot_id)" = '$($capabilityMetadata['BOOT_ID'])'
test "`$(/usr/libexec/rmmirror-transport-wake --version)" = '$($capabilityMetadata['COMPANION_VERSION'])'
printf '%s\n' 'RMMIRROR_WIFI=verified'
"@).Replace("`r`n", "`n").Trim()
        $wifiVerification = Invoke-RedactedCheckedExternalProcess `
            -FilePath $ssh `
            -Arguments ($wifiSshOptions + @(
                '-v',
                "root@$($wifiMetadata['WIFI_HOST'])",
                $wifiVerificationCommand
            )) `
            -TimeoutMilliseconds 15000 `
            -FailureMessage 'Could not verify the paired tablet identity over Wi-Fi'
        if ($wifiVerification.Stdout -notmatch '(?m)^RMMIRROR_WIFI=verified\r?$') {
            throw 'Wi-Fi SSH did not return its verification marker.'
        }

        $fingerprintMatches = @(
            [regex]::Matches(
                $wifiVerification.Stderr,
                'Server host key:\s+\S+\s+(SHA256:[A-Za-z0-9+/]{43})'
            ) |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )
        if ($fingerprintMatches.Count -ne 1) {
            throw 'Could not capture the verified tablet SSH fingerprint.'
        }

        $deviceProfilePath = Set-PrivateDeviceProfile `
            -SshHostKeyAlias $sshHostKeyAlias `
            -SshFingerprint $fingerprintMatches[0] `
            -WifiHost $wifiMetadata['WIFI_HOST'] `
            -WindowsInterfaceId $windowsPairing.InterfaceId `
            -WindowsNetworkIdentity $windowsPairing.NetworkIdentity `
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
        $wifiPairingStatus = 'verified'
    }

    [pscustomobject]@{
        Schema = 'rmmirror.prerequisites/v1'
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
        WifiPairing = $wifiPairingStatus
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
