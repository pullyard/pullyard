using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public abstract class ListPane : Grid
{
    protected readonly AppViewModel Model = AppViewModel.Shared;
    protected readonly TextBlock TitleText;
    protected readonly TextBlock CountText = Ui.Text("", 13, "muted");
    protected readonly StackPanel Tools = Ui.H(2);
    protected readonly StackPanel FilterRow = Ui.V(6);
    protected readonly WakeBar LoadingBar = new() { Visibility = Visibility.Collapsed };
    protected readonly RefreshContainer Refresh = new();
    protected readonly ListView List;
    protected readonly RowAppear Appear;
    protected readonly ContentControl Overlay = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, IsTabStop = false, IsHitTestVisible = true };
    protected readonly RefreshFooter Footer = new();
    protected readonly StackPanel Notice = Ui.V(0);
    private readonly LiveRefresh live;
    private bool subscribed;
    private string noticeKey = "";

    protected ListPane(string title, string template)
    {
        TitleText = Ui.Text(title, 15, "text", FontWeights.SemiBold);
        live = new LiveRefresh(this, OnLiveTick);
        List = ListSupport.Create(template);
        Appear = new RowAppear(List, RowKey);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = Ui.Columns((Ui.H(8, TitleText, CountText), Ui.Star), (Tools, Ui.Auto), (Ui.RefreshButton(OnPullRefresh), Ui.Auto));
        header.ColumnSpacing = 2;
        header.Padding = new Thickness(14, 10, 8, 6);
        Children.Add(header);

        FilterRow.Padding = new Thickness(12, 0, 12, 6);
        SetRow(FilterRow, 1);
        Children.Add(FilterRow);

        SetRow(LoadingBar, 2);
        Children.Add(LoadingBar);

        Refresh.Content = List;
        Refresh.RefreshRequested += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            try
            {
                await OnPullRefresh();
            }
            finally
            {
                deferral.Complete();
            }
        };
        var area = new Grid();
        area.Children.Add(Refresh);
        area.Children.Add(Overlay);
        SetRow(area, 3);
        Children.Add(area);

        Notice.Visibility = Visibility.Collapsed;
        SetRow(Notice, 4);
        Children.Add(Notice);

        Footer.Retry = () => OnPullRefresh().Forget();
        SetRow(Footer, 5);
        Children.Add(Footer);

        Loaded += (_, _) =>
        {
            if (subscribed) return;
            subscribed = true;
            Model.RefreshRequested += OnManualRefresh;
            Model.LiveTick += live.Tick;
            OnAttached();
        };
        Unloaded += (_, _) =>
        {
            subscribed = false;
            Model.RefreshRequested -= OnManualRefresh;
            Model.LiveTick -= live.Tick;
        };
    }

    private static string? RowKey(object item) => item switch
    {
        SearchItem s => s.Id,
        GroupedSearchItem g => g.Item.Id,
        SnoozedSearchItem z => z.Item.Id,
        NotificationThread n => n.Id,
        RepoSummary r => r.Id,
        ProjectSummary p => p.Id,
        _ => null
    };

    protected virtual void OnAttached()
    {
    }

    private void OnManualRefresh() => OnPullRefresh().Forget();

    protected virtual void OnLiveTick()
    {
    }

    protected abstract Task OnPullRefresh();

    protected void ShowOverlay(FrameworkElement? element)
    {
        Overlay.Content = element;
        Overlay.Visibility = element is null ? Visibility.Collapsed : Visibility.Visible;
    }

    protected void SetLoading(bool loading, bool hasItems)
    {
        LoadingBar.Visibility = loading && hasItems ? Visibility.Visible : Visibility.Collapsed;
        List.Opacity = loading && hasItems ? 0.6 : 1;
    }

    protected void SetNotice(string key, params FrameworkElement?[] rows)
    {
        if (key == noticeKey) return;
        noticeKey = key;
        Notice.Children.Clear();
        foreach (var row in rows)
            if (row is not null) Notice.Children.Add(row);
        Notice.Visibility = Notice.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    protected void OnRowOpen(Action<object> open)
    {
        List.DoubleTapped += (_, e) =>
        {
            if (RowItem(e.OriginalSource as DependencyObject) is { } item) open(item);
        };
        List.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter || e.OriginalSource is not ListViewItem row || List.ItemFromContainer(row) is not { } item) return;
            e.Handled = true;
            open(item);
        };
    }

    private object? RowItem(DependencyObject? node)
    {
        while (node is not null)
        {
            if (node is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return null;
            if (node is ListViewItem row) return List.ItemFromContainer(row);
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        }
        return null;
    }

    public static FrameworkElement LoadingMoreRow()
    {
        var row = Ui.H(8, Ui.Spinner(14), Ui.Caption(L.T("List_LoadingMore", "Loading more…")));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        row.Padding = new Thickness(12, 6, 12, 6);
        return row;
    }

    public static FrameworkElement LoadMoreErrorRow(string message, Action retry)
    {
        var detail = Ui.Text(message, 12, "muted", maxLines: 2);
        Ui.Tip(detail, message);
        var words = Ui.V(1, Ui.Text(L.T("List_LoadMoreFailed", "Couldn’t load more results"), 13, "text", FontWeights.Medium), detail);
        var grid = Ui.Columns((Ui.Glyph("\uE7BA", 14, "amber"), Ui.Auto), (words, Ui.Star), (Ui.Button(L.T("Common_Retry", "Retry"), retry), Ui.Auto));
        grid.Padding = new Thickness(14, 6, 12, 6);
        return grid;
    }

    public static FrameworkElement NoteRow(string text)
    {
        var note = Ui.Text(text, 12, "muted", wrap: true);
        note.Margin = new Thickness(14, 6, 14, 6);
        return note;
    }

    public static FrameworkElement ActionRow(string glyph, string text, string buttonText, Action action)
    {
        var grid = Ui.Columns((Ui.Glyph(glyph, 13), Ui.Auto), (Ui.Text(text, 12.5, "muted", maxLines: 1), Ui.Star), (Ui.Button(buttonText, action), Ui.Auto));
        grid.Padding = new Thickness(14, 6, 12, 6);
        return grid;
    }

    protected static SelectorBar StateBar(StateFilter current, Action<StateFilter> changed)
    {
        var bar = new SelectorBar();
        foreach (var s in Enum.GetValues<StateFilter>())
        {
            var item = new SelectorBarItem { Text = s.Title(), Tag = s };
            bar.Items.Add(item);
            if (s == current) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (sender, _) =>
        {
            if (sender.SelectedItem?.Tag is StateFilter f) changed(f);
        };
        return bar;
    }

    protected static TextBox SearchBox(string placeholder, Action<string> changed, int debounceMs = 350)
    {
        var box = new TextBox { PlaceholderText = placeholder };
        DispatcherTimer? timer = null;
        box.TextChanged += (_, _) =>
        {
            timer?.Stop();
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(debounceMs) };
            timer.Tick += (t, _) =>
            {
                ((DispatcherTimer)t!).Stop();
                changed(box.Text);
            };
            timer.Start();
        };
        return box;
    }

    protected static AppBarToggleButton Toggle(string glyph, string tooltip, bool on, Action<bool> changed)
    {
        var b = new AppBarToggleButton { Icon = new FontIcon { Glyph = glyph, FontFamily = Ui.Icons }, IsChecked = on, LabelPosition = CommandBarLabelPosition.Collapsed, Width = 40, Height = 36 };
        ToolTipService.SetToolTip(b, tooltip);
        Ui.Named(b, tooltip);
        b.Click += (_, _) => changed(b.IsChecked == true);
        return b;
    }
}
