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

$sourceRoot = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror'
$modelSource = [System.Security.SecurityElement]::Escape(
    (Join-Path $sourceRoot 'DeviceProfile.cs')
)
$storeSource = [System.Security.SecurityElement]::Escape(
    (Join-Path $sourceRoot 'DeviceProfileStore.cs')
)
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('rmmirror-profile-validation-' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $temporaryRoot 'ProfileValidation.csproj'
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
    <Compile Include="$modelSource" Link="DeviceProfile.cs" />
    <Compile Include="$storeSource" Link="DeviceProfileStore.cs" />
    <Compile Include="Program.cs" />
  </ItemGroup>
</Project>
"@

$program = @'
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace ReMarkableMirror;

internal static class Program
{
    private const string Alias = "10.11.99.1";

    public static int Main(string[] args)
    {
        try
        {
            Run(args.Single());
            Console.WriteLine("Result: PASS");
            Console.WriteLine("RoundTrip: PASS");
            Console.WriteLine("AtomicReplace: PASS");
            Console.WriteLine("TokenReferenceOnly: PASS");
            Console.WriteLine("PinnedIdentity: PASS");
            Console.WriteLine("HashedAlias: PASS");
            Console.WriteLine("AdditionalApplicableKey: REJECTED");
            Console.WriteLine("DuplicateApplicableKey: REJECTED");
            Console.WriteLine("WildcardApplicableKey: REJECTED");
            Console.WriteLine("TruncatedProfile: REJECTED");
            Console.WriteLine("UnknownSchema: REJECTED");
            Console.WriteLine("UnmappedField: REJECTED");
            Console.WriteLine("WidenedAcl: REJECTED");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Device-profile validation failed: {exception.GetType().Name}.");
            return 1;
        }
    }

    private static void Run(string root)
    {
        var stateDirectory = Path.Combine(root, "state");
        var profilePath = Path.Combine(stateDirectory, "device-profile.json");
        var knownHostsPath = Path.Combine(root, "known_hosts");
        var tokenPath = Path.Combine(root, "wake-token");
        Directory.CreateDirectory(stateDirectory);
        File.WriteAllText(tokenPath, new string('a', 64), Encoding.ASCII);

        var keyBlob = Enumerable.Range(1, 64).Select(value => (byte)value).ToArray();
        WriteKnownHost(knownHostsPath, Alias, keyBlob);
        var fingerprint = Fingerprint(keyBlob);
        var store = new DeviceProfileStore(profilePath, knownHostsPath);

        var first = CreateProfile("192.0.2.10", tokenPath, fingerprint);
        store.Save(first);
        var firstLoad = store.Load();
        Require(firstLoad.Status == DeviceProfileLoadStatus.Ready &&
            firstLoad.Profile?.Equals(first) == true);

        var json = File.ReadAllText(profilePath);
        Require(!json.Contains(new string('a', 64), StringComparison.Ordinal));
        Require(json.Contains("tokenFileReference", StringComparison.Ordinal));

        var second = CreateProfile("192.0.2.11", tokenPath, fingerprint);
        store.Save(second);
        var secondLoad = store.Load();
        Require(secondLoad.Status == DeviceProfileLoadStatus.Ready &&
            secondLoad.Profile?.Equals(second) == true);
        Require(!Directory.EnumerateFiles(stateDirectory, "*.tmp").Any());
        Require(HasCurrentUserOnlyAcl(profilePath));

        File.WriteAllText(profilePath, "{");
        RequireRejected(store.Load(), DeviceProfileLoadStatus.Corrupt);

        store.Save(second);
        json = File.ReadAllText(profilePath);
        File.WriteAllText(
            profilePath,
            json.Replace(
                DeviceProfile.CurrentSchema,
                "rmmirror.device-profile/v999",
                StringComparison.Ordinal));
        RequireRejected(store.Load(), DeviceProfileLoadStatus.UnsupportedVersion);

        store.Save(second);
        json = File.ReadAllText(profilePath);
        File.WriteAllText(
            profilePath,
            json.Replace(
                "\"schema\":",
                "\"unexpected\": true,\n  \"schema\":",
                StringComparison.Ordinal));
        RequireRejected(store.Load(), DeviceProfileLoadStatus.Corrupt);

        store.Save(second);
        var salt = Enumerable.Range(65, 20).Select(value => (byte)value).ToArray();
        using (var hmac = new HMACSHA1(salt))
        {
            var hostHash = hmac.ComputeHash(Encoding.UTF8.GetBytes(Alias));
            var hashedAlias = $"|1|{Convert.ToBase64String(salt)}|{Convert.ToBase64String(hostHash)}";
            WriteKnownHost(knownHostsPath, hashedAlias, keyBlob);
        }
        Require(store.Load().Status == DeviceProfileLoadStatus.Ready);

        var differentKey = Enumerable.Range(2, 64).Select(value => (byte)value).ToArray();
        WriteKnownHosts(
            knownHostsPath,
            KnownHostLine(Alias, keyBlob),
            KnownHostLine(Alias, differentKey));
        RequireRejected(store.Load(), DeviceProfileLoadStatus.PinnedIdentityMismatch);

        WriteKnownHosts(
            knownHostsPath,
            KnownHostLine(Alias, keyBlob),
            KnownHostLine(Alias, keyBlob));
        RequireRejected(store.Load(), DeviceProfileLoadStatus.PinnedIdentityMismatch);

        WriteKnownHosts(
            knownHostsPath,
            KnownHostLine(Alias, keyBlob),
            KnownHostLine("*", differentKey));
        RequireRejected(store.Load(), DeviceProfileLoadStatus.PinnedIdentityMismatch);

        WriteKnownHosts(
            knownHostsPath,
            KnownHostLine(Alias, keyBlob),
            KnownHostLine("203.0.113.7", differentKey));
        Require(store.Load().Status == DeviceProfileLoadStatus.Ready);

        WriteKnownHost(knownHostsPath, Alias, differentKey);
        RequireRejected(store.Load(), DeviceProfileLoadStatus.PinnedIdentityMismatch);

        WriteKnownHost(knownHostsPath, Alias, keyBlob);
        store.Save(second);
        var file = new FileInfo(profilePath);
        var acl = FileSystemAclExtensions.GetAccessControl(file);
        var builtinUsers = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
        acl.AddAccessRule(new FileSystemAccessRule(
            builtinUsers,
            FileSystemRights.Read,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(file, acl);
        RequireRejected(store.Load(), DeviceProfileLoadStatus.InsecurePermissions);
    }

    private static DeviceProfile CreateProfile(
        string wifiHost,
        string tokenPath,
        string fingerprint) =>
        new(
            DeviceProfile.CurrentSchema,
            Alias,
            fingerprint,
            wifiHost,
            "{E70BF7D9-4131-4270-B14E-B189132C3980}",
            "validation-network-identity",
            new DeviceProfileFilesTarget("127.0.0.1", 80),
            tokenPath,
            new DeviceProfileVerification(
                DateTimeOffset.UtcNow,
                Guid.NewGuid().ToString("D"),
                "/dev/mmcblk0p2",
                "IMG_VERSION=3.28.0.162;VERSION_ID=5.8.198",
                "5.8.198",
                "rmmirror.wake/v1",
                "0.6.0"));

    private static void WriteKnownHost(string path, string host, byte[] keyBlob) =>
        WriteKnownHosts(path, KnownHostLine(host, keyBlob));

    private static string KnownHostLine(string host, byte[] keyBlob) =>
        $"{host} ssh-ed25519 {Convert.ToBase64String(keyBlob)}";

    private static void WriteKnownHosts(string path, params string[] lines) =>
        File.WriteAllText(
            path,
            string.Join(Environment.NewLine, lines) + Environment.NewLine,
            new UTF8Encoding(false));

    private static string Fingerprint(byte[] keyBlob) =>
        "SHA256:" + Convert.ToBase64String(SHA256.HashData(keyBlob)).TrimEnd('=');

    private static void RequireRejected(
        DeviceProfileLoadResult result,
        DeviceProfileLoadStatus expected)
    {
        Require(result.Status == expected && result.Profile is null);
    }

    private static bool HasCurrentUserOnlyAcl(string path)
    {
        var sid = WindowsIdentity.GetCurrent().User;
        if (sid is null)
        {
            return false;
        }

        var security = FileSystemAclExtensions.GetAccessControl(new FileInfo(path));
        if (!security.AreAccessRulesProtected ||
            !sid.Equals(security.GetOwner(typeof(SecurityIdentifier))))
        {
            return false;
        }

        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier));
        return rules.Count == 1 &&
            rules[0] is FileSystemAccessRule rule &&
            rule.AccessControlType == AccessControlType.Allow &&
            sid.Equals(rule.IdentityReference) &&
            (rule.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl;
    }

    private static void Require(bool condition)
    {
        if (!condition)
        {
            throw new InvalidOperationException("A profile-store invariant failed.");
        }
    }
}
'@

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    [System.IO.File]::WriteAllText(
        $projectPath,
        $project,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $programPath,
        $program,
        [System.Text.UTF8Encoding]::new($false)
    )

    & dotnet run `
        --project $projectPath `
        --configuration Release `
        -- `
        $temporaryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Device-profile validation failed with exit code $LASTEXITCODE."
    }

    $installerPath = Join-Path $repositoryRoot 'scripts\Install-RemarkableMirrorPrerequisites.ps1'
    $installerTokens = $null
    $installerErrors = $null
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $installerPath,
        [ref]$installerTokens,
        [ref]$installerErrors
    )
    if ($installerErrors.Count -ne 0) {
        throw 'The prerequisite installer did not parse.'
    }
    foreach ($functionName in @(
            'Set-CurrentUserOnlyAcl',
            'Test-CurrentUserOnlyAcl',
            'Set-PrivateTokenFile'
        )) {
        $functionAst = $installerAst.Find(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            },
            $true
        )
        if ($null -eq $functionAst) {
            throw 'A required local-persistence function was not found.'
        }
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [System.Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (-not $currentPrincipal.IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator
        )) {
        # PowerShell 7.6 can request SeSecurityPrivilege when Set-Acl reapplies a
        # protected descriptor. The real installer runs elevated; this harness
        # keeps its standard-user coverage by persisting the same file ACL
        # directly, without requesting access to the system audit ACL.
        function Set-Acl {
            param(
                [Parameter(Mandatory)][string]$LiteralPath,
                [Parameter(Mandatory)]
                [System.Security.AccessControl.FileSecurity]$AclObject
            )

            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.FileInfo]::new(
                    [System.IO.Path]::GetFullPath($LiteralPath)
                ),
                $AclObject
            )
        }
    }

    $tokenPath = Join-Path $temporaryRoot 'local-wake-token'
    $firstToken = 'a' * 64
    $secondToken = 'b' * 64
    $publishedPath = Set-PrivateTokenFile -Path $tokenPath -Token $firstToken
    if ($publishedPath -cne $tokenPath -or
        [System.IO.File]::ReadAllText($tokenPath) -cne $firstToken) {
        throw 'The first atomic wake-token publication failed.'
    }
    $publishedPath = Set-PrivateTokenFile -Path $tokenPath -Token $secondToken
    $tokenItem = Get-Item -LiteralPath $tokenPath -Force
    if ($publishedPath -cne $tokenPath -or
        [System.IO.File]::ReadAllText($tokenPath) -cne $secondToken -or
        -not (Test-CurrentUserOnlyAcl -Item $tokenItem) -or
        @(Get-ChildItem -LiteralPath $temporaryRoot -Filter '*.tmp' -File).Count -ne 0) {
        throw 'The replacement wake-token publication failed.'
    }
    Write-Output 'WakeTokenAtomicPublish: PASS'
}
finally {
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedTemporaryRoot).StartsWith(
            'rmmirror-profile-validation-',
            [StringComparison]::Ordinal
        ) -and
        [System.IO.Directory]::Exists($resolvedTemporaryRoot)) {
        [System.IO.Directory]::Delete($resolvedTemporaryRoot, $true)
    }
}
