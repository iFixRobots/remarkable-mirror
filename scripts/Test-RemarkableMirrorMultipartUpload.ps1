param(
    [string]$HeaderSourcePath = (
        Join-Path $PSScriptRoot '..\mirror\windows\ReMarkableMirror\Files\StockUploadMultipartHeaders.cs'
    )
)

$ErrorActionPreference = 'Stop'

$resolvedHeaderSourcePath = (Resolve-Path -LiteralPath $HeaderSourcePath).Path
$assembliesBefore = [AppDomain]::CurrentDomain.GetAssemblies()
$null = Add-Type -Path $resolvedHeaderSourcePath -PassThru
$headerAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_ -notin $assembliesBefore -and $_.GetType('ReMarkableMirror.Files.StockUploadMultipartHeaders', $false) } |
    Select-Object -First 1
if ($null -eq $headerAssembly) {
    throw 'Could not load the production multipart header normalizer.'
}
$headerType = $headerAssembly.GetType(
    'ReMarkableMirror.Files.StockUploadMultipartHeaders',
    $true)
$normalizeMethod = $headerType.GetMethod(
    'Normalize',
    [System.Reflection.BindingFlags]'Static, NonPublic')
if ($null -eq $normalizeMethod) {
    throw 'The production multipart header normalizer is missing.'
}

$cases = @(
    'plain.pdf',
    'plain.epub',
    'with space.pdf',
    [string]::Concat([char]0x00E9, 'tude.epub')
)
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($fileName in $cases) {
    $boundary = "----ReMarkableMirror$([Guid]::NewGuid().ToString('N'))"
    $multipart = [System.Net.Http.MultipartFormDataContent]::new($boundary)
    $fileContent = [System.Net.Http.ByteArrayContent]::new([byte[]](1, 2, 3))
    try {
        $null = $multipart.Headers.Remove('Content-Type')
        $null = $multipart.Headers.TryAddWithoutValidation(
            'Content-Type',
            "multipart/form-data; boundary=$boundary")
        $fileContent.Headers.ContentType =
            [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/pdf')
        $multipart.Add($fileContent, 'file', $fileName)

        $null = $normalizeMethod.Invoke($null, [object[]]@($fileContent))

        $disposition = $fileContent.Headers.ContentDisposition
        $serialized = $disposition.ToString()
        if ($serialized -notmatch '(?:^|;\s*)name="file"(?:;|$)') {
            $failures.Add("$fileName did not serialize name as a quoted file field: $serialized")
        }
        if ($serialized -notmatch '(?:^|;\s*)filename="(?:[^"\\]|\\.)*"(?:;|$)') {
            $failures.Add("$fileName did not serialize filename as a quoted parameter: $serialized")
        }
        if ($serialized -match '(?:^|;\s*)filename\*=') {
            $failures.Add("$fileName retained the unsupported filename* parameter: $serialized")
        }

        $contentType = ($multipart.Headers.GetValues('Content-Type') -join ',')
        if ($contentType -ne "multipart/form-data; boundary=$boundary") {
            $failures.Add("$fileName changed the required unquoted top-level boundary: $contentType")
        }
    }
    finally {
        $multipart.Dispose()
    }
}

if ($failures.Count -gt 0) {
    throw "Stock upload multipart regression failed:`n - $($failures -join "`n - ")"
}

Write-Output "PASS: stock upload multipart headers are exact for $($cases.Count) filename shapes."
