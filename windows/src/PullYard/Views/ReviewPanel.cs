using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PullYard.Controls;
using PullYard.Core.Api;
using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;
using Windows.System;

namespace PullYard.Views;

public sealed class ReviewPanel : Grid
{
    public const string OpenKey = "pr.reviewPanel";

    private readonly PRDetailViewModel model;
    private readonly Action close;
    private readonly StackPanel progress = Ui.V(6);
    private readonly StackPanel pending = Ui.V(6);
    private readonly ContentControl verdictHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private readonly TextBox summary;
    private readonly Button submit = new() { HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(12, 7, 12, 7) };
    private readonly TextBlock reason = Ui.Text("", 12, "amberInk", wrap: true);
    private string verdict = "COMMENT";
    private bool sending;

    public static bool IsOpen => Settings.Shared.GetBool(OpenKey, false);

    public ReviewPanel(PRDetailViewModel model, Action close)
    {
        this.model = model;
        this.close = close;
        Width = 320;
        Background = Palette.Brush("panel");
        BorderBrush = Palette.Brush("line");
        BorderThickness = new Thickness(1, 0, 0, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        AutomationProperties.SetName(this, L.T("ReviewPanel_Name", "Review panel"));

        var title = Ui.Text(L.F("Review_Title", "Review #{0}", model.Ref.Number), 14, "text", FontWeights.SemiBold);
        var closeButton = Ui.IconButton("", L.T("ReviewPanel_Close", "Close review panel (Ctrl+Alt+I)"), close);
        var head = Ui.Columns((title, Ui.Star), (closeButton, Ui.Auto));
        head.Padding = new Thickness(14, 8, 6, 8);
        var headLine = Ui.Line();
        headLine.VerticalAlignment = VerticalAlignment.Bottom;
        var header = new Grid();
        header.Children.Add(head);
        header.Children.Add(headLine);
        Children.Add(header);

        summary = Dialogs.Editor(L.T("Review_Summary", "Review summary (optional when approving)"), model.SummaryDraft, minHeight: 110);
        summary.TextChanged += (_, _) =>
        {
            if (summary.Text != model.SummaryDraft) model.SetSummaryDraft(summary.Text);
            Validate();
        };
        reason.Visibility = Visibility.Collapsed;
        var body = Ui.V(16, progress, verdictHost, Ui.V(6, Section(L.T("ReviewPanel_Summary", "Summary")), summary), Ui.V(6, Section(L.T("ReviewPanel_Pending", "Pending comments")), pending));
        body.Padding = new Thickness(14, 12, 14, 12);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        SetRow(scroll, 1);
        Children.Add(scroll);

        submit.Click += (_, _) => Submit().Forget();
        var foot = Ui.V(6, reason, submit);
        foot.Padding = new Thickness(14, 10, 14, 12);
        var footLine = Ui.Line();
        footLine.VerticalAlignment = VerticalAlignment.Top;
        var footer = new Grid();
        footer.Children.Add(footLine);
        footer.Children.Add(foot);
        SetRow(footer, 2);
        Children.Add(footer);

        var send = new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control };
        send.Invoked += (_, e) =>
        {
            e.Handled = true;
            Submit().Forget();
        };
        KeyboardAccelerators.Add(send);

        Loaded += (_, _) =>
        {
            model.PropertyChanged -= OnModel;
            model.PropertyChanged += OnModel;
            Render();
        };
        Unloaded += (_, _) => model.PropertyChanged -= OnModel;
        Render();
    }

