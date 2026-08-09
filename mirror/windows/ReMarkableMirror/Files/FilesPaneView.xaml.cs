using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace ReMarkableMirror.Files;

public sealed partial class FilesPaneView : UserControl
{
    internal const string OutboundDocumentDragFormat =
        "ReMarkableMirror.OutboundDocument";

    private static readonly Windows.UI.Color AvailableBackground =
        Windows.UI.Color.FromArgb(255, 250, 249, 245);
    private static readonly Windows.UI.Color UnavailableBackground =
        Windows.UI.Color.FromArgb(255, 241, 240, 235);
    private static readonly Windows.UI.Color HighlightedBackground =
        Windows.UI.Color.FromArgb(255, 238, 241, 255);
    private static readonly Windows.UI.Color AvailableIconBackground =
        Windows.UI.Color.FromArgb(255, 221, 226, 255);
    private static readonly Windows.UI.Color UnavailableIconBackground =
        Windows.UI.Color.FromArgb(255, 226, 225, 220);
    private static readonly Windows.UI.Color AvailableIcon =
        Windows.UI.Color.FromArgb(255, 56, 88, 233);
    private static readonly Windows.UI.Color UnavailableIcon =
        Windows.UI.Color.FromArgb(255, 112, 113, 118);
    private static readonly Windows.UI.Color AvailableTitle =
        Windows.UI.Color.FromArgb(255, 32, 33, 36);
    private static readonly Windows.UI.Color UnavailableTitle =
        Windows.UI.Color.FromArgb(255, 95, 96, 102);

    private FilesPaneState _state = new();
    private bool _isDropTargetHighlighted;
    private bool _isDocumentDragEnabled;
    private bool _suppressLibraryItemClick;
    private LibraryDocumentDragSession? _activeDocumentDragSession;
    private long _documentDragGeneration;

    public FilesPaneView()
    {
        InitializeComponent();
        AttachState(_state);
    }

