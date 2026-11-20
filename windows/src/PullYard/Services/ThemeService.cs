using Microsoft.UI.Xaml;
using PullYard.Core.Html;
using PullYard.Core.Util;

namespace PullYard.Services;

public enum ThemeStyle { PullYard, System }

public enum AppearanceMode { Auto, Light, Dark }

public static class ThemeService
{
    private static FrameworkElement? root;
    private static Windows.UI.ViewManagement.AccessibilitySettings? accessibility;
    private static bool? highContrast;
    private static bool applying;

    public static event Action? Changed;

    public static ThemeStyle Style
    {
        get => Settings.Shared.GetString(Keys.ThemeStyle) == "system" ? ThemeStyle.System : ThemeStyle.PullYard;
        set
        {
            Settings.Shared.Set(Keys.ThemeStyle, value == ThemeStyle.System ? "system" : "brand");
            Apply();
        }
    }

    public static AppearanceMode Appearance
    {
        get => Settings.Shared.GetString(Keys.ThemeAppearance) switch
        {
            "light" => AppearanceMode.Light,
            "dark" => AppearanceMode.Dark,
            _ => AppearanceMode.Auto
        };
        set
        {
            Settings.Shared.Set(Keys.ThemeAppearance, value switch
            {
                AppearanceMode.Light => "light",
                AppearanceMode.Dark => "dark",
                _ => "auto"
            });
            Apply();
        }
    }

    public static bool IsBrand => Style == ThemeStyle.PullYard && !IsHighContrast;

    public static bool IsHighContrast
    {
        get
        {
            if (highContrast is { } known) return known;
            try
            {
                accessibility ??= new Windows.UI.ViewManagement.AccessibilitySettings();
                highContrast = accessibility.HighContrast;
            }
            catch
            {
                highContrast = false;
            }
            return highContrast.Value;
        }
    }

    public static bool IsDark
    {
        get
        {
            if (root is not null) return root.ActualTheme == ElementTheme.Dark;
            return Application.Current?.RequestedTheme == ApplicationTheme.Dark;
        }
    }

    public static void Attach(FrameworkElement element)
    {
        root = element;
        element.ActualThemeChanged += (_, _) =>
        {
            if (applying) return;
            var was = highContrast;
            highContrast = null;
            if (was is { } known && known != IsHighContrast) Apply();
            else Notify();
        };
        Palette.WatchAccent(element.DispatcherQueue, Notify);
        try
        {
            accessibility ??= new Windows.UI.ViewManagement.AccessibilitySettings();
            var queue = element.DispatcherQueue;
            accessibility.HighContrastChanged += (sender, _) =>
            {
                var value = sender.HighContrast;
                queue.TryEnqueue(() =>
                {
                    if (highContrast == value) return;
                    highContrast = value;
                    Apply();
                });
            };
        }
        catch
        {
        }
        Apply();
    }

    private static void Notify()
    {
        Palette.Refresh();
        ConversationHtml.Brand = IsBrand;
        ConversationHtml.Vars = WebVars();
        Changed?.Invoke();
    }

    public static void Apply()
    {
        var app = Application.Current;
        if (app is not null)
        {
            var dictionaries = app.Resources.MergedDictionaries;
            var source = new Uri(IsBrand ? "ms-appx:///Themes/Brand.xaml" : "ms-appx:///Themes/System.xaml");
            var index = -1;
            for (var i = 0; i < dictionaries.Count; i++)
            {
                var s = dictionaries[i].Source?.ToString() ?? "";
                if (s.EndsWith("Themes/Brand.xaml", StringComparison.OrdinalIgnoreCase) || s.EndsWith("Themes/System.xaml", StringComparison.OrdinalIgnoreCase)) index = i;
            }
            if (index < 0 || dictionaries[index].Source?.ToString() != source.ToString())
            {
                var next = new ResourceDictionary { Source = source };
                if (index >= 0) dictionaries[index] = next;
                else dictionaries.Add(next);
            }
        }
        if (root is not null)
        {
            var target = Appearance switch
            {
                AppearanceMode.Light => ElementTheme.Light,
                AppearanceMode.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default
            };
            applying = true;
            try
            {
                root.RequestedTheme = root.ActualTheme == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark;
                root.RequestedTheme = target;
            }
            finally
            {
                applying = false;
            }
        }
        Notify();
    }

    public static string WebVars() => PullYard.Core.Theming.ThemeTokens.CssVars(Palette.Argb, IsDark, IsBrand);
}
