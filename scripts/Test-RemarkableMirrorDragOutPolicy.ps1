$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$filesPanePath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\Files\FilesPaneView.xaml.cs'
$sessionPath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\Files\LibraryDocumentDrag.cs'
$mainPagePath = Join-Path $repositoryRoot 'mirror\windows\ReMarkableMirror\MainPage.xaml.cs'

$filesPane = [System.IO.File]::ReadAllText($filesPanePath)
$dragStart = $filesPane.IndexOf('private void LibraryDocument_DragStarting(', [StringComparison]::Ordinal)
$dragEnd = $filesPane.IndexOf('private void LibraryDocument_DropCompleted(', [StringComparison]::Ordinal)
if ($dragStart -lt 0 -or $dragEnd -le $dragStart) {
    throw 'Could not isolate the Files drag-start handler.'
}
$dragHandler = $filesPane.Substring($dragStart, $dragEnd - $dragStart)

foreach ($forbidden in @(
        'async void LibraryDocument_DragStarting(',
        'await ',
        'GetDeferral()',
        'SetStorageItems(',
        'SetContentFromDataPackage()',
        'Preparing ',
        'Release to save'
    )) {
    if ($dragHandler.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "DragStarting must remain immediate. Found forbidden marker: $forbidden"
    }
}

foreach ($required in @(
        'e.Data.SetDataProvider(',
        'StandardDataFormats.StorageItems',
        'e.Data.Properties.FileTypes.Add(".pdf")',
        'e.Data.SetData(OutboundDocumentDragFormat, "1")'
    )) {
    if (-not $dragHandler.Contains($required, [StringComparison]::Ordinal)) {
        throw "DragStarting is missing the delayed file marker: $required"
    }
}

$session = [System.IO.File]::ReadAllText($sessionPath)
foreach ($required in @(
        'request.GetDeferral()',
        'Task.Run(',
        'request.SetData(new IStorageItem[] { preparedDrag.File })',
        'deferral.Complete()',
        'request.Deadline'
    )) {
    if (-not $session.Contains($required, [StringComparison]::Ordinal)) {
        throw "Delayed file delivery is missing a required marker: $required"
    }
}

$mainPage = [System.IO.File]::ReadAllText($mainPagePath)
foreach ($forbidden in @(
        'PrepareLibraryDocumentDragAsync',
        'Preparing PDF over',
        'Release to save'
    )) {
    if ($mainPage.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "The retired pre-drag preparation flow is still present: $forbidden"
    }
}
if (-not $mainPage.Contains(
        'e.DataView.Contains(FilesPaneView.OutboundDocumentDragFormat)',
        [StringComparison]::Ordinal)) {
    throw 'The inbound Files target must reject Mirror outbound drags.'
}

$materializeStart = $mainPage.IndexOf(
    'private async Task<PreparedLibraryDocumentDrag?> MaterializeLibraryDocumentDragAsync(',
    [StringComparison]::Ordinal)
$materializeEnd = $mainPage.IndexOf(
    'private void ShowLibraryDocumentDragError(',
    [StringComparison]::Ordinal)
if ($materializeStart -lt 0 -or $materializeEnd -le $materializeStart) {
    throw 'Could not isolate the delayed drag materializer.'
}
$materializer = $mainPage.Substring($materializeStart, $materializeEnd - $materializeStart)
foreach ($forbidden in @(
        'Interlocked.CompareExchange(',
        'Finish the current export, then drag again.'
    )) {
    if ($materializer.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "A canceled drag can still reject an immediate retry: $forbidden"
    }
}
foreach ($required in @(
        '_exportGate.WaitAsync(cancellationToken)',
        '_exportGate.Release()'
    )) {
    if (-not $materializer.Contains($required, [StringComparison]::Ordinal)) {
        throw "The delayed drag materializer is missing serialized retry handling: $required"
    }
}

Write-Host 'REMARKABLE_MIRROR_DRAG_OUT_POLICY_PASS'
