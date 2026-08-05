using System;
using System.Net.Http;

namespace ReMarkableMirror.Files;

internal static class StockUploadMultipartHeaders
{
    internal static void Normalize(HttpContent fileContent)
    {
        var disposition = fileContent.Headers.ContentDisposition
            ?? throw new InvalidOperationException("The multipart file disposition is missing.");
        var serializedFileName = disposition.FileName;
        if (string.IsNullOrWhiteSpace(serializedFileName))
        {
            throw new InvalidOperationException("The multipart filename is missing.");
        }

        // Xochitl's stock importer expects the browser-style quoted parameters
        // and does not recognize .NET's filename* extension. The FileName
        // getter returns the parameter value without its surrounding quotes.
        disposition.Name = "\"file\"";
        disposition.FileName = $"\"{serializedFileName}\"";
        disposition.FileNameStar = null;
    }
}
