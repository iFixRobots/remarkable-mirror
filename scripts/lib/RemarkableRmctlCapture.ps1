Set-StrictMode -Version Latest

if ($null -eq ('Remarkable.Capture.WindowsJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Remarkable.Capture
{
    public sealed class WindowsJob : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectBasicAccountingInformation = 1;
        private const int JobObjectExtendedLimitInformation = 9;
        private IntPtr handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicAccountingInformation
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref ExtendedLimitInformation information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(
            IntPtr job,
            int informationClass,
            out BasicAccountingInformation information,
            uint informationLength,
            IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public WindowsJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
            }

            var limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            if (!SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    ref limits,
                    (uint)Marshal.SizeOf<ExtendedLimitInformation>()))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(handle);
                handle = IntPtr.Zero;
                throw new Win32Exception(error, "SetInformationJobObject failed.");
            }
        }

        public void Assign(Process process)
        {
            EnsureOpen();
            if (!AssignProcessToJobObject(handle, process.Handle))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed.");
            }
        }

        public uint GetActiveProcessCount()
        {
            EnsureOpen();
            BasicAccountingInformation accounting;
            if (!QueryInformationJobObject(
                    handle,
                    JobObjectBasicAccountingInformation,
                    out accounting,
                    (uint)Marshal.SizeOf<BasicAccountingInformation>(),
                    IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "QueryInformationJobObject failed.");
            }
            return accounting.ActiveProcesses;
        }

        public void Terminate(uint exitCode)
        {
            EnsureOpen();
            if (!TerminateJobObject(handle, exitCode))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TerminateJobObject failed.");
            }
        }

        private void EnsureOpen()
        {
            if (handle == IntPtr.Zero)
            {
                throw new ObjectDisposedException(nameof(WindowsJob));
            }
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
            GC.SuppressFinalize(this);
        }

        ~WindowsJob()
        {
            Dispose();
        }
    }
}
'@
}

function Wait-RemarkableProcessExitBounded {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [ValidateRange(1, 5000)]
        [int]$TimeoutMilliseconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if ($Process.HasExited) {
                return $true
            }
        }
        catch {
            return $true
        }
        Start-Sleep -Milliseconds 20
    } while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    $false
}

function Stop-RemarkableWindowsJobTree {
    param(
        [Parameter(Mandatory)]
        [object]$Job,

        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [ValidateRange(100, 5000)]
        [int]$TimeoutMilliseconds
    )

    try {
        $Job.Terminate(1)
    }
    catch {
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $activeProcesses = $Job.GetActiveProcessCount()
        }
        catch {
            return $false
        }
        try {
            $rootExited = $Process.HasExited
        }
        catch {
            $rootExited = $true
        }
        if ($activeProcesses -eq 0 -and $rootExited) {
            return $true
        }
        Start-Sleep -Milliseconds 20
    } while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    $false
}

