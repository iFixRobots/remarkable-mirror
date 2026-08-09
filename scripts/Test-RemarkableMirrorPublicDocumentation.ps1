#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$markdownFiles = @(
    Get-ChildItem -LiteralPath $repositoryRoot -File -Filter '*.md'
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'docs') -Recurse -File -Filter '*.md'
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'mirror') -Recurse -File -Filter 'README.md'
) | Sort-Object -Property FullName -Unique

if ($markdownFiles.Count -eq 0) {
    throw 'No public Markdown files were found.'
}

$readmePath = Join-Path $repositoryRoot 'README.md'
$readme = [regex]::Replace(
    [System.IO.File]::ReadAllText($readmePath),
    '\s+',
    ' '
)
$platformContract =
    'reMarkable Mirror has native desktop apps for Windows and macOS. ' +
    'Both connect over authenticated SSH to small ARM64 Linux components ' +
    'running on the reMarkable tablet. The Windows app has a complete ' +
    'installer and setup path; the macOS app is currently an unsigned ' +
    'development build.'
if (-not $readme.Contains($platformContract, [StringComparison]::Ordinal)) {
    throw 'README is missing the approved public platform description.'
}

$gettingStartedPath = Join-Path $repositoryRoot 'docs\GETTING_STARTED.md'
$gettingStarted = [System.IO.File]::ReadAllText($gettingStartedPath)
if (-not $gettingStarted.Contains(
        '[System.IO.FileSystemAclExtensions]::SetAccessControl($keyFile, $acl)',
        [StringComparison]::Ordinal
    ) -or
    $gettingStarted.Contains(
        'Set-Acl -LiteralPath $key -AclObject $acl',
        [StringComparison]::Ordinal
    )) {
    throw 'The pairing guide must use the repeat-safe private-key ACL path.'
}

$releasing = [System.IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'docs\RELEASING.md')
)
if (-not $releasing.Contains(
        'Review the complete reachable Git history, not only the current tree.',
        [StringComparison]::Ordinal
    ) -or
    -not $releasing.Contains(
        'Deleting a file from the tip is not history sanitization.',
        [StringComparison]::Ordinal
    )) {
    throw 'The public-release gate must review reachable Git history.'
}

$aclTestRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('rmmirror-doc-acl-' + [guid]::NewGuid().ToString('N'))
try {
    [void][System.IO.Directory]::CreateDirectory($aclTestRoot)
    $aclTestPath = Join-Path $aclTestRoot 'mirror-key'
    [System.IO.File]::WriteAllText($aclTestPath, 'test-only')
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
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
    $aclTestFile = [System.IO.FileInfo]::new($aclTestPath)
    [System.IO.FileSystemAclExtensions]::SetAccessControl($aclTestFile, $acl)
    [System.IO.FileSystemAclExtensions]::SetAccessControl($aclTestFile, $acl)
}
finally {
    if (Test-Path -LiteralPath $aclTestRoot) {
        Remove-Item -LiteralPath $aclTestRoot -Recurse -Force
    }
}

$linkFailures = [System.Collections.Generic.List[string]]::new()
$powerShellFailures = [System.Collections.Generic.List[string]]::new()
$stalePhraseFailures = [System.Collections.Generic.List[string]]::new()
$offlineLinkFailures = [System.Collections.Generic.List[string]]::new()
$powerShellBlockCount = 0
$fence = [regex]::Escape(([string][char]96) * 3)

