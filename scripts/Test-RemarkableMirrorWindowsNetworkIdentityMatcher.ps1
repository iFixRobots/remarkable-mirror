[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\WindowsNetworkIdentityMatcher.cs'
$source = [System.IO.File]::ReadAllText($sourcePath)

if (-not $source.Contains('FileName = "powershell.exe"', [StringComparison]::Ordinal)) {
    throw 'The matcher no longer declares Windows PowerShell as its probe runtime.'
}

$assignmentMatch = [regex]::Match(
    $source,
    '(?m)^\s*\$networkIdentity = (?<expression>.+)$'
)
if (-not $assignmentMatch.Success) {
    throw 'The matcher network-identity expression could not be extracted.'
}

$identityExpression = $assignmentMatch.Groups['expression'].Value.Trim()
$probeScript = @"
`$ErrorActionPreference = 'Stop'
`$identityHash = [byte[]](0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
`$networkIdentity = $identityExpression
[Console]::Out.WriteLine(`$networkIdentity)
"@
$encodedProbe = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($probeScript)
)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'powershell.exe'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        $encodedProbe
    )) {
    [void]$startInfo.ArgumentList.Add($argument)
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) {
        throw 'Windows PowerShell compatibility probe did not start.'
    }
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) {
        $process.Kill($true)
        throw 'Windows PowerShell compatibility probe timed out.'
    }

    $output = $standardOutput.GetAwaiter().GetResult().Trim()
    [void]$standardError.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "The matcher identity expression is incompatible with Windows PowerShell 5.1 (exit $($process.ExitCode))."
    }
    if ($output -cne 'sha256:000102030405060708090a0b0c0d0e0f') {
        throw 'The matcher identity expression returned the wrong lowercase hex value.'
    }
}
finally {
    $process.Dispose()
}

Write-Host 'PASS: network identity hashing works in Windows PowerShell 5.1.'
