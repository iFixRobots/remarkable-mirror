using System.IO.Pipes;
using System.Security;
using System.Security.Cryptography;
using System.Text;

namespace ReMarkableMirror;

/// <summary>
/// Carries the one-time tablet password from the app to OpenSSH in memory.
/// The child process receives only a random current-user pipe name.
/// </summary>
internal static class AskPassBridge
{
    internal const string ModeVariable = "RMMIRROR_ASKPASS_MODE";
    internal const string PipeVariable = "RMMIRROR_ASKPASS_PIPE";
    internal const string Mode = "v1";
    private const string PipePrefix = "rmmirror-askpass-";
    private const int MaximumPasswordBytes = 1024;

    public static bool IsRequested =>
        string.Equals(
            Environment.GetEnvironmentVariable(ModeVariable),
            Mode,
            StringComparison.Ordinal);

    public static string CreatePipeName() => PipePrefix + Guid.NewGuid().ToString("N");

    public static NamedPipeServerStream CreateServer(string pipeName)
    {
        if (!IsValidPipeName(pipeName))
        {
            throw new ArgumentException("The askpass pipe name is invalid.", nameof(pipeName));
        }

        return new NamedPipeServerStream(
            pipeName,
            PipeDirection.Out,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    }

    public static async Task SendAsync(
        NamedPipeServerStream server,
        string password,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(server);
        ValidatePassword(password);

        var bytes = Encoding.UTF8.GetBytes(password);
        try
        {
            await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
            await server.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await server.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public static int RunClient()
    {
        var pipeName = Environment.GetEnvironmentVariable(PipeVariable);
        if (!IsRequested || !IsValidPipeName(pipeName))
        {
            return 1;
        }

        var buffer = new byte[MaximumPasswordBytes + 1];
        try
        {
            using var pipe = new NamedPipeClientStream(
                ".",
                pipeName!,
                PipeDirection.In,
                PipeOptions.None);
            pipe.Connect(5000);

            var length = 0;
            while (length < buffer.Length)
            {
                var read = pipe.Read(buffer, length, buffer.Length - length);
                if (read == 0)
                {
                    break;
                }
                length += read;
            }

            if (length is 0 or > MaximumPasswordBytes)
            {
                return 1;
            }

            using var output = Console.OpenStandardOutput();
            output.Write(buffer, 0, length);
            output.WriteByte((byte)'\n');
            output.Flush();
            return 0;
        }
        catch (Exception exception) when (exception is
            IOException or TimeoutException or UnauthorizedAccessException or SecurityException)
        {
            return 1;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
        }
    }

    public static void ValidatePassword(string password)
    {
        ArgumentException.ThrowIfNullOrEmpty(password);
        if (password.Any(character => character is '\r' or '\n' or '\0') ||
            Encoding.UTF8.GetByteCount(password) > MaximumPasswordBytes)
        {
            throw new ArgumentException("The tablet password is invalid.", nameof(password));
        }
    }

    private static bool IsValidPipeName(string? pipeName) =>
        pipeName is not null &&
        pipeName.Length == PipePrefix.Length + 32 &&
        pipeName.StartsWith(PipePrefix, StringComparison.Ordinal) &&
        pipeName[PipePrefix.Length..].All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');
}