foreach ($file in $markdownFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $relativeFile = [System.IO.Path]::GetRelativePath(
        $repositoryRoot,
        $file.FullName
    )

    foreach ($stalePhrase in @(
            'prepared-tablet preview',
            'experimental native preview',
            'macOS preview',
            'reconnects automatically',
            'wait for the app to reconnect',
            'tablet-sized'
        )) {
        if ($text.Contains(
                $stalePhrase,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $stalePhraseFailures.Add("$relativeFile -> $stalePhrase")
        }
    }

    if ($text -match '(?i)C:\\Users\\(?!Example\\)') {
        $stalePhraseFailures.Add("$relativeFile -> rooted Windows user path")
    }

    $linkText = [regex]::Replace(
        $text,
        '(?ms)^' + $fence + '[^\r\n]*\r?\n.*?^' + $fence + '\s*$',
        ''
    )
    $linkMatches = [regex]::Matches(
        $linkText,
        '(?<!\!)\[[^\]]+\]\(([^)]+)\)|!\[[^\]]*\]\(([^)]+)\)|<img\s+[^>]*src="([^"]+)"'
    )
    foreach ($match in $linkMatches) {
        $target = @(
            $match.Groups[1].Value
            $match.Groups[2].Value
            $match.Groups[3].Value
        ) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($target) -or
            $target.StartsWith('#') -or
            $target -match '^(?i:https?|mailto):') {
            continue
        }

        $pathPart = [uri]::UnescapeDataString(($target -split '#', 2)[0])
        if ([string]::IsNullOrWhiteSpace($pathPart)) {
            continue
        }
        $resolved = [System.IO.Path]::GetFullPath(
            (Join-Path $file.DirectoryName (
                $pathPart -replace '/', [System.IO.Path]::DirectorySeparatorChar
            ))
        )
        if (-not (Test-Path -LiteralPath $resolved)) {
            $linkFailures.Add("$relativeFile -> $target")
        }
    }

    $powerShellBlocks = [regex]::Matches(
        $text,
        '(?ms)^' + $fence + '(?:powershell|pwsh)\s*\r?\n(.*?)^' +
            $fence + '\s*$'
    )
    foreach ($block in $powerShellBlocks) {
        $powerShellBlockCount++
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $block.Groups[1].Value,
            "$relativeFile PowerShell block $powerShellBlockCount",
            [ref]$tokens,
            [ref]$errors
        )
        foreach ($parseError in $errors) {
            $powerShellFailures.Add(
                "$relativeFile -> $($parseError.Message)"
            )
        }
    }
}

$offlinePackageDocuments = [ordered]@{
    'docs\PACKAGE_ONBOARDING.md' = 'ONBOARDING.md'
    'docs\GETTING_STARTED.md' = 'GETTING_STARTED.md'
    'docs\TROUBLESHOOTING.md' = 'TROUBLESHOOTING.md'
    'docs\PLATFORM_SUPPORT.md' = 'PLATFORM_SUPPORT.md'
    'docs\TABLET_CHANGES.md' = 'TABLET_CHANGES.md'
    'docs\UNINSTALL.md' = 'UNINSTALL.md'
}
$offlineMembers = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($destination in $offlinePackageDocuments.Values) {
    [void]$offlineMembers.Add($destination)
}
foreach ($image in @(
        'images/remarkable-mirror-live-wifi.png',
        'images/remarkable-mirror-preparing.png'
    )) {
    [void]$offlineMembers.Add($image)
}

foreach ($entry in $offlinePackageDocuments.GetEnumerator()) {
    $sourcePath = Join-Path $repositoryRoot $entry.Key
    $text = [System.IO.File]::ReadAllText($sourcePath)
    $linkText = [regex]::Replace(
        $text,
        '(?ms)^' + $fence + '[^\r\n]*\r?\n.*?^' + $fence + '\s*$',
        ''
    )
    $linkMatches = [regex]::Matches(
        $linkText,
        '(?<!\!)\[[^\]]+\]\(([^)]+)\)|!\[[^\]]*\]\(([^)]+)\)|<img\s+[^>]*src="([^"]+)"'
    )
    foreach ($match in $linkMatches) {
        $target = @(
            $match.Groups[1].Value
            $match.Groups[2].Value
            $match.Groups[3].Value
        ) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($target) -or
            $target.StartsWith('#') -or
            $target -match '^(?i:https?|mailto):') {
            continue
        }
        $packageTarget = [uri]::UnescapeDataString(
            ($target -split '#', 2)[0]
        ).Replace('\', '/').TrimStart('./')
        if (-not $offlineMembers.Contains($packageTarget)) {
            $offlineLinkFailures.Add(
                "$($entry.Value) -> $target"
            )
        }
    }
}

if ($stalePhraseFailures.Count -gt 0) {
    throw ('Stale or private public-document wording:' +
        [Environment]::NewLine +
        ($stalePhraseFailures -join [Environment]::NewLine))
}
if ($linkFailures.Count -gt 0) {
    throw ('Broken relative Markdown links:' +
        [Environment]::NewLine +
        ($linkFailures -join [Environment]::NewLine))
}
if ($offlineLinkFailures.Count -gt 0) {
    throw ('Broken offline-package documentation links:' +
        [Environment]::NewLine +
        ($offlineLinkFailures -join [Environment]::NewLine))
}
if ($powerShellFailures.Count -gt 0) {
    throw ('Invalid documented PowerShell:' +
        [Environment]::NewLine +
        ($powerShellFailures -join [Environment]::NewLine))
}

$summary = (
    'PASS: {0} public Markdown files, {1} PowerShell blocks, platform wording, ' +
    'source/offline links, and stale-language checks.'
) -f $markdownFiles.Count, $powerShellBlockCount
Write-Host $summary
