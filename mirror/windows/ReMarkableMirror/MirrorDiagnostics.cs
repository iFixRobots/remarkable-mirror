using System.Security;
using Windows.Storage;

namespace ReMarkableMirror;

public sealed class MirrorDiagnostics
{
    private const long MaximumLogBytes = 256 * 1024;
    private const int MaximumMemoryEntries = 120;
    private readonly object _gate = new();
    private readonly Queue<string> _entries = new();

    public MirrorDiagnostics()
    {
        FilePath = Path.Combine(
            ApplicationData.Current.LocalFolder.Path,
            "mirror.log");
    }

    public string FilePath { get; }

    public void Record(string category, string message)
    {
        var cleanCategory = Sanitize(category, 40);
        var cleanMessage = Sanitize(message, 300);
        var line = $"{DateTimeOffset.Now:O} [{cleanCategory}] {cleanMessage}";

        lock (_gate)
        {
            _entries.Enqueue(line);
            while (_entries.Count > MaximumMemoryEntries)
            {
                _entries.Dequeue();
            }

            TryAppend(line);
        }
    }

    public string Export()
    {
        lock (_gate)
        {
            return string.Join(
                Environment.NewLine,
                new[]
                {
                    "reMarkable Mirror connection diagnostics",
                    $"Log: {FilePath}",
                    "This log contains connection states only. It does not record screen content, filenames, typing, or credentials.",
                    string.Empty,
                }.Concat(_entries));
        }
    }

    private void TryAppend(string line)
    {
        try
        {
            var directory = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(directory);
            if (File.Exists(FilePath) && new FileInfo(FilePath).Length >= MaximumLogBytes)
            {
                File.WriteAllText(FilePath, string.Empty);
            }
            File.AppendAllText(FilePath, line + Environment.NewLine);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            // Diagnostics must never interfere with the mirror itself.
        }
    }

    private static string Sanitize(string value, int maximumLength)
    {
        var flattened = value
            .Replace('\r', ' ')
            .Replace('\n', ' ')
            .Trim();
        return flattened.Length <= maximumLength
            ? flattened
            : flattened[..maximumLength];
    }
}
