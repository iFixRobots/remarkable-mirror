[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror'
$inputSource = [System.Security.SecurityElement]::Escape(
    (Join-Path $sourceRoot 'SshInputSession.cs')
)
$routeSource = [System.Security.SecurityElement]::Escape(
    (Join-Path $sourceRoot 'SshRoute.cs')
)
$jobSource = [System.Security.SecurityElement]::Escape(
    (Join-Path $sourceRoot 'SshChildProcessJob.cs')
)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-input-route-policy-' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $temporaryRoot 'InputRoutePolicy.csproj'
$programPath = Join-Path $temporaryRoot 'Program.cs'

$project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$inputSource" Link="SshInputSession.cs" />
    <Compile Include="$routeSource" Link="SshRoute.cs" />
    <Compile Include="$jobSource" Link="SshChildProcessJob.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@

$program = @'
namespace ReMarkableMirror;

internal static class Program
{
    private const string ExistingCommand =
        "/home/root/.local/bin/rmmirror-probe input --heartbeat-timeout 15s";

    public static int Main()
    {
        Require(SshInputSession.CreateRemoteCommand(enableFilesFallback: false) == ExistingCommand);
        Require(
            SshInputSession.CreateRemoteCommand(enableFilesFallback: true) ==
            ExistingCommand + " --files-fallback");
        Require(
            new SshRoute("192.0.2.53", filesTargetHost: "127.0.0.1")
                .CreateFilesForwardArgument(43123) ==
            "127.0.0.1:43123:127.0.0.1:80");
        Console.WriteLine("Result: PASS");
        Console.WriteLine("USB command unchanged: PASS");
        Console.WriteLine("Legacy Files fallback command remains parseable: PASS");
        Console.WriteLine("Files tunnel targets tablet loopback: PASS");
        return 0;
    }

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new InvalidOperationException("An input route-policy invariant failed.");
        }
    }
}
'@

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    [System.IO.File]::WriteAllText(
        $projectPath,
        $project,
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
        $programPath,
        $program,
        [System.Text.UTF8Encoding]::new($false))
    & dotnet run --project $projectPath -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "Input route-policy validation failed with exit code $LASTEXITCODE."
    }

    $mainPage = Get-Content -LiteralPath (
        Join-Path $sourceRoot 'MainPage.xaml.cs'
    ) -Raw
    $loopbackBridgeConnect = [regex]::new(
        'SshInputSession\.ConnectAsync\(\s*generation\.Route,\s*' +
        'enableFilesFallback:\s*false,\s*routeToken\)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $loopbackBridgeConnect.IsMatch($mainPage)) {
        throw 'MainPage still requests the legacy fake-interface Files fallback.'
    }
    if ($mainPage -notmatch 'filesLoopbackHost\s*=\s*"127\.0\.0\.1"') {
        throw 'MainPage does not route tablet Files through Xovi loopback.'
    }
    Write-Host 'Xovi loopback Files route: PASS'

    $immediateActivity = [regex]::new(
        'candidate = await SshInputSession\.ConnectAsync\(.*?' +
        'await candidate\.WakeIfDeepSleepingAsync\(routeToken\).*?' +
        'await candidate\.NotifyActivityAsync\(routeToken\).*?' +
        '_inputSession = candidate',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $immediateActivity.IsMatch($mainPage)) {
        throw 'Wi-Fi input publication does not send tablet activity before publishing controls.'
    }
    Write-Host 'Immediate tablet activity before publication: PASS'

    if ($mainPage -notmatch
            'WifiInputActivityInterval\s*=\s*TimeSpan\.FromSeconds\(10\)' -or
        $mainPage -notmatch
            'UsbInputActivityInterval\s*=\s*TimeSpan\.FromSeconds\(45\)' -or
        $mainPage -notmatch
            'generation\.Kind is DeviceRouteKind\.Wifi\s*\?\s*' +
            'WifiInputActivityInterval\s*:\s*UsbInputActivityInterval') {
        throw 'The input activity cadence is not bounded below the observed Wi-Fi idle loss.'
    }
    Write-Host 'Route-specific activity cadence: PASS'

    $usbFilesProbe = [regex]::new(
        'if \(next\.Kind is DeviceRouteKind\.Usb\)\s*\{\s*' +
        '_ = ProbeFilesRouteAsync\(next\);\s*\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $usbFilesProbe.IsMatch($mainPage)) {
        throw 'USB Files probing no longer begins with route publication.'
    }

    $wifiFilesProbe = [regex]::new(
        '_inputSession = candidate;.*?' +
        'if \(generation\.Kind is DeviceRouteKind\.Wifi\)\s*\{\s*' +
        '_ = ProbeFilesRouteAsync\(generation\);\s*\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $wifiFilesProbe.IsMatch($mainPage)) {
        throw 'Wi-Fi Files probing does not begin after same-generation input publication.'
    }
    Write-Host 'Files probe publication order: PASS'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
