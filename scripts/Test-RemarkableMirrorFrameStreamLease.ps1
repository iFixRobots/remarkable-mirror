[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$frameSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\SshFrameSource.cs'
$mainPageSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\MainPage.xaml.cs'
$routeSourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\SshRoute.cs'
$passiveProbePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\PassiveRouteProbe.cs'
$installerPath = Join-Path `
    $repositoryRoot `
    'scripts\Install-RemarkableMirrorPrerequisites.ps1'

$frameSource = [System.IO.File]::ReadAllText($frameSourcePath)
$mainPageSource = [System.IO.File]::ReadAllText($mainPageSourcePath)
$routeSource = [System.IO.File]::ReadAllText($routeSourcePath)
$passiveProbe = [System.IO.File]::ReadAllText($passiveProbePath)
$installer = [System.IO.File]::ReadAllText($installerPath)

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Expected,

        [Parameter(Mandatory)]
        [string]$Failure
    )

    if (-not $Source.Contains($Expected, [System.StringComparison]::Ordinal)) {
        throw $Failure
    }
}

function Get-RequiredIndex {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Expected,

        [Parameter(Mandatory)]
        [string]$Failure,

        [int]$StartIndex = 0
    )

    $index = $Source.IndexOf(
        $Expected,
        $StartIndex,
        [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw $Failure
    }
    return $index
}

$remoteCommand =
    '/home/root/.local/bin/rmmirror-probe stream --interval 40ms --heartbeat-timeout 15s'
Assert-Contains `
    -Source $frameSource `
    -Expected $remoteCommand `
    -Failure 'The frame stream does not use the exact leased stream command.'
Assert-Contains `
    -Source $frameSource `
    -Expected 'private const string StreamHeartbeatPulse = "\n";' `
    -Failure 'The frame stream heartbeat is not a newline pulse.'
Assert-Contains `
    -Source $frameSource `
    -Expected 'StreamHeartbeatInterval = TimeSpan.FromSeconds(3);' `
    -Failure 'The frame stream heartbeat interval is not three seconds.'
Write-Host 'Exact frame-stream lease command and heartbeat cadence: PASS'

$writerStart = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'heartbeatWriter = WriteStreamHeartbeatsAsync(' `
    -Failure 'The frame stream does not start its heartbeat writer.'
$frameReadStart = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'var stream = process.StandardOutput.BaseStream;' `
    -Failure 'The frame stream read loop was not found.'
if ($writerStart -ge $frameReadStart) {
    throw 'The heartbeat writer does not begin independently before frame rendering.'
}

$writerMethod = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'private static async Task WriteStreamHeartbeatsAsync(' `
    -Failure 'The frame stream heartbeat writer method was not found.'
$immediateWrite = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'await input.WriteAsync(StreamHeartbeatPulse.AsMemory(), cancellationToken)' `
    -Failure 'The heartbeat writer has no immediate pulse.' `
    -StartIndex $writerMethod
$periodicLoop = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'while (await timer.WaitForNextTickAsync(cancellationToken)' `
    -Failure 'The heartbeat writer has no periodic pulse loop.' `
    -StartIndex $writerMethod
if ($immediateWrite -ge $periodicLoop) {
    throw 'The heartbeat writer waits for the first timer tick instead of pulsing immediately.'
}
Write-Host 'Heartbeat writer starts immediately and independently of rendering: PASS'

$cancelWriter = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'heartbeatCancellation.Cancel();' `
    -Failure 'Frame-stream cleanup does not cancel the heartbeat writer.'
$observeWriter = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'await heartbeatWriter.ConfigureAwait(false);' `
    -Failure 'Frame-stream cleanup does not observe the heartbeat writer.' `
    -StartIndex $cancelWriter
$terminateProcess = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'await TerminateAndDrainAsync(process, started, errorDrain).ConfigureAwait(false);' `
    -Failure 'Frame-stream process cleanup was not found.' `
    -StartIndex $observeWriter
if (-not ($cancelWriter -lt $observeWriter -and $observeWriter -lt $terminateProcess)) {
    throw 'Frame-stream cleanup no longer stops and observes the writer before closing stdin.'
}
Write-Host 'Heartbeat writer ownership precedes stdin/process cleanup: PASS'

Assert-Contains `
    -Source $frameSource `
    -Expected '"rmmirror-probe: stream_heartbeat_timeout"' `
    -Failure 'The companion heartbeat-expiry marker is not classified.'
