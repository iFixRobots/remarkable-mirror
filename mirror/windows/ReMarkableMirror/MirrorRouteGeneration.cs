using ReMarkableMirror.Files;

namespace ReMarkableMirror;

/// <summary>
/// Owns every route-scoped resource for one published Mirror connection.
/// Canceling the generation fences in-flight work before its resources are replaced.
/// </summary>
internal sealed class MirrorRouteGeneration : IAsyncDisposable
{
    private readonly CancellationTokenSource _lifetime;
    private readonly CancellationToken _cancellationToken;
    private int _canceled;
    private bool _disposed;

    public MirrorRouteGeneration(
        long id,
        DeviceRouteKind kind,
        SshRoute route,
        CancellationToken applicationCancellationToken)
    {
        Route = route ?? throw new ArgumentNullException(nameof(route));
        Id = id;
        Kind = kind;
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(
            applicationCancellationToken);
        _cancellationToken = _lifetime.Token;
        FrameSource = new SshFrameSource(route);
        FileTransport = new RemarkableFileTransport(route);
    }

    public long Id { get; }

    public DeviceRouteKind Kind { get; }

    public SshRoute Route { get; }

    public SshFrameSource FrameSource { get; }

    public RemarkableFileTransport FileTransport { get; }

    public CancellationToken CancellationToken => _cancellationToken;

    public void Cancel()
    {
        if (Interlocked.Exchange(ref _canceled, 1) == 0)
        {
            _lifetime.Cancel();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Cancel();
        try
        {
            await FileTransport.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifetime.Dispose();
        }
    }
}