function Invoke-RemarkableExternalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600000)]
        [int]$TimeoutMilliseconds,

        [ValidateRange(100, 5000)]
        [int]$TerminationGraceMilliseconds = 1000,

        [ValidateRange(100, 5000)]
        [int]$OutputDrainGraceMilliseconds = 1000
    )

    if (-not $IsWindows) {
        throw 'external_process_windows_job_required: this capture helper requires Windows.'
    }

    $payloadJson = ConvertTo-Json -Compress -Depth 3 -InputObject ([ordered]@{
        file_path = $FilePath
        arguments = @($Arguments)
    })
    $payloadBase64 = [System.Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
    )
    $gateName = 'Local\RemarkableCaptureGate_{0}' -f `
        [guid]::NewGuid().ToString('N')
    $launcherScript = @"
`$gate = [System.Threading.EventWaitHandle]::OpenExisting('$gateName')
try {
    [void]`$gate.WaitOne()
}
finally {
    `$gate.Dispose()
}
`$ErrorActionPreference = 'Stop'
`$payloadBase64 = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace(`$payloadBase64)) {
    throw 'Launcher payload was empty.'
}
`$payloadJson = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String(`$payloadBase64)
)
`$payload = ConvertFrom-Json -InputObject `$payloadJson
`$targetStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
`$targetStartInfo.FileName = [string]`$payload.file_path
`$targetStartInfo.UseShellExecute = `$false
`$targetStartInfo.CreateNoWindow = `$true
# Redirecting only stdin makes .NET pass the launcher's output handles through.
`$targetStartInfo.RedirectStandardInput = `$true
foreach (`$argument in @(`$payload.arguments)) {
    [void]`$targetStartInfo.ArgumentList.Add([string]`$argument)
}
`$target = [System.Diagnostics.Process]::new()
`$target.StartInfo = `$targetStartInfo
try {
    if (-not `$target.Start()) {
        throw 'Target process did not start.'
    }
    `$target.StandardInput.Close()
    [void]`$target.WaitForExit([System.Threading.Timeout]::Infinite)
    `$targetExitCode = `$target.ExitCode
}
finally {
    `$target.Dispose()
}
exit `$targetExitCode
"@
    $launcherEncodedCommand = [System.Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($launcherScript)
    )
    $launcherPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ([string]::IsNullOrWhiteSpace($launcherPath)) {
        throw 'external_process_launcher_not_found: could not resolve the current pwsh executable.'
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launcherPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            $launcherEncodedCommand
        )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $gateEvent = $null
    $job = $null
    $process = $null
    try {
        $createdNew = $false
        try {
            $gateEvent = [System.Threading.EventWaitHandle]::new(
                $false,
                [System.Threading.EventResetMode]::ManualReset,
                $gateName,
                [ref]$createdNew
            )
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "external_process_gate_creation_failed: $($_.Exception.Message)"
            )
        }
        if (-not $createdNew) {
            throw [System.InvalidOperationException]::new(
                'external_process_gate_creation_failed: the unique gate name already exists.'
            )
        }

        try {
            $job = [Remarkable.Capture.WindowsJob]::new()
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "external_process_job_creation_failed: $($_.Exception.Message)"
            )
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start gated launcher for $FilePath"
        }

        try {
            $job.Assign($process)
        }
        catch {
            $assignmentMessage = $_.Exception.Message
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
            }
            catch {
            }
            $assignmentCleanupConfirmed = Wait-RemarkableProcessExitBounded `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            if (-not $assignmentCleanupConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_job_assignment_termination_failed: $FilePath could not be assigned to its job and fallback termination was not confirmed within $TerminationGraceMilliseconds ms."
                )
            }
            throw [System.InvalidOperationException]::new(
                "external_process_job_assignment_failed: $FilePath could not be assigned to its job. $assignmentMessage"
            )
        }

        try {
            if (-not $gateEvent.Set()) {
                throw 'The launcher gate did not report a successful signal.'
            }
        }
        catch {
            $gateSignalMessage = $_.Exception.Message
            $gateCleanupConfirmed = Stop-RemarkableWindowsJobTree `
                -Job $job `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            if (-not $gateCleanupConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_gate_signal_termination_failed: $FilePath was gated but its launcher did not terminate within $TerminationGraceMilliseconds ms."
                )
            }
            throw [System.InvalidOperationException]::new(
                "external_process_gate_signal_failed: $FilePath did not start because its launcher gate could not be signaled. $gateSignalMessage"
            )
        }

        try {
            $process.StandardInput.Write($payloadBase64)
            $process.StandardInput.Close()
        }
        catch {
            $payloadTransferMessage = $_.Exception.Message
            $payloadCleanupConfirmed = Stop-RemarkableWindowsJobTree `
                -Job $job `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            if (-not $payloadCleanupConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_payload_transfer_termination_failed: $FilePath received its gate but its launcher did not terminate within $TerminationGraceMilliseconds ms."
                )
            }
            throw [System.InvalidOperationException]::new(
                "external_process_payload_transfer_failed: $FilePath did not start because its launcher payload could not be delivered. $payloadTransferMessage"
            )
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $treeTerminationConfirmed = Stop-RemarkableWindowsJobTree `
                -Job $job `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            if (-not $treeTerminationConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_timeout_termination_failed: $FilePath exceeded $TimeoutMilliseconds ms and did not confirm termination within $TerminationGraceMilliseconds ms."
                )
            }
            throw [System.TimeoutException]::new(
                "external_process_timeout_terminated: $FilePath exceeded $TimeoutMilliseconds ms and was terminated."
            )
        }

        $outputDrain = [System.Threading.Tasks.Task]::WhenAll(
            [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        )
        $outputDrainDeadline = [System.Threading.Tasks.Task]::Delay(
            $OutputDrainGraceMilliseconds
        )
        $completedDrainTask = [System.Threading.Tasks.Task]::WhenAny(
            [System.Threading.Tasks.Task[]]@($outputDrain, $outputDrainDeadline)
        ).GetAwaiter().GetResult()
        if ([object]::ReferenceEquals($completedDrainTask, $outputDrainDeadline)) {
            $treeTerminationConfirmed = Stop-RemarkableWindowsJobTree `
                -Job $job `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            try {
                $process.StandardOutput.Close()
            }
            catch {
            }
            try {
                $process.StandardError.Close()
            }
            catch {
            }
            if (-not $treeTerminationConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_output_drain_termination_failed: $FilePath exited but its job tree did not terminate within $TerminationGraceMilliseconds ms."
                )
            }
            throw [System.TimeoutException]::new(
                "external_process_output_drain_timeout: $FilePath exited but redirected output did not close within $OutputDrainGraceMilliseconds ms."
            )
        }

        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
        try {
            $activeDescendants = $job.GetActiveProcessCount()
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "external_process_job_query_failed: $($_.Exception.Message)"
            )
        }
        if ($activeDescendants -gt 0) {
            $descendantCleanupConfirmed = Stop-RemarkableWindowsJobTree `
                -Job $job `
                -Process $process `
                -TimeoutMilliseconds $TerminationGraceMilliseconds
            if (-not $descendantCleanupConfirmed) {
                throw [System.TimeoutException]::new(
                    "external_process_descendant_cleanup_failed: $FilePath exited but descendants remained after $TerminationGraceMilliseconds ms."
                )
            }
        }
        $result
    }
    finally {
        if ($null -ne $job) {
            $job.Dispose()
        }
        if ($null -ne $process) {
            try {
                $process.StandardInput.Close()
            }
            catch {
            }
            $process.Dispose()
        }
        if ($null -ne $gateEvent) {
            $gateEvent.Dispose()
        }
    }
}

