[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\tmp\mirror\transport-wake'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\RemarkableGoBuild.ps1')

Build-RemarkableGoProgram `
    -SourceDirectory 'mirror\agent' `
    -Package './cmd/rmmirror-transport-wake' `
    -BinaryName 'rmmirror-transport-wake' `
    -OutputDirectory $OutputDirectory `
    -Force:$Force
