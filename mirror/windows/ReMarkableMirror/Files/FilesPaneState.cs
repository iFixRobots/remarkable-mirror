using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ReMarkableMirror.Files;

/// <summary>
/// Presentation state for the Files pane. Device access and file operations
/// remain owned by the host.
/// </summary>
public sealed class FilesPaneState : INotifyPropertyChanged
{
    private const string DisconnectedStatus = "Connect your reMarkable to browse files.";

    private bool _isAvailable;
    private bool _canGoBack;
    private bool _canRefresh;
    private bool _isLibraryEnabled;
    private bool _isRefreshing;
    private string _libraryStatusText = DisconnectedStatus;
    private string _libraryLocationText = "My files";

    public FilesPaneState(
        ObservableCollection<RemarkableLibraryItem>? libraryItems = null,
        ObservableCollection<global::ReMarkableMirror.TransferItem>? transfers = null)
    {
        LibraryItems = libraryItems ?? [];
        Transfers = transfers ?? [];
        Transfers.CollectionChanged += Transfers_CollectionChanged;
    }

    public ObservableCollection<RemarkableLibraryItem> LibraryItems { get; }

    public ObservableCollection<global::ReMarkableMirror.TransferItem> Transfers { get; }

    public bool IsAvailable
    {
        get => _isAvailable;
        set
        {
            if (SetField(ref _isAvailable, value))
            {
                OnPropertyChanged(nameof(DropTargetTitle));
            }
        }
    }

    public bool CanGoBack
    {
        get => _canGoBack;
        set => SetField(ref _canGoBack, value);
    }

    public bool CanRefresh
    {
        get => _canRefresh;
        set => SetField(ref _canRefresh, value);
    }

    public bool IsLibraryEnabled
    {
        get => _isLibraryEnabled;
        set => SetField(ref _isLibraryEnabled, value);
    }

    public bool IsRefreshing
    {
        get => _isRefreshing;
        set => SetField(ref _isRefreshing, value);
    }

    public string LibraryStatusText
    {
        get => _libraryStatusText;
        set => SetField(ref _libraryStatusText, value ?? string.Empty);
    }

    public string LibraryLocationText
    {
        get => _libraryLocationText;
        set => SetField(ref _libraryLocationText, value ?? string.Empty);
    }

    public string DropTargetTitle => IsAvailable ? "Drop to send" : "Connect to send";

    public bool HasTransfers => Transfers.Count > 0;

    public string TransferCountText =>
        $"{Transfers.Count} transfer{(Transfers.Count == 1 ? string.Empty : "s")}";

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Applies the normal connected or disconnected state in one call.
    /// </summary>
    public void SetAvailability(bool available, bool canGoBack)
    {
        IsAvailable = available;
        CanRefresh = available;
        CanGoBack = available && canGoBack;
        IsLibraryEnabled = available;

        if (!available)
        {
            IsRefreshing = false;
            LibraryStatusText = DisconnectedStatus;
        }
    }

    /// <summary>
    /// Presents a disabled library while a refresh is in progress.
    /// </summary>
    public void BeginLibraryRefresh(string locationText)
    {
        LibraryLocationText = locationText;
        CanRefresh = false;
        CanGoBack = false;
        IsLibraryEnabled = false;
        IsRefreshing = true;
        LibraryStatusText = "Connecting to your library…";
    }

    /// <summary>
    /// Completes a refresh while respecting the current connection state.
    /// </summary>
    public void CompleteLibraryRefresh(string statusText, bool canGoBack)
    {
        LibraryStatusText = statusText;
        IsRefreshing = false;
        CanRefresh = IsAvailable;
        CanGoBack = IsAvailable && canGoBack;
        IsLibraryEnabled = IsAvailable;
    }

    private void Transfers_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(HasTransfers));
        OnPropertyChanged(nameof(TransferCountText));
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