    private static TextBlock Section(string text) => Ui.Text(text.ToUpperInvariant(), 10, "muted", FontWeights.SemiBold);

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PRDetailViewModel.Pr) or nameof(PRDetailViewModel.PendingCount) or nameof(PRDetailViewModel.DiffVersion) or nameof(PRDetailViewModel.Files) or nameof(PRDetailViewModel.Busy))
            DispatcherQueue.TryEnqueue(Render);
        if (e.PropertyName == nameof(PRDetailViewModel.SummaryDraft) && summary.Text != model.SummaryDraft)
            DispatcherQueue.TryEnqueue(() => summary.Text = model.SummaryDraft);
    }

    private void Render()
    {
        RenderProgress();
        RenderVerdict();
        RenderPending();
        Validate();
    }

    private void RenderProgress()
    {
        progress.Children.Clear();
        var files = model.Files;
        var viewed = files.Count(f => model.ViewedPaths.Contains(f.Id));
        var total = Math.Max(files.Count, model.Pr?.ChangedFiles ?? 0);
        progress.Children.Add(Ui.Columns((Ui.Text(L.F("ReviewPanel_FilesViewed", "{0}/{1} files viewed", viewed, total), 13, "text", FontWeights.Medium), Ui.Star)));
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = total == 0 ? 0 : (double)viewed / total, Height = 4, MinHeight = 4, Foreground = Palette.Brush("coral"), Background = Palette.Brush("harborLine") };
        AutomationProperties.SetName(bar, L.T("Files_Viewed", "Viewed"));
        progress.Children.Add(bar);
        var unresolved = model.Pr?.ReviewThreads.Items.Count(t => !t.IsResolved && !t.IsOutdated) ?? 0;
        if (unresolved > 0) progress.Children.Add(Ui.StatusChip(L.F("ReviewPanel_Unresolved", "{0} unresolved threads", unresolved), "amber", ""));
        if (files.FirstOrDefault(f => !model.ViewedPaths.Contains(f.Id)) is { } next)
        {
            var go = Ui.Button(L.T("ReviewPanel_NextUnviewed", "Next unviewed file"), () =>
            {
                model.Tab = PRTab.Files;
                model.RevealFile(next.Id);
            }, glyph: "", tooltip: next.Id);
            go.HorizontalAlignment = HorizontalAlignment.Left;
            progress.Children.Add(go);
        }
        else if (files.Count == 0 && !model.FilesLoaded)
        {
            progress.Children.Add(Ui.Link(L.T("ReviewPanel_LoadFiles", "Load changed files"), () => model.LoadFiles().Forget()));
        }
    }

    private void RenderVerdict()
    {
        if (model.Pr is not { } pr || pr.ViewerDidAuthor)
        {
            verdict = "COMMENT";
            verdictHost.Content = null;
            return;
        }
        if (verdictHost.Content is not null) return;
        verdictHost.Content = Ui.V(6, Section(L.T("Review_Verdict", "Verdict")), Dialogs.Segments(new (string, string, string?)[]
        {
            ("COMMENT", L.T("Review_SegComment", "Comment"), null),
            ("APPROVE", L.T("PR_Approve", "Approve"), null),
            ("REQUEST_CHANGES", L.T("ReviewPanel_Changes", "Changes"), null)
        }, verdict, v =>
        {
            verdict = v;
            Validate();
        }, L.T("Review_Verdict", "Verdict")));
    }

    private void RenderPending()
    {
        pending.Children.Clear();
        if (model.PendingCount == 0)
        {
            pending.Children.Add(Ui.Text(L.T("ReviewPanel_PendingEmpty", "Inline comments you add in Files collect here until you submit."), 12, "muted", wrap: true));
            return;
        }
        foreach (var group in model.Pending.GroupBy(p => p.Path))
        {
            var file = Ui.Text(group.Key, 12, "link", mono: true);
            file.TextTrimming = TextTrimming.CharacterEllipsis;
            Ui.Tip(file, group.Key);
            pending.Children.Add(file);
            foreach (var c in group.OrderBy(c => c.Line))
            {
                var open = new Button
                {
                    Content = Ui.Columns((Ui.Text($"L{c.Line}", 11, "dim", mono: true), Ui.Auto), (Ui.Text(c.Body.ReplaceLineEndings(" "), 12.5, "text", maxLines: 2), Ui.Star)),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(4, 3, 4, 3)
                };
                var path = c.Path;
                open.Click += (_, _) =>
                {
                    model.Tab = PRTab.Files;
                    model.RevealFile(path);
                };
                Ui.Tip(open, c.Body);
                AutomationProperties.SetName(open, $"{path}:{c.Line}, {c.Body}");
                var id = c.Id;
                var remove = Ui.IconButton("", L.T("ReviewPanel_Remove", "Remove comment"), () => model.RemovePending(id));
                remove.Padding = new Thickness(6, 3, 6, 3);
                pending.Children.Add(Ui.Columns((open, Ui.Star), (remove, Ui.Auto)));
            }
        }
    }

    private void Validate()
    {
        var ready = verdict == "APPROVE" || summary.Text.Trim().Length > 0 || model.PendingCount > 0;
        var key = verdict switch { "APPROVE" => "green", "REQUEST_CHANGES" => "red", _ => "accent" };
        submit.Content = sending ? L.T("Composer_Sending", "Sending…") : verdict switch
        {
            "APPROVE" => L.T("PR_Approve", "Approve"),
            "REQUEST_CHANGES" => L.T("Review_RequestChanges", "Request changes"),
            _ => L.T("Review_SubmitComment", "Comment")
        };
        Ui.Tint(submit, key);
        submit.IsEnabled = ready && !sending && model.Pr is { IsOpen: true } && !model.Busy;
        Ui.Tip(submit, L.T("ReviewPanel_SubmitHint", "Submit review (Ctrl+Enter)"));
        reason.Text = ready ? "" : L.T("Review_WhyComment", "Write a summary or add inline comments to send a comment.");
        reason.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
    }

    private async Task Submit()
    {
        if (!submit.IsEnabled || sending) return;
        sending = true;
        Validate();
        var sent = verdict;
        try
        {
            if (await model.SubmitReview(sent, summary.Text))
            {
                summary.Text = "";
                Dialogs.ReviewToast(model, sent);
            }
        }
        finally
        {
            sending = false;
            Render();
        }
    }
}
