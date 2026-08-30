[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\tmp\mirror\agent'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\RemarkableGoBuild.ps1')

Build-RemarkableGoProgram `
    -SourceDirectory 'mirror\agent' `
    -Package './cmd/rmmirror-probe' `
    -BinaryName 'rmmirror-probe' `
    -OutputDirectory $OutputDirectory `
    -Force:$Force