Assert-Contains `
    -Source $frameSource `
    -Expected 'StreamInterrupted("exit=" + exitCode + "; category=stream_heartbeat_timeout")' `
    -Failure 'Heartbeat expiry is not mapped to a sanitized transient classification.'
$streamInterruptedStart = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'private static FrameStreamException StreamInterrupted(' `
    -Failure 'The StreamInterrupted helper was not found.'
$streamInterruptedEnd = Get-RequiredIndex `
    -Source $frameSource `
    -Expected 'private readonly record struct ParsedFrameUpdate(' `
    -Failure 'The end of the StreamInterrupted helper was not found.' `
    -StartIndex $streamInterruptedStart
$streamInterruptedBlock = $frameSource.Substring(
    $streamInterruptedStart,
    $streamInterruptedEnd - $streamInterruptedStart)
Assert-Contains `
    -Source $streamInterruptedBlock `
    -Expected 'FrameStreamFailureKind.StreamInterrupted,' `
    -Failure 'The transient frame-stream classification was not found.'
Assert-Contains `
    -Source $streamInterruptedBlock `
    -Expected 'canAutoRetry: true,' `
    -Failure 'Frame-stream interruption is no longer marked transient for sanitized copy.'
Assert-Contains `
    -Source $frameSource `
    -Expected 'return StreamInterrupted(technicalDetail);' `
    -Failure 'A clean or unmarked stream exit no longer shares the transient classification.'

$handleFailureStart = Get-RequiredIndex `
    -Source $mainPageSource `
    -Expected 'private async Task HandleFrameFailureAsync(' `
    -Failure 'The selected-route frame failure handler was not found.'
$handleFailureEnd = Get-RequiredIndex `
    -Source $mainPageSource `
    -Expected 'private async Task RetireSelectedConnectionAsync(' `
    -Failure 'The exact-generation retirement method was not found.' `
    -StartIndex $handleFailureStart
$handleFailureBlock = $mainPageSource.Substring(
    $handleFailureStart,
    $handleFailureEnd - $handleFailureStart)
Assert-Contains `
    -Source $handleFailureBlock `
    -Expected 'await RetireSelectedConnectionAsync(' `
    -Failure 'A frame failure no longer retires the owner-selected route.'
foreach ($forbiddenRetryMarker in @(
        'BeginDisplayRecoveryAsync(',
        'AutomaticFrameRetryLimit',
        'RetryDelayFor('
    )) {
    if ($mainPageSource.Contains($forbiddenRetryMarker, [StringComparison]::Ordinal)) {
        throw "MainPage still reopens a failed frame route automatically: $forbiddenRetryMarker"
    }
}
Write-Host 'Transient stream failures retire the selected route for a new owner action: PASS'

Assert-Contains `
    -Source $passiveProbe `
    -Expected 'private const string ExpectedProbeVersion = "0.4.9";' `
    -Failure 'Passive route validation does not require probe 0.4.9.'
Assert-Contains `
    -Source $passiveProbe `
    -Expected 'test "$probe_version" = ''0.4.9'' || mismatch=1' `
    -Failure 'The embedded passive probe does not require probe 0.4.9.'
Assert-Contains `
    -Source $installer `
    -Expected "`$mirrorProbeVersion = '0.4.9'" `
    -Failure 'The prerequisite installer does not deploy probe 0.4.9.'
Write-Host 'Windows prerequisite version contract is probe 0.4.9: PASS'

