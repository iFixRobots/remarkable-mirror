using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace ReMarkableMirror.Files;

internal sealed record LibraryDocumentDragRequest(
    string DocumentId,
    string DisplayName,
    string? ModifiedClient);

internal sealed record PreparedLibraryDocumentDrag(
    StorageFile File,
    string StagingDirectory,
    long BytesWritten);

internal sealed record LibraryDocumentDragCompletion(
    PreparedLibraryDocumentDrag? PreparedDrag,
    DataPackageOperation DropResult);

/// <summary>
/// Owns one delayed-rendered Explorer drag. DragStarting only registers this
/// provider; the PDF is materialized later, when the drop target asks for it.
/// </summary>
internal sealed class LibraryDocumentDragSession
{
    private readonly object _gate = new();
    private readonly Func<
        LibraryDocumentDragRequest,
        CancellationToken,
        Task<PreparedLibraryDocumentDrag?>> _materializeAsync;
    private readonly Action<LibraryDocumentDragCompletion> _completed;
    private readonly Action<Exception> _providerFailed;
    private readonly CancellationTokenSource _cancellation = new();
    private Task<PreparedLibraryDocumentDrag?>? _materializationTask;
    private PreparedLibraryDocumentDrag? _preparedDrag;
    private DataPackageOperation _dropResult;
    private int _activeProviderRequests;
    private bool _providerRequested;
    private bool _dropCompleted;
    private bool _completionReported;

    public LibraryDocumentDragSession(
        LibraryDocumentDragRequest request,
        string fileName,
        Func<
            LibraryDocumentDragRequest,
            CancellationToken,
            Task<PreparedLibraryDocumentDrag?>> materializeAsync,
        Action<LibraryDocumentDragCompletion> completed,
        Action<Exception> providerFailed)
    {
        Request = request;
        FileName = fileName;
        _materializeAsync = materializeAsync;
        _completed = completed;
        _providerFailed = providerFailed;
    }

    public LibraryDocumentDragRequest Request { get; }

    public string FileName { get; }

    public void ProvideData(DataProviderRequest request)
    {
        DataProviderDeferral deferral;
        try
        {
            deferral = request.GetDeferral();
        }
        catch (Exception exception)
        {
            _providerFailed(exception);
            return;
        }

        lock (_gate)
        {
            _providerRequested = true;
            _activeProviderRequests++;
        }

        _ = ProvideDataAsync(request, deferral);
    }

    public void Complete(DataPackageOperation dropResult)
    {
        LibraryDocumentDragCompletion? completion;
        lock (_gate)
        {
            if (_dropCompleted)
            {
                return;
            }

            _dropCompleted = true;
            _dropResult = dropResult;
            if (dropResult is DataPackageOperation.None)
            {
                _cancellation.Cancel();
            }
            completion = TakeCompletionIfReady();
        }

        if (completion is not null)
        {
            _completed(completion);
        }
    }

    private async Task ProvideDataAsync(
        DataProviderRequest request,
        DataProviderDeferral deferral)
    {
        try
        {
            var preparedDrag = await GetOrStartMaterializationAsync(request.Deadline)
                .ConfigureAwait(false);
            if (preparedDrag is not null && !_cancellation.IsCancellationRequested)
            {
                request.SetData(new IStorageItem[] { preparedDrag.File });
            }
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (!_cancellation.IsCancellationRequested)
        {
            _providerFailed(exception);
        }
        catch (Exception) when (_cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            try
            {
                deferral.Complete();
            }
            catch (Exception exception) when (!_cancellation.IsCancellationRequested)
            {
                _providerFailed(exception);
            }
            catch (Exception) when (_cancellation.IsCancellationRequested)
            {
            }

            LibraryDocumentDragCompletion? completion;
            lock (_gate)
            {
                _activeProviderRequests--;
                completion = TakeCompletionIfReady();
            }
            if (completion is not null)
            {
                _completed(completion);
            }
        }
    }

    private Task<PreparedLibraryDocumentDrag?> GetOrStartMaterializationAsync(
        DateTimeOffset deadline)
    {
        lock (_gate)
        {
            _materializationTask ??= Task.Run(
                () => MaterializeBeforeDeadlineAsync(deadline));
            return _materializationTask;
        }
    }

    private async Task<PreparedLibraryDocumentDrag?> MaterializeBeforeDeadlineAsync(
        DateTimeOffset deadline)
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            _cancellation.Token);
        var remaining = deadline - DateTimeOffset.Now;
        if (remaining <= TimeSpan.Zero)
        {
            cancellation.Cancel();
        }
        else
        {
            cancellation.CancelAfter(remaining);
        }

        var preparedDrag = await _materializeAsync(Request, cancellation.Token)
            .ConfigureAwait(false);
        lock (_gate)
        {
            _preparedDrag = preparedDrag;
        }
        return preparedDrag;
    }

    private LibraryDocumentDragCompletion? TakeCompletionIfReady()
    {
        if (_completionReported ||
            !_dropCompleted ||
            _activeProviderRequests != 0 ||
            (_dropResult is not DataPackageOperation.None && !_providerRequested))
        {
            return null;
        }

        _completionReported = true;
        return new LibraryDocumentDragCompletion(_preparedDrag, _dropResult);
    }
}
