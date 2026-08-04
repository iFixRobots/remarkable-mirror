using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ReMarkableMirror;

public sealed partial class LibraryTile : UserControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
        nameof(Title), typeof(string), typeof(LibraryTile), new PropertyMetadata(string.Empty));

    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(string), typeof(LibraryTile), new PropertyMetadata("Document", OnKindChanged));

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string Kind
    {
        get => (string)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public LibraryTile()
    {
        InitializeComponent();
        UpdateVisual();
    }

    private static void OnKindChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is LibraryTile tile)
        {
            tile.UpdateVisual();
        }
    }

    private void UpdateVisual()
    {
        if (KindIcon is null)
        {
            return;
        }

        KindIcon.Glyph = Kind == "Folder" ? "\uE8B7" : "\uE8A5";
        PageAccent.Visibility = Kind == "Folder" ? Visibility.Collapsed : Visibility.Visible;
    }
}
