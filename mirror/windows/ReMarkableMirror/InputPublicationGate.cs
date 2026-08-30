namespace ReMarkableMirror;

internal sealed class InputPublicationGate
{
    private long _generation;

    public void Begin(long generation) =>
        Interlocked.Exchange(ref _generation, generation);

    public bool IsPending(long generation) =>
        Interlocked.Read(ref _generation) == generation;

    public void Complete(long generation) =>
        Interlocked.CompareExchange(ref _generation, 0, generation);

    public void Reset() => Interlocked.Exchange(ref _generation, 0);
}
