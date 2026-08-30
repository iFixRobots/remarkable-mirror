namespace ReMarkableMirror.Files;

public enum RemarkableLibraryItemKind
{
    Document,
    Collection,
}

public sealed record RemarkableLibraryItem
{
    public RemarkableLibraryItem(
        string id,
        string? visibleName,
        string? vissibleName,
        string parentId,
        RemarkableLibraryItemKind kind,
        bool isBookmarked,
        string? modifiedClient,
        int? currentPage,
        string? fileType)
    {
        Id = id;
        VisibleName = visibleName;
        VissibleName = vissibleName;
        ParentId = parentId;
        Kind = kind;
        IsBookmarked = isBookmarked;
        ModifiedClient = modifiedClient;
        CurrentPage = currentPage;
        FileType = fileType;
    }

    public string Id { get; set; }

    public string? VisibleName { get; set; }

    public string? VissibleName { get; set; }

    public string ParentId { get; set; }

    public RemarkableLibraryItemKind Kind { get; set; }

    public bool IsBookmarked { get; set; }

    public string? ModifiedClient { get; set; }

    public int? CurrentPage { get; set; }

    public string? FileType { get; set; }

    public string Name => VissibleName ?? VisibleName ?? string.Empty;

    public string KindLabel => Kind is RemarkableLibraryItemKind.Collection
        ? "Folder"
        : string.IsNullOrWhiteSpace(FileType)
            ? "Document"
            : FileType.ToUpperInvariant();

    public string Glyph => Kind is RemarkableLibraryItemKind.Collection
        ? "\uE8B7"
        : "\uE8A5";

    public string ActionGlyph => Kind is RemarkableLibraryItemKind.Collection
        ? "\uE76C"
        : "\uE896";

    public bool IsDocument => Kind is RemarkableLibraryItemKind.Document;
}

public sealed record RemarkableUploadResult(
    string SourceFileName,
    string DestinationFolderId,
    RemarkableLibraryItem Item);

public sealed record RemarkableDownloadResult(
    long BytesWritten,
    string? SuggestedFileName,
    string? SavedPath);
