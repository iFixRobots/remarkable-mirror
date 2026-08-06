[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path `
    $repositoryRoot `
    'mirror\windows\ReMarkableMirror\WifiRepairConfirmationPolicy.cs'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw 'WifiRepairConfirmationPolicy.cs is missing.'
}

$escapedSourcePath = [System.Security.SecurityElement]::Escape($sourcePath)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-wifi-repair-validation-' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $temporaryRoot 'WifiRepairValidation.csproj'
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
    <Compile Include="$escapedSourcePath" Link="WifiRepairConfirmationPolicy.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@

$program = @'
namespace ReMarkableMirror;

internal static class Program
{
    public static int Main()
    {
        try
        {
            var policy = new WifiRepairConfirmationPolicy();

            Require(!policy.Record(true, true));
            Require(policy.Record(true, true));

            policy.Reset();
            Require(!policy.Record(true, true));
            Require(!policy.Record(false, false));
            Require(!policy.Record(true, true));

            policy.Reset();
            Require(!policy.Record(false, true));
            Require(!policy.Record(false, true));
            Require(!policy.Record(true, false));
            Require(!policy.Record(true, false));

            policy.Reset();
            Require(!policy.Record(true, true));

            Console.WriteLine("Result: PASS");
            Console.WriteLine("ConsecutiveConfirmation: PASS");
            Console.WriteLine("TransientReset: PASS");
            Console.WriteLine("IdentityRequired: PASS");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Wi-Fi repair policy validation failed: {exception.GetType().Name}.");
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
        throw "Wi-Fi repair policy validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
