using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace ReMarkableMirror.Files;

public sealed partial class FilesPaneView : UserControl
{
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
    private bool _isTransitionCopy;
    private bool _isDropTargetHighlighted;
    private double? _pendingLibraryScrollOffset;

    public FilesPaneView()
    {
        InitializeComponent();
        AttachState(_state);
    }

    /// <summary>
    /// The presentation state shared by the main and transition instances.
    /// </summary>
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

    /// <summary>
    /// Makes this instance a display-only compositor copy without changing its
    /// enabled appearance. Set this before placing it in the transition island.
    /// </summary>
    public bool IsTransitionCopy
    {
        get => _isTransitionCopy;
        set
        {
            if (_isTransitionCopy == value)
            {
                return;
            }

            _isTransitionCopy = value;
            IsHitTestVisible = !value;
            // The pane itself should never add an extra tab stop; its child
            // controls remain keyboard reachable on the interactive copy.
            IsTabStop = false;
            AutomationProperties.SetAccessibilityView(
                this,
                value ? AccessibilityView.Raw : AccessibilityView.Content);
            ApplyState();
        }
    }

    /// <summary>
    /// Border used where the pane joins the tablet surface. The settled main
    /// copy normally uses zero; the transition copy uses 0,1,1,1.
    /// </summary>
    public Thickness SurfaceBorderThickness
    {
        get => PaneSurface.BorderThickness;
        set => PaneSurface.BorderThickness = value;
    }

    /// <summary>
    /// Corner treatment for the host context. The settled main copy normally
    /// uses zero; the transition copy uses right-side 24-pixel corners.
    /// </summary>
    public CornerRadius SurfaceCornerRadius
    {
        get => PaneSurface.CornerRadius;
        set => PaneSurface.CornerRadius = value;
    }

    public event EventHandler? CloseRequested;

    public event EventHandler? BackRequested;

    public event EventHandler? RefreshRequested;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? LibraryItemInvoked;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? SavePdfRequested;

    public event EventHandler<FilesPaneLibraryItemEventArgs>? SaveNativeRequested;

    public event EventHandler<DragEventArgs>? FilesDropped;

    /// <summary>
    /// Returns the current library-list scroll offset for transition handoff.
    /// </summary>
    public double GetLibraryScrollOffset() =>
        FindDescendant<ScrollViewer>(LibraryList)?.VerticalOffset ?? 0;

    /// <summary>
    /// Restores the library-list scroll offset without animating it. If the
    /// control is not loaded yet, the offset is applied after its first layout.
    /// </summary>
    public void SetLibraryScrollOffset(double offset)
    {
        _pendingLibraryScrollOffset = Math.Max(0, offset);
        ApplyPendingLibraryScrollOffset();
    }

    /// <summary>
    /// Re-applies all shared presentation state immediately.
    /// </summary>
    public void RefreshVisualState() => ApplyState();

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
        DropTarget.AllowDrop = !_isTransitionCopy && _state.IsAvailable;
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

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isTransitionCopy)
        {
            CloseRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void LibraryBackButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isTransitionCopy && _state.CanGoBack)
        {
            BackRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void LibraryRefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isTransitionCopy && _state.CanRefresh)
        {
            RefreshRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void LibraryList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (!_isTransitionCopy &&
            _state.IsLibraryEnabled &&
            e.ClickedItem is RemarkableLibraryItem item)
        {
            LibraryItemInvoked?.Invoke(this, new FilesPaneLibraryItemEventArgs(item));
        }
    }

    private void SaveLibraryPdf_Click(object sender, RoutedEventArgs e)
    {
        if (!_isTransitionCopy && sender is FrameworkElement { Tag: RemarkableLibraryItem item })
        {
            SavePdfRequested?.Invoke(this, new FilesPaneLibraryItemEventArgs(item));
        }
    }

    private void SaveLibraryNative_Click(object sender, RoutedEventArgs e)
    {
        if (!_isTransitionCopy && sender is FrameworkElement { Tag: RemarkableLibraryItem item })
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
        !_isTransitionCopy &&
        _state.IsAvailable &&
        e.DataView.Contains(StandardDataFormats.StorageItems);

    private void FilesPaneView_Loaded(object sender, RoutedEventArgs e)
    {
        ApplyState();
        ApplyPendingLibraryScrollOffset();
    }

    private void ApplyPendingLibraryScrollOffset()
    {
        if (!_pendingLibraryScrollOffset.HasValue || !IsLoaded)
        {
            return;
        }

        LibraryList.UpdateLayout();
        var scrollViewer = FindDescendant<ScrollViewer>(LibraryList);
        if (scrollViewer is null)
        {
            return;
        }

        scrollViewer.ChangeView(
            horizontalOffset: null,
            verticalOffset: _pendingLibraryScrollOffset.Value,
            zoomFactor: null,
            disableAnimation: true);
        _pendingLibraryScrollOffset = null;
    }

    private static T? FindDescendant<T>(DependencyObject parent)
        where T : DependencyObject
    {
        var childCount = VisualTreeHelper.GetChildrenCount(parent);
        for (var index = 0; index < childCount; index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match)
            {
                return match;
            }

            var descendant = FindDescendant<T>(child);
            if (descendant is not null)
            {
                return descendant;
            }
        }

        return null;
    }
}

public sealed class FilesPaneLibraryItemEventArgs : EventArgs
{
    public FilesPaneLibraryItemEventArgs(RemarkableLibraryItem item)
    {
        Item = item;
    }

    public RemarkableLibraryItem Item { get; }
}
