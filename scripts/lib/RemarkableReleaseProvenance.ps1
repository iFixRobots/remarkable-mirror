Set-StrictMode -Version Latest

function Get-RemarkableReleaseProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Publisher,

        [string]$OfficialPublisher = 'CN=iFixRobots',

        [switch]$AllowDirtyOfficialDevelopmentBuild
    )

    $repositoryRootFull = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $gitTopLevel = ((& $git -C $repositoryRootFull rev-parse --show-toplevel 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or
        [string]::IsNullOrWhiteSpace($gitTopLevel) -or
        [System.IO.Path]::GetFullPath($gitTopLevel) -ne $repositoryRootFull) {
        throw 'Packaging source must be the root of a Git working tree.'
    }

    $sourceCommit = ((& $git -C $repositoryRootFull rev-parse --verify HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or
        $sourceCommit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw 'Packaging source has no committed HEAD. Create the initial commit before building release metadata.'
    }

    $sourceStatus = @(& $git -C $repositoryRootFull status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not determine whether the packaging source is dirty.'
    }
    $sourceDirty = $sourceStatus.Count -ne 0
    if ($Publisher -ieq $OfficialPublisher -and
        $sourceDirty -and
        -not $AllowDirtyOfficialDevelopmentBuild) {
        throw ('Official iFixRobots packages require a clean Git working tree. ' +
            'Commit or stash all tracked and untracked source changes, or pass ' +
            '-AllowDirtyOfficialDevelopmentBuild only for a local development artifact. ' +
            'release.json will record source_dirty=true.')
    }

    [pscustomobject]@{
        SourceCommit = $sourceCommit
        SourceDirty = $sourceDirty
    }
}
