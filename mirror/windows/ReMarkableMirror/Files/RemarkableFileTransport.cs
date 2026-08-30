using System.Buffers;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReMarkableMirror.Files;

public sealed class RemarkableFileTransport : IAsyncDisposable
{
    public const long MaximumUploadBytes = 100_000_000;

    private const string UploadSuccessPayload = "{\"status\":\"Upload successful\"}";
    private const int DownloadBufferBytes = 128 * 1024;
    private static readonly TimeSpan ListResponseHeaderTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ListResponseBodyTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan UploadResponseTimeout = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan UploadResponseBodyTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan UploadReconciliationTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan DownloadResponseHeaderTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan DownloadReadIdleTimeout = TimeSpan.FromSeconds(20);
    private static readonly HashSet<char> InvalidWindowsFileNameCharacters =
        Path.GetInvalidFileNameChars().ToHashSet();
    private static readonly HashSet<string> ReservedWindowsFileNames = new(
        [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ],
        StringComparer.OrdinalIgnoreCase);

    // Xochitl stores the selected upload folder as process-wide state. Every
    // API operation, across every transport instance, must therefore be ordered.
    private static readonly SemaphoreSlim ApiGate = new(1, 1);

    private readonly SshWebInterfaceTunnel _tunnel;
    private readonly HttpClient _httpClient;
    private bool _disposed;

    public RemarkableFileTransport(SshRoute route)
    {
        _tunnel = new SshWebInterfaceTunnel(
            route ?? throw new ArgumentNullException(nameof(route)));
        _httpClient = new HttpClient(
            new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                AutomaticDecompression = DecompressionMethods.None,
                ConnectTimeout = TimeSpan.FromSeconds(4),
                PooledConnectionLifetime = TimeSpan.FromMinutes(1),
                UseCookies = false,
                UseProxy = false,
            },
            disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public Task<IReadOnlyList<RemarkableLibraryItem>> ListRootAsync(
        CancellationToken cancellationToken = default) =>
        ExecuteSerializedAsync(
            "refresh the reMarkable file list",
            token => ListCoreAsync(string.Empty, token),
            cancellationToken);

    public Task<IReadOnlyList<RemarkableLibraryItem>> ListFolderAsync(
        string folderId,
        CancellationToken cancellationToken = default)
    {
        var normalizedFolderId = NormalizeRequiredId(folderId, "folder");
        return ExecuteSerializedAsync(
            "refresh the reMarkable folder",
            token => ListCoreAsync(normalizedFolderId, token),
            cancellationToken);
    }

    public Task<RemarkableUploadResult> UploadAsync(
        string sourcePath,
        string? destinationFolderId = null,
        CancellationToken cancellationToken = default)
    {
        var upload = ValidateUpload(sourcePath);
        var normalizedFolderId = NormalizeOptionalFolderId(destinationFolderId);
        return ExecuteSerializedAsync(
            "send the file to reMarkable",
            token => UploadCoreAsync(upload, normalizedFolderId, token),
            cancellationToken);
    }

    public Task<RemarkableDownloadResult> DownloadPdfToFileAsync(
        string documentId,
        string destinationPath,
        bool overwrite = false,
        CancellationToken cancellationToken = default) =>
        DownloadToFileAsync(
            documentId,
            DownloadRepresentation.Pdf,
            destinationPath,
            overwrite,
            cancellationToken);

    public Task<RemarkableDownloadResult> DownloadRmdocToFileAsync(
        string documentId,
        string destinationPath,
        bool overwrite = false,
        CancellationToken cancellationToken = default) =>
        DownloadToFileAsync(
            documentId,
            DownloadRepresentation.Rmdoc,
            destinationPath,
            overwrite,
            cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await ApiGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _httpClient.Dispose();
            await _tunnel.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            ApiGate.Release();
        }
    }

