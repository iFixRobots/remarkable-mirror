using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using Windows.Graphics;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace ReMarkableMirror;

/// <summary>
/// The application window. This hosts a Frame that displays pages. Add your
/// UI and logic to MainPage.xaml / MainPage.xaml.cs instead of here so you
/// can use Page features such as navigation events and the Loaded lifecycle.
/// </summary>
public sealed partial class MainWindow : Window
{
    private const double DefaultDpi = 96;
    private const double FilesPaneWidthDip = 320;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpNoOwnerZOrder = 0x0200;
    private readonly int _compactWidth;
    private readonly int _expandedWidth;
    private readonly double _compactClientWidth;
    private readonly double _expandedClientWidth;
    private readonly IntPtr _hwnd;
    private int _lastFilesPaneNativeWidth;

    public MainWindow()
    {
        InitializeComponent();

        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowDpi = GetDpiForWindow(_hwnd);
        var pixelsPerDip = Math.Max(DefaultDpi, windowDpi) / DefaultDpi;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        AppWindow.SetIcon("Assets/AppIcon.ico");

        var display = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary);
        var workAreaWidthDip = display is null
            ? 1920
            : display.WorkArea.Width / pixelsPerDip;
        var workAreaHeightDip = display is null
            ? 972
            : display.WorkArea.Height / pixelsPerDip;
        var desiredHeightDip = Math.Clamp(workAreaHeightDip - 72, 720, 1040);
        var compactWidthDip = Math.Min(
            Math.Clamp(desiredHeightDip * 0.55, 570, 590),
            Math.Max(360, workAreaWidthDip - 48 - FilesPaneWidthDip));
        _compactWidth = (int)Math.Round(compactWidthDip * pixelsPerDip);
        _expandedWidth = _compactWidth +
            (int)Math.Round(FilesPaneWidthDip * pixelsPerDip);
        var desiredHeight = (int)Math.Round(desiredHeightDip * pixelsPerDip);
        var desiredSize = new SizeInt32(_compactWidth, desiredHeight);
        AppWindow.Resize(desiredSize);
        if (display is not null)
        {
            var workArea = display.WorkArea;
            var sideMargin = (int)Math.Round(24 * pixelsPerDip);
            var centeredX = workArea.X + Math.Max(0, (workArea.Width - desiredSize.Width) / 2);
            var rightmostExpandedX = workArea.X + workArea.Width - sideMargin - _expandedWidth;
            AppWindow.Move(new PointInt32(
                Math.Max(workArea.X + sideMargin, Math.Min(centeredX, rightmostExpandedX)),
                workArea.Y + Math.Max(0, (workArea.Height - desiredSize.Height) / 2)));
        }

        // Mirror owns its device-shaped compact and Files-open widths. Prevent
        // manual resize/maximize from producing empty space around that surface;
        // the app's SetWindowPos transition can still move between its two sizes.
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }

        // The mirror surface never relayouts when Files is open. The native
        // window grows once behind the compositor transition, while this frame
        // remains the exact compact width the user approved.
        // AppWindow sizes are physical pixels; XAML layout uses DIPs. Keeping
        // that conversion explicit makes the full 320-DIP pane visible at any
        // Windows display scale instead of only at 100%.
        _compactClientWidth = AppWindow.ClientSize.Width / pixelsPerDip;
        _expandedClientWidth = _compactClientWidth + FilesPaneWidthDip;
        RootFrame.Width = _compactClientWidth;
        _lastFilesPaneNativeWidth = _compactWidth;

        Activated += MainWindow_Activated;
        Closed += MainWindow_Closed;

        // Navigate the root frame to the main page on startup.
        RootFrame.Navigate(typeof(MainPage));
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState is WindowActivationState.Deactivated &&
            RootFrame.Content is MainPage page)
        {
            await page.ResetRemoteInputStateAsync();
        }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        if (RootFrame.Content is MainPage page)
        {
            page.DisposeFilesPaneAnimation();
        }
    }

    public Task SetFilesPaneOpenAsync(bool isOpen)
    {
        if (RootFrame.Content is MainPage page)
        {
            return page.SetFilesPaneOpenAsync(isOpen);
        }
        return Task.CompletedTask;
    }

    internal void BeginFilesPaneNativeResize()
    {
        RootFrame.Width = _expandedClientWidth;
        RootFrame.HorizontalAlignment = HorizontalAlignment.Left;
        _lastFilesPaneNativeWidth = AppWindow.Size.Width;
    }

    internal void SetFilesPaneWindowProgress(double progress)
    {
        progress = Math.Clamp(progress, 0, 1);
        var width = (int)Math.Round(
            _compactWidth + ((_expandedWidth - _compactWidth) * progress));
        if (width == _lastFilesPaneNativeWidth)
        {
            return;
        }

        var size = AppWindow.Size;
        if (!SetWindowPos(
                _hwnd,
                IntPtr.Zero,
                0,
                0,
                width,
                size.Height,
                SwpNoMove |
                SwpNoZOrder |
                SwpNoActivate |
                SwpNoOwnerZOrder))
        {
            AppWindow.Resize(new SizeInt32(width, size.Height));
        }
        _lastFilesPaneNativeWidth = width;
    }

    internal void EndFilesPaneNativeResize(bool open)
    {
        SetFilesPaneWindowProgress(open ? 1 : 0);
        if (open)
        {
            RootFrame.ClearValue(FrameworkElement.WidthProperty);
            RootFrame.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        else
        {
            RootFrame.Width = _compactClientWidth;
            RootFrame.HorizontalAlignment = HorizontalAlignment.Left;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