    /// <summary>The pane's presentation state.</summary>
    public FilesPaneState State
    {
        get => _state;
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            if (ReferenceEquals(_state, value))
            {
                return;
            }

            _state.PropertyChanged -= State_PropertyChanged;
            _state = value;
            AttachState(_state);
        }
    }

    public event EventHandler? CloseRequested;

    public event EventHandler? BackRequested;

    public event EventHandler? RefreshRequested;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? LibraryItemInvoked;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? SavePdfRequested;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? SaveNativeRequested;

    public event EventHandler<DragEventArgs>? FilesDropped;

    internal Func<LibraryDocumentDragRequest, LibraryDocumentDragSession?>?
        BeginDocumentDrag { get; set; }

    internal bool IsDocumentDragEnabled
    {
        get => _isDocumentDragEnabled;
        set => _isDocumentDragEnabled = value;
    }

    private void AttachState(FilesPaneState state)
    {
        state.PropertyChanged += State_PropertyChanged;
        LibraryList.ItemsSource = state.LibraryItems;
        TransferList.ItemsSource = state.Transfers;
        ApplyState();
    }

    private void State_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            ApplyState();
        }
        else
        {
            DispatcherQueue.TryEnqueue(ApplyState);
        }
    }

    private void ApplyState()
    {
        DropTarget.AllowDrop = _state.IsAvailable;
        DropTargetTitle.Text = _state.DropTargetTitle;
        LibraryRefreshButton.IsEnabled = _state.CanRefresh;
        LibraryBackButton.IsEnabled = _state.CanGoBack;
        LibraryList.IsEnabled = _state.IsLibraryEnabled;
        LibraryProgressRing.IsActive = _state.IsRefreshing;
        LibraryProgressRing.Visibility = _state.IsRefreshing
            ? Visibility.Visible
            : Visibility.Collapsed;
        LibraryStateText.Text = _state.LibraryStatusText;
        LibraryLocationText.Text = _state.LibraryLocationText;
        TransferSection.Visibility = _state.HasTransfers
            ? Visibility.Visible
            : Visibility.Collapsed;
        QueueCountText.Text = _state.TransferCountText;
        ApplyDropTargetVisual();
    }

    private void ApplyDropTargetVisual()
    {
        var available = _state.IsAvailable;
        DropTarget.BorderThickness = new Thickness(_isDropTargetHighlighted ? 2 : 1);
        DropTarget.Background = new SolidColorBrush(
            _isDropTargetHighlighted
                ? HighlightedBackground
                : available
                    ? AvailableBackground
                    : UnavailableBackground);
        DropTargetIconSurface.Background = new SolidColorBrush(
            available ? AvailableIconBackground : UnavailableIconBackground);
        DropTargetIcon.Foreground = new SolidColorBrush(
            available ? AvailableIcon : UnavailableIcon);
        DropTargetTitle.Foreground = new SolidColorBrush(
            available ? AvailableTitle : UnavailableTitle);
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) =>
        CloseRequested?.Invoke(this, EventArgs.Empty);

    private void LibraryBackButton_Click(object sender, RoutedEventArgs e)
    {
        if (_state.CanGoBack)
        {
            BackRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void LibraryRefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (_state.CanRefresh)
        {
            RefreshRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void LibraryList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (_suppressLibraryItemClick)
        {
            return;
        }

        if (_state.IsLibraryEnabled &&
            e.ClickedItem is RemarkableLibraryItem item)
        {
            LibraryItemInvoked?.Invoke(this, new FilesPaneLibraryItemEventArgs(item));
        }
    }

    private void LibraryDocument_DragStarting(
        UIElement sender,
        DragStartingEventArgs e)
    {
        var beginDocumentDrag = BeginDocumentDrag;
        if (!_isDocumentDragEnabled ||
            !_state.IsAvailable ||
            _activeDocumentDragSession is not null ||
            beginDocumentDrag is null ||
            sender is not FrameworkElement { DataContext: RemarkableLibraryItem item } ||
            !item.IsDocument)
        {
            e.Cancel = true;
            return;
        }

        // ListView recycles its row visuals. Capture immutable document values
        // now, then promise the PDF to Windows without waiting for the tablet.
        var request = new LibraryDocumentDragRequest(
            item.Id,
            item.Name,
            item.ModifiedClient);
        var session = beginDocumentDrag(request);
        if (session is null)
        {
            e.Cancel = true;
            return;
        }

        try
        {
            e.AllowedOperations = DataPackageOperation.Copy;
            e.Data.RequestedOperation = DataPackageOperation.Copy;
            e.Data.Properties.Title = session.FileName;
            e.Data.Properties.Description = "PDF from your reMarkable";
            e.Data.Properties.FileTypes.Add(".pdf");
            e.Data.SetData(OutboundDocumentDragFormat, "1");
            e.Data.SetDataProvider(
                StandardDataFormats.StorageItems,
                session.ProvideData);
            _activeDocumentDragSession = session;
            _suppressLibraryItemClick = true;
            _documentDragGeneration++;
        }
        catch (Exception)
        {
            e.Cancel = true;
            session.Complete(DataPackageOperation.None);
            _activeDocumentDragSession = null;
        }
    }

    private void LibraryDocument_DropCompleted(
        UIElement sender,
        DropCompletedEventArgs e)
    {
        var session = _activeDocumentDragSession;
        _activeDocumentDragSession = null;
        if (session is not null)
        {
            session.Complete(e.DropResult);
        }

        // A completed drag must not fall through to the row's click-to-save
        // behavior. Clear the suppression after routed pointer work settles so
        // the next intentional click behaves normally.
        ResetLibraryItemClickSuppression(_documentDragGeneration);
    }

    private void ResetLibraryItemClickSuppression(long dragGeneration) =>
        DispatcherQueue.TryEnqueue(
            Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () =>
            {
                if (_documentDragGeneration == dragGeneration &&
                    _activeDocumentDragSession is null)
                {
                    _suppressLibraryItemClick = false;
                }
            });

    private void SaveLibraryPdf_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: RemarkableLibraryItem item })
        {
            SavePdfRequested?.Invoke(this, new FilesPaneLibraryItemEventArgs(item));
        }
    }

    private void SaveLibraryNative_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: RemarkableLibraryItem item })
        {
            SaveNativeRequested?.Invoke(this, new FilesPaneLibraryItemEventArgs(item));
        }
    }

    private void DropTarget_DragEnter(object sender, DragEventArgs e)
    {
        if (CanAcceptDrop(e))
        {
            _isDropTargetHighlighted = true;
            ApplyDropTargetVisual();
        }
    }

    private void DropTarget_DragLeave(object sender, DragEventArgs e)
    {
        _isDropTargetHighlighted = false;
        ApplyDropTargetVisual();
    }

    private void DropTarget_DragOver(object sender, DragEventArgs e)
    {
        if (!CanAcceptDrop(e))
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }

        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Send to reMarkable";
        e.DragUIOverride.IsContentVisible = true;
    }

    private void DropTarget_Drop(object sender, DragEventArgs e)
    {
        _isDropTargetHighlighted = false;
        ApplyDropTargetVisual();
        if (CanAcceptDrop(e))
        {
            FilesDropped?.Invoke(this, e);
        }
    }

    private bool CanAcceptDrop(DragEventArgs e) =>
        _state.IsAvailable &&
        !e.DataView.Contains(OutboundDocumentDragFormat) &&
        e.DataView.Contains(StandardDataFormats.StorageItems);

}

public sealed class FilesPaneLibraryItemEventArgs : EventArgs
{
    public FilesPaneLibraryItemEventArgs(RemarkableLibraryItem item)
    {
        Item = item;
    }

    public RemarkableLibraryItem Item { get; }
}