    private async Task<RemarkableUploadResult> UploadCoreAsync(
        UploadFile upload,
        string destinationFolderId,
        CancellationToken cancellationToken)
    {
        await using var source = OpenUploadSource(upload);
        var boundary = $"----ReMarkableMirror{Guid.NewGuid():N}";
        using var multipart = new MultipartFormDataContent(boundary);
        multipart.Headers.Remove("Content-Type");
        multipart.Headers.TryAddWithoutValidation(
            "Content-Type",
            $"multipart/form-data; boundary={boundary}");
        using var fileContent = new StreamContent(source);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue(upload.ContentType);
        multipart.Add(fileContent, "file", upload.FileName);
        StockUploadMultipartHeaders.Normalize(fileContent);
        using var request = CreateRequest(HttpMethod.Post, "upload");
        request.Content = multipart;

        // This GET selects Xochitl's process-wide destination. The next HTTP
        // operation under the global gate is the upload itself.
        var before = await ListCoreAsync(destinationFolderId, cancellationToken)
            .ConfigureAwait(false);
        string responsePayload;
        try
        {
            using var response = await SendAsync(
                    request,
                    UploadResponseTimeout,
                    "The tablet upload stopped responding.",
                    cancellationToken)
                .ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.Created)
            {
                throw new FileTransferException(
                    FileTransferFailure.Rejected,
                    $"The tablet rejected the upload (HTTP {(int)response.StatusCode}).",
                    statusCode: response.StatusCode);
            }

            using var responseBodyCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            responseBodyCancellation.CancelAfter(UploadResponseBodyTimeout);
            try
            {
                responsePayload = await response.Content
                    .ReadAsStringAsync(responseBodyCancellation.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException exception)
                when (!cancellationToken.IsCancellationRequested)
            {
                throw new FileTransferException(
                    FileTransferFailure.Connection,
                    "The tablet upload confirmation stopped responding.",
                    exception);
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
        catch (FileTransferException exception)
            when (exception.Failure == FileTransferFailure.Connection)
        {
            return await ReconcileUnconfirmedUploadAsync(
                    before,
                    upload.FileName,
                    destinationFolderId,
                    exception,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (IOException exception)
        {
            return await ReconcileUnconfirmedUploadAsync(
                    before,
                    upload.FileName,
                    destinationFolderId,
                    exception,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        if (!string.Equals(
                responsePayload,
                UploadSuccessPayload,
                StringComparison.Ordinal))
        {
            return await ReconcileUnconfirmedUploadAsync(
                    before,
                    upload.FileName,
                    destinationFolderId,
                    new FileTransferException(
                        FileTransferFailure.Protocol,
                        "The tablet returned an unexpected upload confirmation."),
                    cancellationToken)
                .ConfigureAwait(false);
        }

        return await ReconcileConfirmedUploadAsync(
                before,
                upload.FileName,
                destinationFolderId,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<RemarkableUploadResult> ReconcileConfirmedUploadAsync(
        IReadOnlyList<RemarkableLibraryItem> before,
        string sourceFileName,
        string destinationFolderId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<RemarkableLibraryItem> after;
        using var reconciliationCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        reconciliationCancellation.CancelAfter(UploadReconciliationTimeout);
        try
        {
            after = await ListCoreAsync(
                    destinationFolderId,
                    reconciliationCancellation.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is FileTransferException or HttpRequestException or IOException or JsonException or OperationCanceledException)
        {
            throw new FileTransferException(
                FileTransferFailure.AmbiguousResult,
                "The tablet accepted the upload, but its new document could not be identified. Refresh before retrying.",
                exception);
        }

        cancellationToken.ThrowIfCancellationRequested();
        var uploadedItem = ResolveUploadedItem(before, after, destinationFolderId);
        return new RemarkableUploadResult(
            sourceFileName,
            destinationFolderId,
            uploadedItem);
    }

    private async Task<RemarkableUploadResult> ReconcileUnconfirmedUploadAsync(
        IReadOnlyList<RemarkableLibraryItem> before,
        string sourceFileName,
        string destinationFolderId,
        Exception originalFailure,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<RemarkableLibraryItem> after;
        using var reconciliationCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        reconciliationCancellation.CancelAfter(UploadReconciliationTimeout);
        try
        {
            after = await ListCoreAsync(
                    destinationFolderId,
                    reconciliationCancellation.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is FileTransferException or HttpRequestException or IOException or JsonException or OperationCanceledException)
        {
            throw new FileTransferException(
                FileTransferFailure.AmbiguousResult,
                "The upload response was lost and the tablet could not be reconciled. Refresh the destination before retrying.",
                new AggregateException(originalFailure, exception));
        }

        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            _ = ResolveUploadedItem(before, after, destinationFolderId);
        }
        catch (FileTransferException exception)
            when (exception.Failure == FileTransferFailure.AmbiguousResult)
        {
            throw new FileTransferException(
                FileTransferFailure.AmbiguousResult,
                "The upload response was not exact and its result is unknown. Refresh the destination before retrying.",
                new AggregateException(originalFailure, exception));
        }

        throw new FileTransferException(
            FileTransferFailure.AmbiguousResult,
            $"A new document appeared after sending {sourceFileName}, but the tablet response was not exact. Refresh before retrying.",
            originalFailure);
    }

    private static RemarkableLibraryItem ResolveUploadedItem(
        IReadOnlyList<RemarkableLibraryItem> before,
        IReadOnlyList<RemarkableLibraryItem> after,
        string destinationFolderId)
    {
        var beforeIds = before.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        var added = after.Where(item => !beforeIds.Contains(item.Id)).ToList();
        if (added.Count != 1)
        {
            throw new FileTransferException(
                FileTransferFailure.AmbiguousResult,
                $"The tablet accepted the upload, but {added.Count} new items were found. Refresh before retrying.");
        }

        var uploadedItem = added[0];
        if (uploadedItem.Kind != RemarkableLibraryItemKind.Document ||
            !string.Equals(
                uploadedItem.ParentId,
                destinationFolderId,
                StringComparison.Ordinal))
        {
            throw new FileTransferException(
                FileTransferFailure.AmbiguousResult,
                "The uploaded item did not appear as a document in the selected destination. Refresh before retrying.");
        }

        return uploadedItem;
    }

    private async Task<IReadOnlyList<RemarkableLibraryItem>> ListCoreAsync(
        string folderId,
        CancellationToken cancellationToken)
    {
        var path = string.IsNullOrEmpty(folderId)
            ? "documents/"
            : $"documents/{Uri.EscapeDataString(folderId)}";
        using var request = CreateRequest(HttpMethod.Get, path);
        using var response = await SendAsync(
                request,
                ListResponseHeaderTimeout,
                "The tablet file list stopped responding.",
                cancellationToken)
            .ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new FileTransferException(
                FileTransferFailure.Rejected,
                $"The tablet could not list that folder (HTTP {(int)response.StatusCode}).",
                statusCode: response.StatusCode);
        }

        List<ListingItemDto>? items;
        using var responseBodyCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        responseBodyCancellation.CancelAfter(ListResponseBodyTimeout);
        try
        {
            await using var responseStream = await response.Content
                .ReadAsStreamAsync(responseBodyCancellation.Token)
                .ConfigureAwait(false);
            items = await JsonSerializer.DeserializeAsync<List<ListingItemDto>>(
                    responseStream,
                    cancellationToken: responseBodyCancellation.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException exception)
            when (!cancellationToken.IsCancellationRequested)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet file-list response stopped responding.",
                exception);
        }
        catch (OperationCanceledException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
        catch (JsonException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                "The tablet returned an invalid file listing.",
                exception);
        }

        if (items is null)
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                "The tablet returned an empty file-list response.");
        }

        var result = new List<RemarkableLibraryItem>(items.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < items.Count; index++)
        {
            var item = MapListingItem(items[index], index);
            if (!string.Equals(item.ParentId, folderId, StringComparison.Ordinal))
            {
                throw new FileTransferException(
                    FileTransferFailure.Protocol,
                    "The tablet returned an item outside the requested folder.");
            }

            if (!ids.Add(item.Id))
            {
                throw new FileTransferException(
                    FileTransferFailure.Protocol,
                    "The tablet returned a duplicate document identifier.");
            }

            result.Add(item);
        }

        return result;
    }

    private Task<RemarkableDownloadResult> DownloadToFileAsync(
        string documentId,
        DownloadRepresentation representation,
        string destinationPath,
        bool overwrite,
        CancellationToken cancellationToken)
    {
        var normalizedDocumentId = NormalizeRequiredId(documentId, "document");
        var fullDestinationPath = NormalizeDestinationPath(destinationPath);
        return ExecuteSerializedAsync(
            "download the reMarkable document",
            token => DownloadFileCoreAsync(
                normalizedDocumentId,
                representation,
                fullDestinationPath,
                overwrite,
                token),
            cancellationToken);
    }

    private async Task<RemarkableDownloadResult> DownloadFileCoreAsync(
        string documentId,
        DownloadRepresentation representation,
        string destinationPath,
        bool overwrite,
        CancellationToken cancellationToken)
    {
        if (!overwrite && File.Exists(destinationPath))
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "A file already exists at the selected destination.");
        }

        var directory = Path.GetDirectoryName(destinationPath);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "The selected destination folder does not exist.");
        }

        var partialPath = Path.Combine(
            directory,
            $".{Path.GetFileName(destinationPath)}.{Guid.NewGuid():N}.partial");
        var published = false;
        try
        {
            RemarkableDownloadResult download;
            await using (var destination = new FileStream(
                partialPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                DownloadBufferBytes,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                download = await DownloadCoreAsync(
                        documentId,
                        representation,
                        destination,
                        cancellationToken)
                    .ConfigureAwait(false);
                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(partialPath, destinationPath, overwrite);
            published = true;
            return download with { SavedPath = destinationPath };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (FileTransferException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "Windows could not save the downloaded file.",
                exception);
        }
        finally
        {
            if (!published)
            {
                try
                {
                    File.Delete(partialPath);
                }
                catch (Exception exception) when (
                    exception is IOException or UnauthorizedAccessException)
                {
                }
            }
        }
    }

    private async Task<RemarkableDownloadResult> DownloadCoreAsync(
        string documentId,
        DownloadRepresentation representation,
        Stream destination,
        CancellationToken cancellationToken)
    {
        var suffix = representation == DownloadRepresentation.Pdf ? "pdf" : "rmdoc";
        using var request = CreateRequest(
            HttpMethod.Get,
            $"download/{Uri.EscapeDataString(documentId)}/{suffix}");
        using var response = await SendAsync(
                request,
                DownloadResponseHeaderTimeout,
                $"The tablet did not start the {suffix.ToUpperInvariant()} download in time.",
                cancellationToken)
            .ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new FileTransferException(
                FileTransferFailure.Rejected,
                $"The tablet could not prepare that {suffix.ToUpperInvariant()} download (HTTP {(int)response.StatusCode}).",
                statusCode: response.StatusCode);
        }

        var suggestedFileName = ReadSuggestedFileName(response);
        var expectedBytes = response.Content.Headers.ContentLength;
        await using var source = await ReadDownloadStreamAsync(
                response.Content,
                cancellationToken)
            .ConfigureAwait(false);
        var buffer = ArrayPool<byte>.Shared.Rent(DownloadBufferBytes);
        var idleCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        long bytesWritten = 0;
        try
        {
            while (true)
            {
                int read;
                try
                {
                    if (idleCancellation.IsCancellationRequested &&
                        !cancellationToken.IsCancellationRequested)
                    {
                        idleCancellation.Dispose();
                        idleCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                            cancellationToken);
                    }
                    idleCancellation.CancelAfter(DownloadReadIdleTimeout);
                    read = await source.ReadAsync(
                            buffer.AsMemory(0, DownloadBufferBytes),
                            idleCancellation.Token)
                        .ConfigureAwait(false);
                    idleCancellation.CancelAfter(Timeout.InfiniteTimeSpan);
                }
                catch (OperationCanceledException exception)
                    when (!cancellationToken.IsCancellationRequested)
                {
                    throw new FileTransferException(
                        FileTransferFailure.Connection,
                        "The tablet download stopped sending data.",
                        exception);
                }
                catch (OperationCanceledException)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    throw;
                }
                catch (IOException exception)
                {
                    throw new FileTransferException(
                        FileTransferFailure.Connection,
                        "The tablet download connection closed before the file completed.",
                        exception);
                }

                if (read == 0)
                {
                    break;
                }

                try
                {
                    await destination.WriteAsync(
                            buffer.AsMemory(0, read),
                            cancellationToken)
                        .ConfigureAwait(false);
                    bytesWritten += read;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception exception) when (
                    exception is IOException or UnauthorizedAccessException or NotSupportedException)
                {
                    throw new FileTransferException(
                        FileTransferFailure.LocalFile,
                        "Windows could not write the downloaded file.",
                        exception);
                }
            }
        }
        finally
        {
            idleCancellation.Dispose();
            ArrayPool<byte>.Shared.Return(buffer);
        }

        if (expectedBytes.HasValue && bytesWritten != expectedBytes.Value)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet download ended before the complete file arrived.");
        }

