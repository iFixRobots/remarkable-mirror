[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$NoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$appProject = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\ReMarkableMirror.csproj'
if (-not $NoBuild) {
    & dotnet build $appProject `
        -c $Configuration `
        -r win-x64 `
        -p:PublishTrimmed=false `
        --no-restore
    if ($LASTEXITCODE -ne 0) {
        throw "ReMarkableMirror build failed with exit code $LASTEXITCODE."
    }
}

$sourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\MirrorInputRecoveryPolicy.cs'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw 'MirrorInputRecoveryPolicy.cs is missing.'
}

$escapedSourcePath = [System.Security.SecurityElement]::Escape($sourcePath)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-input-recovery-validation-' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $temporaryRoot 'InputRecoveryValidation.csproj'
$programPath = Join-Path $temporaryRoot 'Program.cs'

$project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$escapedSourcePath" Link="MirrorInputRecoveryPolicy.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@

$program = @'
using System.Diagnostics;

namespace ReMarkableMirror;

internal static class Program
{
    public static int Main()
    {
        try
        {
            var policy = new MirrorInputRecoveryPolicy();
            var window = TimeSpan.FromSeconds(15);
            var started = Stopwatch.GetTimestamp();
            var withinWindow = started + (long)(Stopwatch.Frequency * 2.0);
            var afterWindow = started + (long)(Stopwatch.Frequency * 20.0);

            policy.BeginGeneration(10);
            Require(policy.RequiresInputPublication(10));
            Require(policy.TryReserveSetupFailureRecovery(10));
            Require(!policy.TryReserveSetupFailureRecovery(10));
            Require(policy.RequiresInputPublication(10));
            policy.MarkRecoveryComplete(10);
            Require(!policy.RequiresInputPublication(10));

            Require(policy.RecordPublishedSessionLoss(11, started, window, true) ==
                MirrorInputRecoveryDisposition.AwaitingFrameInterruption);
            Require(policy.RequiresInputPublication(11));
            Require(!policy.TryConsumeScheduled(12, withinWindow, window));
            policy.RecordFrameInterruption(11, withinWindow);
            Require(policy.TryConsumeScheduled(11, withinWindow, window));
            Require(policy.RequiresInputPublication(11));
            Require(!policy.TryConsumeScheduled(11, withinWindow, window));

            policy.MarkRecoveryComplete(11);
            Require(!policy.RequiresInputPublication(11));
            Require(policy.RecordPublishedSessionLoss(11, withinWindow, window, true) ==
                MirrorInputRecoveryDisposition.None);
            Require(policy.RequiresInputPublication(11));

            policy.RearmGeneration(11);
            Require(policy.RequiresInputPublication(11));
            Require(policy.RecordPublishedSessionLoss(11, started, window, true) ==
                MirrorInputRecoveryDisposition.AwaitingFrameInterruption);
            Require(!policy.TryConsumeScheduled(11, afterWindow, window));
            Require(policy.RequiresInputPublication(11));
            Require(policy.RecordPublishedSessionLoss(11, afterWindow, window, true) ==
                MirrorInputRecoveryDisposition.None);

            policy.RearmGeneration(11);
            policy.RecordFrameInterruption(11, started);
            Require(policy.RecordPublishedSessionLoss(11, withinWindow, window, true) ==
                MirrorInputRecoveryDisposition.BeginNow);
            Require(policy.RequiresInputPublication(11));
            Require(!policy.TryConsumeScheduled(11, withinWindow, window));

            policy.RearmGeneration(11);
            Require(policy.TryReserveStoppedSessionRecovery(11));
            Require(policy.RequiresInputPublication(11));
            Require(!policy.TryReserveStoppedSessionRecovery(11));
            Require(policy.RecordPublishedSessionLoss(11, withinWindow, window, true) ==
                MirrorInputRecoveryDisposition.None);
            Require(policy.RequiresInputPublication(11));
            policy.AbandonGeneration(11);
            Require(!policy.RequiresInputPublication(11));

            policy.RearmGeneration(11);
            Require(policy.RecordPublishedSessionLoss(11, started, window, false) ==
                MirrorInputRecoveryDisposition.None);
            Require(policy.RequiresInputPublication(11));

            policy.RearmGeneration(11);
            Require(policy.TryReserveStoppedSessionRecovery(11));
            policy.MarkRecoveryComplete(11);
            Require(!policy.RequiresInputPublication(11));
            policy.Reset();
            Require(!policy.RequiresInputPublication(11));
            Require(policy.TryReserveStoppedSessionRecovery(11));

            Console.WriteLine("Result: PASS");
            Console.WriteLine("GenerationFence: PASS");
            Console.WriteLine("CoupledWindow: PASS");
            Console.WriteLine("OneShotBudget: PASS");
            Console.WriteLine("PublicationGate: PASS");
            Console.WriteLine("InitialPublicationGate: PASS");
            Console.WriteLine("InitialSetupOneShot: PASS");
            Console.WriteLine("BothEventOrders: PASS");
            Console.WriteLine("PublishThenDieBeforeFrame: PASS");
            Console.WriteLine("ExplicitRearm: PASS");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Input-recovery policy validation failed: {exception.GetType().Name}.");
            return 1;
        }
    }

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new InvalidOperationException();
        }
    }
}
'@

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    [System.IO.File]::WriteAllText($projectPath, $project)
    [System.IO.File]::WriteAllText($programPath, $program)
    & dotnet run --project $projectPath -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "Input-recovery policy validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