function Assert-RemarkableJsonObjectShape {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Required,

        [string[]]$Optional = @()
    )

    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "$Path must be a non-null object."
    }

    $allowed = @{}
    foreach ($name in @($Required) + @($Optional)) {
        $allowed[$name] = $true
    }
    foreach ($name in $Required) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -eq $property) {
            throw "$Path is missing required property $name."
        }
        if ($null -eq $property.Value) {
            throw "$Path.$name must not be null."
        }
    }
    foreach ($property in $Value.PSObject.Properties) {
        if (-not $allowed.ContainsKey($property.Name)) {
            throw "$Path contains unexpected property $($property.Name)."
        }
        if ($null -eq $property.Value) {
            throw "$Path.$($property.Name) must not be null."
        }
    }
}

function Assert-RemarkableJsonArray {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [System.Array]) {
        throw "$Path must be a non-null array."
    }
}

function Assert-RemarkableJsonString {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowEmpty
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        throw "$Path must be a string."
    }
    if (-not $AllowEmpty -and $Value.Length -eq 0) {
        throw "$Path must not be empty."
    }
}

function Assert-RemarkableJsonBoolean {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -eq $Value -or $Value -isnot [bool]) {
        throw "$Path must be a boolean."
    }
}

function Assert-RemarkableJsonNonnegativeInteger {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $isInteger = $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    if (-not $isInteger -or [decimal]$Value -lt 0) {
        throw "$Path must be a nonnegative integer."
    }
}

