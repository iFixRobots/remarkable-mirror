[CmdletBinding()]
param(
    [string]$TabletAddress,
    [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\remarkable_chiappa_ed25519'),
    [string]$KnownHostsFile = (Join-Path $env:USERPROFILE '.ssh\remarkable_known_hosts'),
    [string]$RemoteCandidate = '/tmp/rmmirror-probe-wifi-files',
    [ValidateRange(0, 30)]
    [int]$HoldSeconds = 0,
    [ValidateRange(1, 10)]
    [int]$ActivityIntervalSeconds = 4,
    [ValidateRange(1, 180)]
    [int]$FilesReadyWaitSeconds = 120,
    [switch]$ImmediateActivityBeforeFilesCheck,
    [switch]$RequireFilesStateReady
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TabletAddress)) {
    $profilePath = Join-Path $env:LOCALAPPDATA 'ReMarkableMirror\device-profile.json'
    $TabletAddress = (
        Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    ).lastVerifiedWifiHost
}
if ($RemoteCandidate -notmatch '^/tmp/[A-Za-z0-9._-]+$' -and
    $RemoteCandidate -cne '/home/root/.local/bin/rmmirror-probe') {
    throw 'RemoteCandidate must be the installed probe or one simple absolute path under /tmp.'
}

$sshArguments = @(
    '-F', 'NUL',
    '-i', $IdentityFile,
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'HostKeyAlgorithms=ssh-ed25519',
    '-o', "UserKnownHostsFile=$KnownHostsFile",
    '-o', 'GlobalKnownHostsFile=NUL',
    '-o', 'HostKeyAlias=10.11.99.1',
    '-o', 'UpdateHostKeys=no',
    '-o', 'ConnectTimeout=3',
    '-o', 'ConnectionAttempts=1'
)
$target = "root@$TabletAddress"

function Invoke-TabletCommand {
    param([Parameter(Mandatory)][string]$Command)

    & ssh.exe @sshArguments $target $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Tablet command failed with exit code $LASTEXITCODE."
    }
}

function Test-TabletCommand {
    param([Parameter(Mandatory)][string]$Command)

    $null = & ssh.exe @sshArguments $target $Command 2>$null
    return $LASTEXITCODE -eq 0
}

