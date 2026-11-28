using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PullYard.Core.Claude;
using PullYard.Services;

namespace PullYard.Controls;

public static class AgentAccount
{
    private static readonly string[] Tints = { "sky", "violet", "teal", "amberInk", "indigo", "coralInk" };

    public static string ColorKey(string id)
    {
        if (id == ClaudeProfiles.DefaultId) return Tints[0];
        var sum = id.Sum(c => (int)c);
        return Tints[1 + sum % (Tints.Length - 1)];
    }

    public static string Describe(ClaudeProfile profile) => profile.Email is { } e ? $"{profile.Label} · {e}" : profile.Label;

    public static FrameworkElement? Chip(ClaudeProfile? profile, bool compact = false)
    {
        if (profile is null || !ClaudeProfiles.Shared.HasSeveral) return null;
        var tint = ColorKey(profile.Id);
        var text = Ui.Text(compact ? profile.Initial : profile.Label, 10, tint, FontWeights.SemiBold);
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.MaxLines = 1;
        var chip = new Border
        {
            Background = Palette.Brush(tint, 0.14),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(compact ? 5 : 6, 1, compact ? 5 : 6, 1),
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = compact ? 40 : 140,
            Child = text
        };
        Ui.Tip(chip, Describe(profile));
        AutomationProperties.SetName(chip, L.F("Agents_AccountChip", "Account {0}", profile.Label));
        return chip;
    }

    public static FrameworkElement? Filter(ClaudeWorkspace ws, Action changed)
    {
        var profiles = ClaudeProfiles.Shared;
        if (!profiles.HasSeveral) return null;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var current = ws.AccountFilter;
        row.Children.Add(FilterButton(L.T("Agents_AccountAll", "All"), null, "muted", current is null, L.T("Agents_AccountAllHint", "Sessions from all accounts"), ws, changed));
        foreach (var p in profiles.Visible)
            row.Children.Add(FilterButton(p.Label, p.Id, ColorKey(p.Id), current == p.Id, L.F("Agents_AccountOnlyHint", "Only sessions from {0}", p.Label), ws, changed));
        var scroll = new ScrollViewer
        {
            Content = row,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled
        };
        AutomationProperties.SetName(scroll, L.T("Agents_AccountFilter", "Filter sessions by account"));
        return scroll;
    }

    private static Button FilterButton(string title, string? id, string tint, bool selected, string tip, ClaudeWorkspace ws, Action changed)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (id is not null) content.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, Fill = Palette.Brush(tint), VerticalAlignment = VerticalAlignment.Center });
        var label = Ui.Text(title, 12, selected ? "text" : "muted", selected ? FontWeights.SemiBold : FontWeights.Normal);
        label.MaxLines = 1;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        label.MaxWidth = 120;
        content.Children.Add(label);
        var b = new Button
        {
            Content = content,
            Background = selected ? Palette.Brush("raised") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderBrush = Palette.Brush(selected ? "lineStrong" : "line"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(8, 2, 8, 3),
            MinHeight = 0,
            MinWidth = 0
        };
        Ui.Tip(b, tip);
        AutomationProperties.SetName(b, title);
        AutomationProperties.SetItemStatus(b, selected ? L.T("A11y_Selected", "Selected") : "");
        b.Click += (_, _) =>
        {
            ws.AccountFilter = id;
            changed();
        };
        return b;
    }

    public static void AddNewAsItems(IList<MenuFlyoutItemBase> items, Action<string> start, string? header = null)
    {
        var profiles = ClaudeProfiles.Shared;
        if (!profiles.HasSeveral) return;
        var sub = new MenuFlyoutSubItem { Text = header ?? L.T("Agents_NewChatAs", "New chat as") };
        foreach (var p in profiles.Visible)
        {
            var id = p.Id;
            sub.Items.Add(Ui.MenuItem(Describe(p), () => start(id)));
        }
        items.Add(sub);
    }
}