$probePublish = Get-RequiredIndex `
    -Source $installer `
    -Expected 'mv -f /home/root/.local/bin/rmmirror-probe.new /home/root/.local/bin/rmmirror-probe' `
    -Failure 'The prerequisite installer no longer publishes the probe atomically.'
$retirementStart = Get-RequiredIndex `
    -Source $installer `
    -Expected 'frame_stream_probe_path=/home/root/.local/bin/rmmirror-probe' `
    -Failure 'The prerequisite installer has no frame-stream retirement transaction.' `
    -StartIndex $probePublish
$transportInstall = Get-RequiredIndex `
    -Source $installer `
    -Expected 'chmod 0700 "`$stage/install-transport-wake.sh"' `
    -Failure 'The transport installer boundary was not found after frame-stream retirement.' `
    -StartIndex $retirementStart
$retirementBlock = $installer.Substring(
    $retirementStart,
    $transportInstall - $retirementStart)
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'frame_stream_probe_path=/home/root/.local/bin/rmmirror-probe' `
    -Failure 'Frame-stream retirement does not pin the exact probe executable.'
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'test "`$frame_stream_executable" != "`$frame_stream_probe_path (deleted)"' `
    -Failure 'Frame-stream retirement does not recognize the old atomically replaced executable.'
$retirementDefinition = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'retire_frame_streams() {' `
    -Failure 'The frame-stream retirement function was not found.'
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'test "`$frame_stream_argv0" = "`$frame_stream_probe_path"' `
    -Failure 'Frame-stream retirement does not require the exact probe argv[0].'
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'test "`$frame_stream_argv1" = stream' `
    -Failure 'Frame-stream retirement does not require argv[1] to be stream.'
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'while test "`$frame_stream_attempt" -lt 20; do' `
    -Failure 'Frame-stream retirement no longer has a bounded polling window.'
Assert-Contains `
    -Source $retirementBlock `
    -Expected 'sleep 0.1' `
    -Failure 'Frame-stream retirement no longer uses a bounded short polling cadence.'
$term = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'kill -TERM `$frame_stream_pids' `
    -Failure 'Frame-stream retirement does not attempt graceful TERM.'
$firstWait = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'if wait_for_frame_stream_retirement; then' `
    -Failure 'Frame-stream retirement has no bounded wait after TERM.' `
    -StartIndex $term
$kill = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'kill -KILL `$frame_stream_pids' `
    -Failure 'Frame-stream retirement does not force blocked survivors to exit.' `
    -StartIndex $firstWait
$secondWait = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'if wait_for_frame_stream_retirement; then' `
    -Failure 'Frame-stream retirement has no bounded wait after KILL.' `
    -StartIndex $kill
$failureMarker = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected 'rmmirror-prerequisite: frame_stream_retirement_failed' `
    -Failure 'Frame-stream retirement has no explicit failure marker.' `
    -StartIndex $secondWait
if (-not ($term -lt $firstWait -and
        $firstWait -lt $kill -and
        $kill -lt $secondWait -and
        $secondWait -lt $failureMarker)) {
    throw 'Frame-stream retirement no longer follows TERM, wait, KILL, wait, fail ordering.'
}
if ($retirementBlock.Contains('input', [System.StringComparison]::OrdinalIgnoreCase) -or
    $retirementBlock.Contains('watchdog', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Frame-stream retirement must not target input or watchdog processes.'
}
$retirementCall = Get-RequiredIndex `
    -Source $retirementBlock `
    -Expected "`nretire_frame_streams" `
    -Failure 'The frame-stream retirement transaction is defined but not invoked.' `
    -StartIndex ($retirementDefinition + 'retire_frame_streams() {'.Length)
Write-Host 'Probe upgrade retires only exact frame streams with bounded TERM/KILL verification: PASS'

Assert-Contains `
    -Source $routeSource `
    -Expected '"ServerAliveInterval=3"' `
    -Failure 'The OpenSSH keepalive interval drifted from three seconds.'
Assert-Contains `
    -Source $routeSource `
    -Expected '"ServerAliveCountMax=3"' `
    -Failure 'The OpenSSH keepalive count drifted from three.'
Write-Host 'Existing 3x3 OpenSSH keepalive policy remains intact: PASS'
Write-Host 'Result: PASS'