        return new RemarkableDownloadResult(
            bytesWritten,
            suggestedFileName,
            SavedPath: null);
    }

    private async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        TimeSpan responseTimeout,
        string timeoutMessage,
        CancellationToken cancellationToken)
    {
        var baseUri = await _tunnel.GetBaseUriAsync(cancellationToken).ConfigureAwait(false);
        request.RequestUri = new Uri(baseUri, request.RequestUri!);
        using var responseCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        responseCancellation.CancelAfter(responseTimeout);
        try
        {
            return await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    responseCancellation.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException exception)
            when (!cancellationToken.IsCancellationRequested)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                timeoutMessage,
                exception);
        }
        catch (OperationCanceledException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
        catch (HttpRequestException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet file service is not available through the secure connection.",
                exception);
        }
    }

    private static async Task<Stream> ReadDownloadStreamAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        using var idleCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        idleCancellation.CancelAfter(DownloadReadIdleTimeout);
        try
        {
            return await content
                .ReadAsStreamAsync(idleCancellation.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException exception)
            when (!cancellationToken.IsCancellationRequested)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                "The tablet download stopped responding before data arrived.",
                exception);
        }
        catch (OperationCanceledException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
    }

    private async Task<T> ExecuteSerializedAsync<T>(
        string operation,
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await ApiGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return await action(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (FileTransferException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"The tablet returned invalid data while trying to {operation}.",
                exception);
        }
        catch (IOException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.Connection,
                $"The connection closed while trying to {operation}.",
                exception);
        }
        finally
        {
            ApiGate.Release();
        }
    }

    private async Task ExecuteSerializedAsync(
        string operation,
        Func<CancellationToken, Task> action,
        CancellationToken cancellationToken)
    {
        await ExecuteSerializedAsync(
                operation,
                async token =>
                {
                    await action(token).ConfigureAwait(false);
                    return true;
                },
                cancellationToken)
            .ConfigureAwait(false);
    }

    private static HttpRequestMessage CreateRequest(HttpMethod method, string path) =>
        new(method, new Uri(path, UriKind.Relative))
        {
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };

    private static RemarkableLibraryItem MapListingItem(ListingItemDto source, int index)
    {
        var itemNumber = index + 1;
        var id = NormalizeResponseId(source.Id, $"item {itemNumber} ID");
        var parent = ReadRequiredString(source.Parent, itemNumber, "Parent");
        var parentId = string.IsNullOrEmpty(parent)
            ? string.Empty
            : NormalizeResponseId(parent, $"item {itemNumber} parent");
        if (source.VisibleName is null && source.VissibleName is null)
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"Tablet item {itemNumber} has no visible name.");
        }

        var kind = source.Type switch
        {
            "DocumentType" => RemarkableLibraryItemKind.Document,
            "CollectionType" => RemarkableLibraryItemKind.Collection,
            _ => throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"Tablet item {itemNumber} has an unknown type."),
        };

        var currentPage = ReadOptionalInt(source.CurrentPage, itemNumber, "CurrentPage");
        if (kind == RemarkableLibraryItemKind.Document &&
            string.IsNullOrWhiteSpace(source.FileType))
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"Tablet document {itemNumber} has no file type.");
        }

        return new RemarkableLibraryItem(
            id,
            source.VisibleName,
            source.VissibleName,
            parentId,
            kind,
            source.Bookmarked,
            ReadOptionalScalar(source.ModifiedClient, itemNumber, "ModifiedClient"),
            currentPage,
            source.FileType);
    }

    private static int? ReadOptionalInt(JsonElement value, int itemNumber, string field)
    {
        if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number))
        {
            return number;
        }

        if (value.ValueKind == JsonValueKind.String &&
            int.TryParse(
                value.GetString(),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out number))
        {
            return number;
        }

        throw new FileTransferException(
            FileTransferFailure.Protocol,
            $"Tablet item {itemNumber} has an invalid {field} value.");
    }

    private static string? ReadOptionalScalar(
        JsonElement value,
        int itemNumber,
        string field)
    {
        if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.String)
        {
            return value.GetString();
        }

        if (value.ValueKind == JsonValueKind.Number)
        {
            return value.GetRawText();
        }

        throw new FileTransferException(
            FileTransferFailure.Protocol,
            $"Tablet item {itemNumber} has an invalid {field} value.");
    }

    private static string ReadRequiredString(
        JsonElement value,
        int itemNumber,
        string field)
    {
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"Tablet item {itemNumber} has an invalid {field} value.");
        }

        return value.GetString()!;
    }

    private static string? ReadSuggestedFileName(HttpResponseMessage response)
    {
        if (!response.Content.Headers.TryGetValues("Content-Disposition", out var headerValues))
        {
            return null;
        }

        var header = headerValues.FirstOrDefault();
        if (header is null || !ContentDispositionHeaderValue.TryParse(header, out var disposition))
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                "The tablet returned an invalid download filename.");
        }

        var candidate = disposition.FileNameStar ?? disposition.FileName;
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return null;
        }

        candidate = candidate.Trim();
        if (candidate.Length >= 2 && candidate[0] == '"' && candidate[^1] == '"')
        {
            candidate = candidate[1..^1]
                .Replace("\\\"", "\"", StringComparison.Ordinal)
                .Replace("\\\\", "\\", StringComparison.Ordinal);
        }

        const string utf8Prefix = "UTF-8''";
        if (candidate.StartsWith(utf8Prefix, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                candidate = Uri.UnescapeDataString(candidate[utf8Prefix.Length..]);
            }
            catch (UriFormatException)
            {
            }
        }

        var leafName = candidate
            .Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault();
        if (string.IsNullOrWhiteSpace(leafName) || leafName is "." or "..")
        {
            return null;
        }

        var safeCharacters = leafName
            .Select(character =>
                char.IsControl(character) ||
                InvalidWindowsFileNameCharacters.Contains(character)
                    ? '_'
                    : character)
            .ToArray();
        var safeName = new string(safeCharacters).Trim().TrimEnd('.');
        if (string.IsNullOrEmpty(safeName) || safeName is "." or "..")
        {
            return null;
        }

        var baseName = Path.GetFileNameWithoutExtension(safeName).TrimEnd(' ', '.');
        return ReservedWindowsFileNames.Contains(baseName)
            ? $"_{safeName}"
            : safeName;
    }

    private static FileStream OpenUploadSource(UploadFile upload)
    {
        try
        {
            return new FileStream(
                upload.FullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                DownloadBufferBytes,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
        }
        catch (FileNotFoundException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "The source file is no longer available.",
                exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "Windows cannot read the source file.",
                exception);
        }
        catch (IOException exception)
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "Windows could not read the source file.",
                exception);
        }
    }

    private static UploadFile ValidateUpload(string sourcePath)
    {
        if (string.IsNullOrWhiteSpace(sourcePath))
        {
            throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                "Choose a PDF or EPUB file to send.");
        }

        string fullPath;
        FileInfo file;
        string extension;
        string fileName;
        long length;
        try
        {
            fullPath = Path.GetFullPath(sourcePath);
            file = new FileInfo(fullPath);
            if (!file.Exists)
            {
                throw new FileTransferException(
                    FileTransferFailure.LocalFile,
                    "The selected source file does not exist.");
            }

            extension = file.Extension;
            fileName = file.Name;
            length = file.Length;
        }
        catch (FileTransferException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw new FileTransferException(
                FileTransferFailure.LocalFile,
                "Windows could not inspect the selected source file.",
                exception);
        }

        var contentType = extension.ToLowerInvariant() switch
        {
            ".pdf" => "application/pdf",
            ".epub" => "application/epub+zip",
            _ => throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                "Only PDF and EPUB files can be sent to the tablet."),
        };

        if (length > MaximumUploadBytes)
        {
            throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                "The tablet file service accepts files up to 100 MB.");
        }

        return new UploadFile(fullPath, fileName, contentType);
    }

    private static string NormalizeOptionalFolderId(string? folderId) =>
        string.IsNullOrWhiteSpace(folderId)
            ? string.Empty
            : NormalizeRequiredId(folderId, "destination folder");

    private static string NormalizeRequiredId(string id, string label)
    {
        if (!Guid.TryParse(id, out var parsed))
        {
            throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                $"The {label} identifier is invalid.");
        }

        return parsed.ToString("D");
    }

    private static string NormalizeResponseId(string? id, string label)
    {
        if (!Guid.TryParse(id, out var parsed))
        {
            throw new FileTransferException(
                FileTransferFailure.Protocol,
                $"The tablet returned an invalid {label}.");
        }

        return parsed.ToString("D");
    }

    private static string NormalizeDestinationPath(string destinationPath)
    {
        if (string.IsNullOrWhiteSpace(destinationPath))
        {
            throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                "Choose where to save the downloaded file.");
        }

        try
        {
            return Path.GetFullPath(destinationPath);
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw new FileTransferException(
                FileTransferFailure.InvalidRequest,
                "The selected download path is invalid.",
                exception);
        }
    }

    private sealed record UploadFile(
        string FullPath,
        string FileName,
        string ContentType);

    private sealed class ListingItemDto
    {
        [JsonPropertyName("Bookmarked")]
        public bool Bookmarked { get; init; }

        [JsonPropertyName("ID")]
        public string? Id { get; init; }

        [JsonPropertyName("ModifiedClient")]
        public JsonElement ModifiedClient { get; init; }

        [JsonPropertyName("Parent")]
        public JsonElement Parent { get; init; }

        [JsonPropertyName("Type")]
        public string? Type { get; init; }

        [JsonPropertyName("VisibleName")]
        public string? VisibleName { get; init; }

        [JsonPropertyName("VissibleName")]
        public string? VissibleName { get; init; }

        [JsonPropertyName("CurrentPage")]
        public JsonElement CurrentPage { get; init; }

        [JsonPropertyName("fileType")]
        public string? FileType { get; init; }
    }

    private enum DownloadRepresentation
    {
        Pdf,
        Rmdoc,
    }
}
