using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security;
using System.Text.Json;
using ReMarkableMirror.Files;

namespace ReMarkableMirror;

public sealed record TabletBackupProgress(int Completed, int Total);

public sealed record TabletBackupResult(int Count, string Destination);

public sealed class TabletBackupException : Exception
{
    public TabletBackupException(string message)
        : base(message)
    {
    }
}

/// <summary>
/// Copies every document off the tablet's stock USB web interface as a
/// full-fidelity .rmdoc archive, and puts .rmdoc files back through the same
/// interface. A stock tablet serves the interface on the cable address, so
/// backup works before Developer Mode with only the Settings toggle and the
/// cable. A Mirror-provisioned tablet keeps the interface loopback-only, so
/// the service reaches it through the same SSH tunnel the Files browser uses.
/// </summary>
public sealed class TabletBackupService : IDisposable
{
    private const string BackupFolderName = "reMarkable Backup";

    private readonly HttpClient _http = new()
    {
        Timeout = TimeSpan.FromSeconds(120),
    };

    public void Dispose() => _http.Dispose();

    private async Task<(Uri BaseUri, SshWebInterfaceTunnel? Tunnel)> ResolveTransportAsync(
        CancellationToken cancellationToken)
    {
        using (var directProbe = new TcpClient())
        {
            try
            {
                var connect = directProbe.ConnectAsync("10.11.99.1", 80, cancellationToken)
                    .AsTask();
                var finished = await Task.WhenAny(
                        connect,
                        Task.Delay(TimeSpan.FromSeconds(2), cancellationToken))
                    .ConfigureAwait(false) == connect;
                if (finished && connect.IsCompletedSuccessfully && directProbe.Connected)
                {
                    return (new Uri("http://10.11.99.1/"), null);
                }
            }
            catch (SocketException)
            {
            }
        }

        var route = new SshRoute("10.11.99.1", filesTargetHost: "127.0.0.1");
        if (!route.CredentialFilesExist)
        {
            throw new TabletBackupException(
                "The tablet isn’t answering over USB-C. Turn on Settings > Storage > " +
                "USB web interface, reconnect the cable, and try again.");
        }

        var tunnel = new SshWebInterfaceTunnel(route);
        try
        {
            var baseUri = await tunnel.GetBaseUriAsync(cancellationToken)
                .ConfigureAwait(false);
            return (baseUri, tunnel);
        }
        catch (FileTransferException exception)
        {
            await tunnel.DisposeAsync().ConfigureAwait(false);
            throw new TabletBackupException(exception.Message);
        }
        catch
        {
            await tunnel.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task<TabletBackupResult> BackUpAllDocumentsAsync(
        IProgress<TabletBackupProgress>? progress,
        CancellationToken cancellationToken)
    {
        var (baseUri, tunnel) = await ResolveTransportAsync(cancellationToken)
            .ConfigureAwait(false);
        try
        {
            return await BackUpAllDocumentsAsync(baseUri, progress, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            if (tunnel is not null)
            {
                await tunnel.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private async Task<TabletBackupResult> BackUpAllDocumentsAsync(
        Uri baseUri,
        IProgress<TabletBackupProgress>? progress,
        CancellationToken cancellationToken)
    {
        var documents = await CollectDocumentsAsync(
                baseUri,
                folderId: string.Empty,
                path: [],
                cancellationToken)
            .ConfigureAwait(false);
        var destination = MakeDestination();

        var completed = 0;
        foreach (var document in documents)
        {
            var folder = document.Path.Aggregate(destination, Path.Combine);
            try
            {
                Directory.CreateDirectory(folder);
            }
            catch (Exception exception) when (exception is
                IOException or UnauthorizedAccessException or NotSupportedException)
            {
                folder = destination;
            }

            var file = Path.Combine(folder, $"{document.Name}.rmdoc");
            byte[] data;
            try
            {
                data = await _http.GetByteArrayAsync(
                        new Uri(baseUri, $"download/{document.Id}/rmdoc"),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception) when (exception is
                HttpRequestException or TaskCanceledException)
            {
                throw DocumentFailed(document.Name);
            }
            if (data.Length == 0)
            {
                throw DocumentFailed(document.Name);
            }
            try
            {
                await File.WriteAllBytesAsync(file, data, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is
                IOException or UnauthorizedAccessException or NotSupportedException)
            {
                throw new TabletBackupException(
                    "The backup folder couldn’t be created in Documents.");
            }

            completed++;
            progress?.Report(new TabletBackupProgress(completed, documents.Count));
        }

        return new TabletBackupResult(documents.Count, destination);
    }

    /// <summary>
    /// Uploads every .rmdoc under the folder back to the tablet through the
    /// stock USB web interface. The interface places uploads in the tablet's
    /// home; folder structure is not recreated.
    /// </summary>
    public async Task<int> RestoreAllDocumentsAsync(
        string folder,
        IProgress<TabletBackupProgress>? progress,
        CancellationToken cancellationToken)
    {
        var files = RmdocFiles(folder);
        if (files.Count == 0)
        {
            throw new TabletBackupException(
                "That folder has no .rmdoc backup files in it.");
        }

        var (baseUri, tunnel) = await ResolveTransportAsync(cancellationToken)
            .ConfigureAwait(false);
        try
        {
            // Prove the interface answers before the first upload mutates anything.
            _ = await ListAsync(baseUri, string.Empty, cancellationToken).ConfigureAwait(false);

            var completed = 0;
            foreach (var file in files)
            {
                await UploadAsync(baseUri, file, cancellationToken).ConfigureAwait(false);
                completed++;
                progress?.Report(new TabletBackupProgress(completed, files.Count));
            }
            return files.Count;
        }
        finally
        {
            if (tunnel is not null)
            {
                await tunnel.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    public static string? LatestBackupFolder()
    {
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                BackupFolderName);
            if (!Directory.Exists(root))
            {
                return null;
            }
            return Directory.EnumerateDirectories(root)
                .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
                .FirstOrDefault();
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or SecurityException or
            NotSupportedException or ArgumentException)
        {
            return null;
        }
    }

    private sealed record FoundDocument(string Id, string Name, string[] Path);

    private async Task<List<FoundDocument>> CollectDocumentsAsync(
        Uri baseUri,
        string folderId,
        string[] path,
        CancellationToken cancellationToken)
    {
        var listing = await ListAsync(baseUri, folderId, cancellationToken).ConfigureAwait(false);
        var found = new List<FoundDocument>();
        foreach (var (id, name, isFolder) in listing)
        {
            if (isFolder)
            {
                found.AddRange(await CollectDocumentsAsync(
                        baseUri,
                        id,
                        [.. path, name],
                        cancellationToken)
                    .ConfigureAwait(false));
            }
            else
            {
                found.Add(new FoundDocument(id, name, path));
            }
        }
        return found;
    }

    private async Task<List<(string Id, string Name, bool IsFolder)>> ListAsync(
        Uri baseUri,
        string folderId,
        CancellationToken cancellationToken)
    {
        byte[] payload;
        try
        {
            payload = await _http.GetByteArrayAsync(
                    new Uri(baseUri, $"documents/{folderId}"),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is
            HttpRequestException or TaskCanceledException)
        {
            throw new TabletBackupException(
                "The tablet isn’t answering over USB-C. Turn on Settings > Storage > " +
                "USB web interface, reconnect the cable, and try again.");
        }

        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new JsonException();
            }
            var entries = new List<(string, string, bool)>();
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object ||
                    !item.TryGetProperty("ID", out var idProperty) ||
                    idProperty.ValueKind != JsonValueKind.String ||
                    !item.TryGetProperty("Type", out var typeProperty) ||
                    typeProperty.ValueKind != JsonValueKind.String)
                {
                    continue;
                }
                var rawName = item.TryGetProperty("VisibleName", out var nameProperty) &&
                    nameProperty.ValueKind == JsonValueKind.String
                        ? nameProperty.GetString()!
                        : "Untitled";
                entries.Add((
                    idProperty.GetString()!,
                    SafeName(rawName),
                    typeProperty.GetString() == "CollectionType"));
            }
            return entries;
        }
        catch (JsonException)
        {
            throw new TabletBackupException(
                "The tablet answered, but its document list couldn’t be read. " +
                "Toggle the USB web interface off and on, then try again.");
        }
    }

    private static string MakeDestination()
    {
        var destination = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            BackupFolderName,
            DateTime.Now.ToString("yyyy-MM-dd HH.mm"));
        try
        {
            Directory.CreateDirectory(destination);
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or NotSupportedException or
            ArgumentException)
        {
            throw new TabletBackupException(
                "The backup folder couldn’t be created in Documents.");
        }
        return destination;
    }

    private async Task UploadAsync(
        Uri baseUri,
        string file,
        CancellationToken cancellationToken)
    {
        var name = Path.GetFileName(file);
        byte[] contents;
        try
        {
            contents = await File.ReadAllBytesAsync(file, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw UploadRejected(name);
        }

        using var body = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(contents);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/zip");
        body.Add(fileContent, "file", name);
        StockUploadMultipartHeaders.Normalize(fileContent);

        HttpResponseMessage response;
        try
        {
            response = await _http.PostAsync(
                    new Uri(baseUri, "upload"),
                    body,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is
            HttpRequestException or TaskCanceledException)
        {
            throw new TabletBackupException(
                "The tablet isn’t answering over USB-C. Turn on Settings > Storage > " +
                "USB web interface, reconnect the cable, and try again.");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                throw UploadRejected(name);
            }
        }
    }

    private static List<string> RmdocFiles(string folder)
    {
        try
        {
            return Directory.EnumerateFiles(
                    folder,
                    "*.rmdoc",
                    SearchOption.AllDirectories)
                .OrderBy(Path.GetFileName, StringComparer.Ordinal)
                .ToList();
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or SecurityException or
            NotSupportedException or ArgumentException)
        {
            return [];
        }
    }

    private static string SafeName(string name)
    {
        var cleaned = name.Trim();
        foreach (var invalid in Path.GetInvalidFileNameChars())
        {
            cleaned = cleaned.Replace(invalid, '-');
        }
        return cleaned.Length == 0 ? "Untitled" : cleaned;
    }

    private static TabletBackupException DocumentFailed(string name) =>
        new($"“{name}” couldn’t be downloaded. Keep the tablet awake and " +
            "connected, then try the backup again.");

    private static TabletBackupException UploadRejected(string name) =>
        new($"The tablet didn’t accept “{name}”. Keep it awake and connected " +
            "with the USB web interface on, then try again.");
}
