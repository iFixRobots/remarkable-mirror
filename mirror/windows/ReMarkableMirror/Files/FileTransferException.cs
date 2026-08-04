using System.Net;

namespace ReMarkableMirror.Files;

public enum FileTransferFailure
{
    Configuration,
    Connection,
    InvalidRequest,
    Protocol,
    Rejected,
    AmbiguousResult,
    LocalFile,
}

public sealed class FileTransferException : Exception
{
    public FileTransferException(
        FileTransferFailure failure,
        string message,
        Exception? innerException = null,
        HttpStatusCode? statusCode = null)
        : base(message, innerException)
    {
        Failure = failure;
        StatusCode = statusCode;
    }

    public FileTransferFailure Failure { get; }

    public HttpStatusCode? StatusCode { get; }
}