function Assert-RemarkableSnapshotContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Snapshot,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot `
        -Path '$' `
        -Required @(
            'schema',
            'captured_at',
            'status',
            'privacy',
            'identity',
            'memory',
            'filesystems',
            'services',
            'settings',
            'errors'
        )

    Assert-RemarkableJsonString -Value $Snapshot.schema -Path '$.schema'
    if ($Snapshot.schema -ne 'rmctl.snapshot/v1') {
        throw 'rmctl returned an unsupported snapshot schema.'
    }
    Assert-RemarkableJsonString -Value $Snapshot.captured_at -Path '$.captured_at'
    if ($Snapshot.captured_at -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{0,8}[1-9])?Z$') {
        throw '$.captured_at must use canonical Go RFC3339Nano UTC Z form.'
    }
    $capturedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            $Snapshot.captured_at,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$capturedAt
        )) {
        throw '$.captured_at must be a parseable timestamp.'
    }
    Assert-RemarkableJsonString -Value $Snapshot.status -Path '$.status'
    if ($Snapshot.status -notin @('complete', 'partial', 'unsupported')) {
        throw '$.status contains an invalid value.'
    }

    $privacyFields = @(
        'allowlisted_typed_setting_values_included',
        'sensitive_setting_values_included',
        'sensitive_setting_presence_included',
        'unknown_setting_names_included',
        'machine_identifiers_included',
        'mutating_operations_supported'
    )
    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot.privacy `
        -Path '$.privacy' `
        -Required $privacyFields
    foreach ($field in $privacyFields) {
        Assert-RemarkableJsonBoolean `
            -Value $Snapshot.privacy.$field `
            -Path "$.privacy.$field"
    }
    $expectedPrivacy = [ordered]@{
        allowlisted_typed_setting_values_included = $true
        sensitive_setting_values_included = $false
        sensitive_setting_presence_included = $true
        unknown_setting_names_included = $false
        machine_identifiers_included = $false
        mutating_operations_supported = $false
    }
    foreach ($field in $privacyFields) {
        if ($Snapshot.privacy.$field -ne $expectedPrivacy[$field]) {
            throw "$.privacy.$field violates the rmctl.snapshot/v1 privacy contract."
        }
    }

    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot.identity `
        -Path '$.identity' `
        -Required @(
            'product_code_name',
            'hostname',
            'architecture',
            'kernel_release',
            'os_id',
            'os_version',
            'os_build',
            'logical_cpus',
            'uptime_seconds',
            'running_as_root'
        )
    foreach ($field in @(
            'product_code_name',
            'architecture',
            'kernel_release',
            'os_id',
            'os_version',
            'os_build'
        )) {
        Assert-RemarkableJsonString `
            -Value $Snapshot.identity.$field `
            -Path "$.identity.$field" `
            -AllowEmpty
    }
    Assert-RemarkableJsonNonnegativeInteger `
        -Value $Snapshot.identity.logical_cpus `
        -Path '$.identity.logical_cpus'
    Assert-RemarkableJsonNonnegativeInteger `
        -Value $Snapshot.identity.uptime_seconds `
        -Path '$.identity.uptime_seconds'
    Assert-RemarkableJsonBoolean `
        -Value $Snapshot.identity.running_as_root `
        -Path '$.identity.running_as_root'

    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot.identity.hostname `
        -Path '$.identity.hostname' `
        -Required @('state') `
        -Optional @('value')
    Assert-RemarkableJsonString `
        -Value $Snapshot.identity.hostname.state `
        -Path '$.identity.hostname.state' `
        -AllowEmpty
    if ($Snapshot.identity.hostname.state -notin @('', 'default', 'redacted')) {
        throw '$.identity.hostname.state contains an invalid value.'
    }
    $hostnameValue = $Snapshot.identity.hostname.PSObject.Properties['value']
    if ($Snapshot.identity.hostname.state -eq 'default') {
        if ($null -eq $hostnameValue) {
            throw '$.identity.hostname.value is required for the default state.'
        }
        Assert-RemarkableJsonString `
            -Value $hostnameValue.Value `
            -Path '$.identity.hostname.value'
    }
    elseif ($null -ne $hostnameValue) {
        throw '$.identity.hostname.value is allowed only for the default state.'
    }

    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot.memory `
        -Path '$.memory' `
        -Required @('total_bytes', 'available_bytes')
    Assert-RemarkableJsonNonnegativeInteger `
        -Value $Snapshot.memory.total_bytes `
        -Path '$.memory.total_bytes'
    Assert-RemarkableJsonNonnegativeInteger `
        -Value $Snapshot.memory.available_bytes `
        -Path '$.memory.available_bytes'
    if ([decimal]$Snapshot.memory.available_bytes -gt [decimal]$Snapshot.memory.total_bytes) {
        throw '$.memory.available_bytes must not exceed total_bytes.'
    }

    Assert-RemarkableJsonArray -Value $Snapshot.filesystems -Path '$.filesystems'
    $filesystemPaths = @{}
    for ($index = 0; $index -lt $Snapshot.filesystems.Count; $index++) {
        $filesystem = $Snapshot.filesystems[$index]
        $path = "$.filesystems[$index]"
        Assert-RemarkableJsonObjectShape `
            -Value $filesystem `
            -Path $path `
            -Required @(
                'path',
                'total_bytes',
                'used_bytes',
                'free_bytes',
                'available_bytes',
                'mount'
            )
        Assert-RemarkableJsonString -Value $filesystem.path -Path "$path.path"
        if ($filesystem.path -notin @('/', '/home') -or
            $filesystemPaths.ContainsKey($filesystem.path)) {
            throw "$path.path is invalid or duplicated."
        }
        $filesystemPaths[$filesystem.path] = $true
        foreach ($field in @('total_bytes', 'used_bytes', 'free_bytes', 'available_bytes')) {
            Assert-RemarkableJsonNonnegativeInteger `
                -Value $filesystem.$field `
                -Path "$path.$field"
        }
        if ([decimal]$filesystem.used_bytes -gt [decimal]$filesystem.total_bytes -or
            [decimal]$filesystem.free_bytes -gt [decimal]$filesystem.total_bytes -or
            [decimal]$filesystem.available_bytes -gt [decimal]$filesystem.free_bytes) {
            throw "$path contains inconsistent capacity values."
        }
        Assert-RemarkableJsonObjectShape `
            -Value $filesystem.mount `
            -Path "$path.mount" `
            -Required @('filesystem_type', 'read_only', 'noexec', 'nosuid', 'nodev')
        Assert-RemarkableJsonString `
            -Value $filesystem.mount.filesystem_type `
            -Path "$path.mount.filesystem_type" `
            -AllowEmpty
        foreach ($field in @('read_only', 'noexec', 'nosuid', 'nodev')) {
            Assert-RemarkableJsonBoolean `
                -Value $filesystem.mount.$field `
                -Path "$path.mount.$field"
        }
    }

    Assert-RemarkableJsonArray -Value $Snapshot.services -Path '$.services'
    $serviceUnits = @{}
    for ($index = 0; $index -lt $Snapshot.services.Count; $index++) {
        $service = $Snapshot.services[$index]
        $path = "$.services[$index]"
        Assert-RemarkableJsonObjectShape `
            -Value $service `
            -Path $path `
            -Required @(
                'unit',
                'load_state',
                'active_state',
                'sub_state',
                'restarts',
                'healthy'
            )
        foreach ($field in @('unit', 'load_state', 'active_state', 'sub_state')) {
            Assert-RemarkableJsonString -Value $service.$field -Path "$path.$field"
        }
        if ($service.unit -notin @('xochitl.service', 'rm-sync.service') -or
            $serviceUnits.ContainsKey($service.unit)) {
            throw "$path.unit is invalid or duplicated."
        }
        $serviceUnits[$service.unit] = $true
        Assert-RemarkableJsonNonnegativeInteger `
            -Value $service.restarts `
            -Path "$path.restarts"
        Assert-RemarkableJsonBoolean -Value $service.healthy -Path "$path.healthy"
        $expectedHealthy = $service.load_state -eq 'loaded' -and
            $service.active_state -eq 'active' -and
            $service.sub_state -eq 'running'
        if ($service.healthy -ne $expectedHealthy) {
            throw "$path.healthy is inconsistent with the service states."
        }
    }

    Assert-RemarkableJsonObjectShape `
        -Value $Snapshot.settings `
        -Path '$.settings' `
        -Required @(
            'source',
            'source_state',
            'sections_observed',
            'keys_observed',
            'known_keys_observed',
            'unknown_sections',
            'unknown_keys',
            'malformed_lines',
            'duplicate_keys',
            'known'
        )
    Assert-RemarkableJsonString -Value $Snapshot.settings.source -Path '$.settings.source'
    if ($Snapshot.settings.source -ne 'xochitl.conf') {
        throw '$.settings.source contains an invalid value.'
    }
    Assert-RemarkableJsonString `
        -Value $Snapshot.settings.source_state `
        -Path '$.settings.source_state'
    if ($Snapshot.settings.source_state -notin @('present', 'absent', 'unobserved')) {
        throw '$.settings.source_state contains an invalid value.'
    }
    foreach ($field in @(
            'sections_observed',
            'keys_observed',
            'known_keys_observed',
            'unknown_sections',
            'unknown_keys',
            'malformed_lines',
            'duplicate_keys'
        )) {
        Assert-RemarkableJsonNonnegativeInteger `
            -Value $Snapshot.settings.$field `
            -Path "$.settings.$field"
    }
    if ([decimal]$Snapshot.settings.unknown_sections -gt [decimal]$Snapshot.settings.sections_observed -or
        [decimal]$Snapshot.settings.known_keys_observed -gt 12 -or
        [decimal]$Snapshot.settings.keys_observed -ne
            [decimal]$Snapshot.settings.known_keys_observed + [decimal]$Snapshot.settings.unknown_keys) {
        throw '$.settings contains inconsistent observation counts.'
    }

    Assert-RemarkableJsonArray -Value $Snapshot.settings.known -Path '$.settings.known'
    $knownPolicies = [ordered]@{
        'Experimental/SnapToShapes' = @('preference', 'bool')
        'General/DeveloperPassword' = @('secret', 'state')
        'General/LastOpen' = @('private', 'state')
        'General/LastWritingTool' = @('private', 'state')
        'General/SetupState' = @('preference', 'enum')
        'General/UserToken' = @('secret', 'state')
        'Migration/ThumbnailVersion' = @('internal', 'integer')
        'Tooltips/Long_Press_Entry' = @('preference', 'bool')
        'Tooltips/Tools_Eraser' = @('preference', 'bool')
        'Tooltips/Tools_Pens' = @('preference', 'bool')
        'Tooltips/Undo_Introduction' = @('preference', 'bool')
        'Wifi/wifiEnabledBeforeAirplaneMode' = @('preference', 'bool')
    }
    if ($Snapshot.settings.known.Count -ne $knownPolicies.Count) {
        throw '$.settings.known must contain the complete rmctl.snapshot/v1 known-key set.'
    }
    $seenKnown = @{}
    $observedKnownCount = 0
    for ($index = 0; $index -lt $Snapshot.settings.known.Count; $index++) {
        $setting = $Snapshot.settings.known[$index]
        $path = "$.settings.known[$index]"
        Assert-RemarkableJsonObjectShape `
            -Value $setting `
            -Path $path `
            -Required @('section', 'key', 'classification', 'state') `
            -Optional @('value_state', 'bool_value', 'integer_value', 'string_value')
        foreach ($field in @('section', 'key', 'classification', 'state')) {
            Assert-RemarkableJsonString -Value $setting.$field -Path "$path.$field"
        }
        $policyKey = "$($setting.section)/$($setting.key)"
        if (-not $knownPolicies.Contains($policyKey) -or $seenKnown.ContainsKey($policyKey)) {
            throw "$path identifies an unknown or duplicated setting."
        }
        $seenKnown[$policyKey] = $true
        $policy = $knownPolicies[$policyKey]
        if ($setting.classification -ne $policy[0]) {
            throw "$path.classification is inconsistent with its known-key policy."
        }
        if ($setting.state -notin @('unobserved', 'absent', 'empty', 'set', 'invalid')) {
            throw "$path.state contains an invalid value."
        }

        $optionalPresent = @(
            @(
                'value_state',
                'bool_value',
                'integer_value',
                'string_value'
            ) | Where-Object { $null -ne $setting.PSObject.Properties[$_] }
        )
        if ($setting.state -ne 'set' -and $optionalPresent.Count -ne 0) {
            throw "$path includes a typed value for a non-set state."
        }
        if ($setting.state -in @('empty', 'set', 'invalid')) {
            $observedKnownCount++
        }

        if ($setting.state -eq 'set') {
            switch ($policy[1]) {
                'bool' {
                    if ($optionalPresent.Count -ne 1 -or 'bool_value' -notin $optionalPresent) {
                        throw "$path must include exactly one boolean value."
                    }
                    Assert-RemarkableJsonBoolean `
                        -Value $setting.bool_value `
                        -Path "$path.bool_value"
                }
                'integer' {
                    if ($optionalPresent.Count -ne 1 -or 'integer_value' -notin $optionalPresent) {
                        throw "$path must include exactly one integer value."
                    }
                    Assert-RemarkableJsonNonnegativeInteger `
                        -Value $setting.integer_value `
                        -Path "$path.integer_value"
                }
                'enum' {
                    if ('value_state' -notin $optionalPresent) {
                        throw "$path must include value_state."
                    }
                    Assert-RemarkableJsonString `
                        -Value $setting.value_state `
                        -Path "$path.value_state"
                    if ($setting.value_state -eq 'allowlisted') {
                        if ($optionalPresent.Count -ne 2 -or
                            'string_value' -notin $optionalPresent) {
                            throw "$path allowlisted enum must include exactly one string value."
                        }
                        Assert-RemarkableJsonString `
                            -Value $setting.string_value `
                            -Path "$path.string_value"
                        if ($setting.string_value -ne 'Intro') {
                            throw "$path.string_value is not allowlisted."
                        }
                    }
                    elseif ($setting.value_state -eq 'withheld_unrecognized') {
                        if ($optionalPresent.Count -ne 1) {
                            throw "$path withheld enum must not include a typed value."
                        }
                    }
                    else {
                        throw "$path.value_state contains an invalid value."
                    }
                }
                'state' {
                    if ($optionalPresent.Count -ne 0) {
                        throw "$path sensitive state must not include a value."
                    }
                }
            }
        }
        elseif ($setting.state -eq 'invalid' -and $policy[1] -notin @('bool', 'integer')) {
            throw "$path invalid state is not supported for this known-key policy."
        }
    }
    if ([decimal]$Snapshot.settings.known_keys_observed -ne $observedKnownCount) {
        throw '$.settings.known_keys_observed disagrees with known setting states.'
    }
    if ($Snapshot.settings.source_state -eq 'absent' -and
        @($Snapshot.settings.known | Where-Object { $_.state -ne 'absent' }).Count -ne 0) {
        throw '$.settings absent source must report every known key as absent.'
    }
    if ($Snapshot.settings.source_state -eq 'unobserved' -and
        @($Snapshot.settings.known | Where-Object { $_.state -ne 'unobserved' }).Count -ne 0) {
        throw '$.settings unobserved source must report every known key as unobserved.'
    }

    Assert-RemarkableJsonArray -Value $Snapshot.errors -Path '$.errors'
    for ($index = 0; $index -lt $Snapshot.errors.Count; $index++) {
        $errorItem = $Snapshot.errors[$index]
        $path = "$.errors[$index]"
        Assert-RemarkableJsonObjectShape `
            -Value $errorItem `
            -Path $path `
            -Required @('component', 'code')
        foreach ($field in @('component', 'code')) {
            Assert-RemarkableJsonString -Value $errorItem.$field -Path "$path.$field"
            if ($errorItem.$field -notmatch '^[a-z0-9_.-]+$') {
                throw "$path.$field contains invalid characters."
            }
        }
    }

    $errorCount = $Snapshot.errors.Count
    switch ($Snapshot.status) {
        'complete' {
            if ($ExitCode -ne 0 -or $errorCount -ne 0) {
                throw 'rmctl complete status disagrees with its exit code or errors.'
            }
            if ($Snapshot.filesystems.Count -ne 2 -or
                $filesystemPaths.Count -ne 2 -or
                -not $filesystemPaths.ContainsKey('/') -or
                -not $filesystemPaths.ContainsKey('/home')) {
                throw 'rmctl complete status requires exactly the root and home filesystems.'
            }
            foreach ($filesystem in $Snapshot.filesystems) {
                if ([string]::IsNullOrEmpty($filesystem.mount.filesystem_type)) {
                    throw 'rmctl complete status requires every filesystem type.'
                }
            }
            if ($Snapshot.services.Count -ne 2 -or
                $serviceUnits.Count -ne 2 -or
                -not $serviceUnits.ContainsKey('xochitl.service') -or
                -not $serviceUnits.ContainsKey('rm-sync.service')) {
                throw 'rmctl complete status requires exactly both observed services.'
            }
            if ($Snapshot.identity.product_code_name -ne 'chiappa' -or
                $Snapshot.identity.architecture -ne 'arm64' -or
                [string]::IsNullOrEmpty($Snapshot.identity.kernel_release) -or
                [string]::IsNullOrEmpty($Snapshot.identity.os_id) -or
                [string]::IsNullOrEmpty($Snapshot.identity.os_version) -or
                [decimal]$Snapshot.identity.logical_cpus -le 0 -or
                $Snapshot.identity.hostname.state -notin @('default', 'redacted')) {
                throw 'rmctl complete status contains an incomplete tablet identity.'
            }
            if ([decimal]$Snapshot.memory.total_bytes -le 0) {
                throw 'rmctl complete status requires positive total memory.'
            }
            if ($Snapshot.settings.source_state -ne 'present' -or
                [decimal]$Snapshot.settings.malformed_lines -ne 0 -or
                [decimal]$Snapshot.settings.duplicate_keys -ne 0 -or
                @($Snapshot.settings.known | Where-Object {
                        $_.state -in @('unobserved', 'invalid')
                    }).Count -ne 0) {
                throw 'rmctl complete status contains an incomplete settings observation.'
            }
        }
        'partial' {
            if ($ExitCode -ne 1 -or $errorCount -eq 0) {
                throw 'rmctl partial status disagrees with its exit code or errors.'
            }
        }
        'unsupported' {
            if ($ExitCode -ne 2 -or $errorCount -eq 0) {
                throw 'rmctl unsupported status disagrees with its exit code or errors.'
            }
            if ($errorCount -ne 1 -or
                $Snapshot.errors[0].component -ne 'platform' -or
                $Snapshot.errors[0].code -ne 'linux_required') {
                throw 'rmctl unsupported status requires only platform/linux_required.'
            }
            if ($Snapshot.identity.product_code_name -ne '' -or
                [string]::IsNullOrEmpty($Snapshot.identity.architecture) -or
                $Snapshot.identity.kernel_release -ne '' -or
                $Snapshot.identity.os_id -ne '' -or
                $Snapshot.identity.os_version -ne '' -or
                $Snapshot.identity.os_build -ne '' -or
                [decimal]$Snapshot.identity.logical_cpus -le 0 -or
                [decimal]$Snapshot.identity.uptime_seconds -ne 0 -or
                $Snapshot.identity.running_as_root -or
                $Snapshot.identity.hostname.state -ne '') {
                throw 'rmctl unsupported status contains unexpected identity observations.'
            }
            if ([decimal]$Snapshot.memory.total_bytes -ne 0 -or
                [decimal]$Snapshot.memory.available_bytes -ne 0 -or
                $Snapshot.filesystems.Count -ne 0 -or
                $Snapshot.services.Count -ne 0) {
                throw 'rmctl unsupported status contains unexpected system observations.'
            }
            if ($Snapshot.settings.source_state -ne 'unobserved' -or
                [decimal]$Snapshot.settings.sections_observed -ne 0 -or
                [decimal]$Snapshot.settings.keys_observed -ne 0 -or
                [decimal]$Snapshot.settings.known_keys_observed -ne 0 -or
                [decimal]$Snapshot.settings.unknown_sections -ne 0 -or
                [decimal]$Snapshot.settings.unknown_keys -ne 0 -or
                [decimal]$Snapshot.settings.malformed_lines -ne 0 -or
                [decimal]$Snapshot.settings.duplicate_keys -ne 0 -or
                @($Snapshot.settings.known | Where-Object {
                        $_.state -ne 'unobserved'
                    }).Count -ne 0) {
                throw 'rmctl unsupported status contains unexpected settings observations.'
            }
        }
    }
}

function Resolve-RemarkableServiceVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('xochitl', 'rm_sync')]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Stdout
    )

    if ($ExitCode -ne 0) {
        return [pscustomobject]@{
            State = 'check_failed'
            IssueCode = "${Name}_check_failed"
        }
    }
    $state = $Stdout.Trim()
    if ($state -notmatch '^[a-z-]+$') {
        return [pscustomobject]@{
            State = 'check_failed'
            IssueCode = "${Name}_check_failed"
        }
    }
    if ($state -eq 'active') {
        return [pscustomobject]@{
            State = $state
            IssueCode = $null
        }
    }
    [pscustomobject]@{
        State = $state
        IssueCode = "${Name}_not_active"
    }
}

function Get-RemarkableCaptureResultLabel {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$IssueCodes = @()
    )

    $normalizedIssueCodes = @(
        $IssueCodes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($normalizedIssueCodes.Count -eq 0) {
        return 'RMCTL_CAPTURED'
    }
    $hasVerificationIssue = $false
    $hasCleanupIssue = $false
    foreach ($issueCode in $normalizedIssueCodes) {
        if ($issueCode -match '^(?:xochitl|rm_sync)_(?:not_active|check_failed)$') {
            $hasVerificationIssue = $true
        }
        else {
            $hasCleanupIssue = $true
        }
    }
    if ($hasVerificationIssue -and $hasCleanupIssue) {
        return 'RMCTL_CAPTURED_VERIFICATION_AND_CLEANUP_INCOMPLETE'
    }
    if ($hasVerificationIssue) {
        return 'RMCTL_CAPTURED_VERIFICATION_INCOMPLETE'
    }
    'RMCTL_CAPTURED_CLEANUP_INCOMPLETE'
}