function Send-InputWakeActivity {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [int]$CommandId,
        [Parameter(Mandatory)]
        [string]$Purpose,
        [ValidateSet('KEY_F12', 'KEY_WAKEUP')]
        [string]$Key = 'KEY_F12'
    )

    # KEY_WAKEUP asks Linux/Xochitl to leave sleep without the toggle semantics
    # of KEY_POWER. KEY_F12 is the non-visible activity signal the app uses to
    # keep Xochitl out of deep sleep while a Wi-Fi Mirror session is active.
    $command = @{
        id = $CommandId
        type = 'key'
        action = 'click'
        key = $Key
    } | ConvertTo-Json -Compress
    $Process.StandardInput.WriteLine($command)
    $Process.StandardInput.Flush()
    $responseLine = $Process.StandardOutput.ReadLineAsync().WaitAsync(
        [TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
    $response = $responseLine | ConvertFrom-Json
    if (-not $response.ok -or $response.id -ne $CommandId) {
        throw "Candidate input session rejected its $Purpose wake activity."
    }
}

$activeRuntimeCheck = @'
set -eu
test "$(cat /run/rmmirror-files-fallback.owner)" = "rmmirror.files-fallback/v2"
ip -o -4 address show dev usb1 | grep -q "10.11.99.1/32"
test ! -e /run/systemd/system/xochitl.service.d/90-rmmirror-wifi-files.conf
test ! -e /run/rmmirror-files/xochitl
systemctl is-active --quiet xochitl.service
pid="$(systemctl show -p MainPID --value xochitl.service)"
test "$pid" -gt 0
test "$(readlink -f "/proc/$pid/exe")" = "/usr/bin/xochitl"
printf 'fallback_stock_runtime_ok\n'
'@

$filesHttpCheck = @'
wget -q -T 2 -O /dev/null http://10.11.99.1/documents/ 2>/dev/null
'@

$activeCheck = $activeRuntimeCheck + "`n" + $filesHttpCheck + "`nprintf 'fallback_http_ok\n'`n"

$cleanupCheck = @'
set -eu
test ! -e /run/rmmirror-files-fallback.owner
! ip -o -4 address show dev usb1 | grep -q "10.11.99.1/32"
test ! -e /run/systemd/system/xochitl.service.d/90-rmmirror-wifi-files.conf
test ! -e /run/rmmirror-files/xochitl
systemctl is-active --quiet xochitl.service
pid="$(systemctl show -p MainPID --value xochitl.service)"
test "$pid" -gt 0
test "$(readlink -f "/proc/$pid/exe")" = "/usr/bin/xochitl"
__CANDIDATE__ input-ready --restore-timeout 20s >/dev/null
printf 'cleanup_ok\n'
'@
$cleanupCheck = $cleanupCheck.Replace('__CANDIDATE__', $RemoteCandidate)

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'ssh.exe'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in $sshArguments) {
    [void]$startInfo.ArgumentList.Add($argument)
}
[void]$startInfo.ArgumentList.Add($target)
[void]$startInfo.ArgumentList.Add(
    "$RemoteCandidate input --heartbeat-timeout 60s --files-fallback")

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$started = $false
$primaryError = $null
$cleanupErrors = [System.Collections.Generic.List[System.Exception]]::new()
try {
    if (-not $process.Start()) {
        throw 'Candidate input process did not start.'
    }
    $started = $true
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $readyLine = $process.StandardOutput.ReadLineAsync().WaitAsync(
        [TimeSpan]::FromSeconds(45)).GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($readyLine)) {
        [void]$process.WaitForExit(5000)
        $stderr = if ($stderrTask.IsCompleted) {
            $stderrTask.GetAwaiter().GetResult().Trim()
        }
        else {
            'no SSH error was available'
        }
        throw "Candidate input process returned no handshake: $stderr"
    }
    $ready = $readyLine | ConvertFrom-Json
    if (-not $ready.ready -or $ready.schema -ne 'rmmirror.input/v1') {
        throw 'Candidate input handshake was invalid.'
    }
    $filesState = [string]$ready.files_state
    Write-Host "display_state=$([string]$ready.display_state)"
    Write-Host "files_state=$filesState"

    $commandId = 0
    if ($ImmediateActivityBeforeFilesCheck) {
        $commandId++
        Send-InputWakeActivity `
            -Process $process `
            -CommandId $commandId `
            -Purpose 'immediate non-toggling wake' `
            -Key 'KEY_WAKEUP'
        Write-Host 'immediate_wakeup_ok'
        $commandId++
        Send-InputWakeActivity -Process $process -CommandId $commandId -Purpose 'immediate activity'
        Write-Host 'immediate_activity_ok'
    }

    Invoke-TabletCommand -Command $activeRuntimeCheck

    $filesDeadline = (Get-Date).AddSeconds($FilesReadyWaitSeconds)
    while (-not (Test-TabletCommand -Command $filesHttpCheck)) {
        if ((Get-Date) -ge $filesDeadline) {
            throw "Files HTTP did not become ready within $FilesReadyWaitSeconds seconds."
        }
        $commandId++
        Send-InputWakeActivity -Process $process -CommandId $commandId -Purpose 'Files readiness'
        Start-Sleep -Seconds $ActivityIntervalSeconds
    }
    Invoke-TabletCommand -Command $activeCheck
    if ($RequireFilesStateReady -and $filesState -cne 'ready') {
        throw "Candidate input handshake reported Files state '$filesState'."
    }

    if ($HoldSeconds -gt 0) {
        $holdDeadline = (Get-Date).AddSeconds($HoldSeconds)
        while ((Get-Date) -lt $holdDeadline) {
            $commandId++
            Send-InputWakeActivity -Process $process -CommandId $commandId -Purpose 'hold'

            $remaining = $holdDeadline - (Get-Date)
            if ($remaining -gt [TimeSpan]::Zero) {
                $activityIntervalMilliseconds = $ActivityIntervalSeconds * 1000
                Start-Sleep -Milliseconds (
                    [Math]::Min($activityIntervalMilliseconds, [int]$remaining.TotalMilliseconds))
            }
        }
        Invoke-TabletCommand -Command $activeCheck
        Write-Host "fallback_held_${HoldSeconds}s_activity_${ActivityIntervalSeconds}s"
    }

    $lanClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $lanClient.ConnectAsync($TabletAddress, 80).WaitAsync(
            [TimeSpan]::FromSeconds(1)).GetAwaiter().GetResult()
        throw 'The stock Files endpoint was exposed directly on Wi-Fi.'
    }
    catch [System.TimeoutException] {
        Write-Host 'lan_http_closed'
    }
    catch [System.Net.Sockets.SocketException] {
        Write-Host 'lan_http_closed'
    }
    finally {
        $lanClient.Dispose()
    }

    $process.StandardInput.Close()
    if (-not $process.WaitForExit(100000)) {
        $process.Kill($true)
        throw 'Candidate input process did not clean up.'
    }
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    if ($process.ExitCode -ne 0) {
        throw "Candidate input exited $($process.ExitCode): $stderr"
    }
}
catch {
    $primaryError = $_.Exception
}
finally {
    if ($started -and -not $process.HasExited) {
        try {
            $process.StandardInput.Close()
        }
        catch {
            $cleanupErrors.Add($_.Exception)
        }
        try {
            if (-not $process.WaitForExit(100000)) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) {
                    throw 'Candidate input process remained active after it was killed.'
                }
            }
        }
        catch {
            $cleanupErrors.Add($_.Exception)
        }
    }
    if ($started) {
        if ($process.HasExited) {
            try {
                Invoke-TabletCommand -Command $cleanupCheck
            }
            catch {
                $cleanupErrors.Add($_.Exception)
            }
        }
        else {
            $cleanupErrors.Add(
                [System.InvalidOperationException]::new(
                    'Cleanup verification could not run because the candidate input process did not terminate.'))
        }
    }
    try {
        $process.Dispose()
    }
    catch {
        $cleanupErrors.Add($_.Exception)
    }
}

if ($null -ne $primaryError -and $cleanupErrors.Count -gt 0) {
    $allErrors = [System.Collections.Generic.List[System.Exception]]::new()
    $allErrors.Add($primaryError)
    $allErrors.AddRange($cleanupErrors)
    throw [System.AggregateException]::new(
        'Live fallback test failed and cleanup also reported errors.',
        $allErrors.ToArray())
}
if ($null -ne $primaryError) {
    throw $primaryError
}
if ($cleanupErrors.Count -eq 1) {
    throw $cleanupErrors[0]
}
if ($cleanupErrors.Count -gt 1) {
    throw [System.AggregateException]::new(
        'Live fallback cleanup reported multiple errors.',
        $cleanupErrors.ToArray())
}

Write-Host 'Result: PASS'
