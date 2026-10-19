using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using PullYard.Core.Util;

namespace PullYard.Services;

public static class TextZoom
{
    public static double Scale { get; private set; } = ZoomLevels.Nearest(Settings.Shared.GetDouble(Keys.TextZoom, 1));

    public static event Action? Changed;

    private static bool changedThisSession;

    public static readonly DependencyProperty BaseSizeProperty =
        DependencyProperty.RegisterAttached("BaseSize", typeof(double), typeof(TextZoom), new PropertyMetadata(0d));

    public static bool CanZoomIn => ZoomLevels.Next(Scale) > Scale;
    public static bool CanZoomOut => ZoomLevels.Previous(Scale) < Scale;
    public static bool IsDefault => Math.Abs(Scale - 1) < 0.001;

    public static void ZoomIn() => Set(ZoomLevels.Next(Scale));
    public static void ZoomOut() => Set(ZoomLevels.Previous(Scale));
    public static void Reset() => Set(1);

    public static void Set(double value)
    {
        var next = ZoomLevels.Nearest(value);
        if (Math.Abs(next - Scale) < 0.001) return;
        Scale = next;
        changedThisSession = true;
        Settings.Shared.Set(Keys.TextZoom, next);
        Changed?.Invoke();
    }

    public static double Size(double size) => size * Scale;

    public static T Track<T>(T element, double size) where T : FrameworkElement
    {
        element.SetValue(BaseSizeProperty, size);
        switch (element)
        {
            case TextBlock t:
                t.FontSize = size * Scale;
                break;
            case FontIcon f:
                f.FontSize = size * Scale;
                break;
            case Control c:
                c.FontSize = size * Scale;
                break;
        }
        return element;
    }

    public static void Apply(DependencyObject? root)
    {
        if (root is null) return;
        Walk(root);
    }

    public static void ApplyWhenLoaded(FrameworkElement element)
    {
        if (IsDefault && !changedThisSession) return;
        void OnLoaded(object sender, RoutedEventArgs e)
        {
            element.Loaded -= OnLoaded;
            Apply(element);
        }
        element.Loaded += OnLoaded;
    }

    public static void ApplyToWindow(XamlRoot? xamlRoot, UIElement? content)
    {
        Apply(content);
        if (xamlRoot is null) return;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot)) Apply(popup.Child);
    }

    public static void Exclude(FrameworkElement element) => element.SetValue(BaseSizeProperty, -1d);

    private static void Walk(DependencyObject d)
    {
        if (d is Panel or Border && (double)d.GetValue(BaseSizeProperty) < 0) return;
        switch (d)
        {
            case WebView2:
                return;
            case TextBlock t:
                Rescale(t, TextBlock.FontSizeProperty, t.FontSize, false);
                return;
            case RichTextBlock r:
                Rescale(r, RichTextBlock.FontSizeProperty, r.FontSize, false);
                return;
            case FontIcon f:
                Rescale(f, FontIcon.FontSizeProperty, f.FontSize, false);
                return;
            case ButtonBase or TextBox or PasswordBox or RichEditBox or AutoSuggestBox or ComboBox or ToggleSwitch or NavigationViewItem or NavigationViewItemHeader:
                var c = (Control)d;
                Rescale(c, Control.FontSizeProperty, c.FontSize, true);
                break;
        }
        var count = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < count; i++) Walk(VisualTreeHelper.GetChild(d, i));
    }

    private static void Rescale(DependencyObject d, DependencyProperty property, double current, bool styled)
    {
        var size = (double)d.GetValue(BaseSizeProperty);
        if (size <= 0)
        {
            if (!styled && d.ReadLocalValue(property) == DependencyProperty.UnsetValue) return;
            if (current <= 0) return;
            size = current;
            d.SetValue(BaseSizeProperty, size);
        }
        var target = size * Scale;
        if (Math.Abs(current - target) > 0.01) d.SetValue(property, target);
    }
}
