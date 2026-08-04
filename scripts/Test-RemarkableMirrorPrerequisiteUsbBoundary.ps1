#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installerPath = Join-Path $repositoryRoot 'scripts\Install-RemarkableMirrorPrerequisites.ps1'
$installerText = [System.IO.File]::ReadAllText($installerPath)
$wakeServicePath = Join-Path $repositoryRoot 'mirror\agent\deploy\rmmirror-transport-wake.service'
$wakeServiceText = [System.IO.File]::ReadAllText($wakeServicePath)
$tokens = $null
$errors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    throw 'The prerequisite installer did not parse.'
}

$tabletAddressParameter = @(
    $installerAst.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -ceq 'TabletAddress' }
)
if ($tabletAddressParameter.Count -ne 1 -or
    $tabletAddressParameter[0].Extent.Text -cnotmatch
        "(?s)ValidateSet\s*\(\s*'10\.11\.99\.1'\s*\)") {
    throw 'TabletAddress is not constrained to the fixed USB tablet target.'
}

$routeFunction = $installerAst.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-DirectUsbTabletRoute'
    },
    $true
)
if ($null -eq $routeFunction) {
    throw 'The installer is missing the direct USB route preflight.'
}
. ([scriptblock]::Create($routeFunction.Extent.Text))

$script:usbFixture = @{}
function Reset-UsbFixture {
    $script:usbFixture = @{
        Address = [pscustomobject]@{
            IPAddress = '10.11.99.11'
            PrefixLength = 27
            InterfaceIndex = 23
            InterfaceAlias = 'USB Tablet'
            AddressState = 'Preferred'
            SkipAsSource = $false
        }
        Adapter = [pscustomobject]@{
            InterfaceIndex = 23
            InterfaceAlias = 'USB Tablet'
            Status = 'Up'
            HardwareInterface = $true
            Virtual = $false
            PnPDeviceID = 'USB\VID_04B3&PID_4010\0'
            InterfaceName = 'ethernet_test_usb'
        }
        RouteSource = [pscustomobject]@{
            IPAddress = '10.11.99.11'
            PrefixLength = 27
            InterfaceIndex = 23
            InterfaceAlias = 'USB Tablet'
        }
        Route = [pscustomobject]@{
            DestinationPrefix = '10.11.99.0/27'
            InterfaceIndex = 23
            InterfaceAlias = 'USB Tablet'
            NextHop = '0.0.0.0'
            State = 'Alive'
        }
    }
}

function Get-NetIPAddress {
    [CmdletBinding()]
    param(
        [string]$IPAddress,
        [string]$AddressFamily
    )
    $script:usbFixture.Address
}

function Get-NetAdapter {
    [CmdletBinding()]
    param([int]$InterfaceIndex)
    $script:usbFixture.Adapter
}

function Find-NetRoute {
    [CmdletBinding()]
    param(
        [string]$RemoteIPAddress,
        [string]$LocalIPAddress
    )
    $script:usbFixture.RouteSource
    $script:usbFixture.Route
}

function Assert-UsbRouteRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Arrange,
        [Parameter(Mandatory)][string]$Name
    )

    Reset-UsbFixture
    & $Arrange
    try {
        Get-DirectUsbTabletRoute | Out-Null
        throw "USB route preflight accepted $Name."
    }
    catch {
        if ($_.Exception.Message -ceq "USB route preflight accepted $Name.") {
            throw
        }
    }
}

Reset-UsbFixture
$route = Get-DirectUsbTabletRoute
if ($route.InterfaceIndex -ne 23 -or
    $route.InterfaceAlias -cne 'USB Tablet' -or
    $route.SourceAddress -cne '10.11.99.11') {
    throw 'The valid direct USB route did not round-trip exactly.'
}

Assert-UsbRouteRejected -Name 'a non-USB adapter' -Arrange {
    $script:usbFixture.Adapter.PnPDeviceID = 'PCI\VEN_1234'
}
Assert-UsbRouteRejected -Name 'the wrong host prefix' -Arrange {
    $script:usbFixture.Address.PrefixLength = 24
}
Assert-UsbRouteRejected -Name 'a non-preferred source address' -Arrange {
    $script:usbFixture.Address.AddressState = 'Tentative'
}
Assert-UsbRouteRejected -Name 'a route on another interface' -Arrange {
    $script:usbFixture.Route.InterfaceIndex = 42
}
Assert-UsbRouteRejected -Name 'a routed next hop' -Arrange {
    $script:usbFixture.Route.NextHop = '10.11.99.30'
}
Assert-UsbRouteRejected -Name 'a route outside the USB /27' -Arrange {
    $script:usbFixture.Route.DestinationPrefix = '0.0.0.0/0'
}

$preflightIndex = $installerText.IndexOf('$usbRoute = Get-DirectUsbTabletRoute')
$firstMutationIndex = $installerText.IndexOf('umask 077; mkdir $remoteStage')
$tokenReadIndex = $installerText.IndexOf('$tokenResult = Invoke-CheckedExternalProcess')
if ($preflightIndex -lt 0 -or
    $firstMutationIndex -le $preflightIndex -or
    $tokenReadIndex -le $preflightIndex) {
    throw 'The USB trust preflight does not precede tablet mutation and token read.'
}

foreach ($requiredMarker in @(
        '$remoteHost = "root@$usbTabletAddress"',
        'BindAddress=$usbHostAddress',
        'BindInterface=`"$($usbRoute.InterfaceAlias)`"',
        'GET /v1/status HTTP/1.1\r\n',
        'busybox nc 127.0.0.1 51337',
        "'-F', 'NUL'",
        "'GlobalKnownHostsFile=NUL'"
    )) {
    if (-not $installerText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "The installer is missing USB boundary marker: $requiredMarker"
    }
}

foreach ($forbiddenMarker in @(
        'root@$TabletAddress',
        'http://${TabletAddress}:51337',
        '[System.Net.Http.HttpClientHandler]'
    )) {
    if ($installerText.Contains($forbiddenMarker, [StringComparison]::Ordinal)) {
        throw "The installer retains an unsafe target path: $forbiddenMarker"
    }
}

foreach ($requiredMarker in @(
        "grep -c '^127[.]0[.]0[.]1:51337",
        "grep -c '^10[.]11[.]99[.]1:51337",
        "grep -c ':51337"
    )) {
    if (-not $installerText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "The installer does not verify the exact wake listeners: $requiredMarker"
    }
}

foreach ($requiredMarker in @(
        '--wake-listen 127.0.0.1:51337',
        '--wake-listen 10.11.99.1:51337'
    )) {
    if (-not $wakeServiceText.Contains($requiredMarker, [StringComparison]::Ordinal)) {
        throw "The wake service is missing a private listener: $requiredMarker"
    }
}
if ($wakeServiceText.Contains('--wake-listen 0.0.0.0:51337', [StringComparison]::Ordinal)) {
    throw 'The wake service still exposes its endpoint on every tablet interface.'
}

Write-Host 'PASS: prerequisite installer and wake endpoint are pinned to USB and tablet loopback.'
