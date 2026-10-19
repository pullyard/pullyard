using System.Reflection;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PullYard.Core;
using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Stacks;
using PullYard.Core.Util;
using PullYard.ViewModels;
using PullYard.Views;

namespace PullYard.Services;

public static class SmokeTour
{
    private static string LogPath => Path.Combine(AppInfo.DataDirectory, "tour.log");

    private static void Log(string text)
    {
        try
        {
            File.AppendAllText(LogPath, $"{DateTimeOffset.Now:HH:mm:ss.fff} {text}\n");
        }
        catch
        {
        }
    }

    public static async Task Run(MainWindow window)
    {
        var app = AppViewModel.Shared;
        try
        {
            Place(window);
            Log("start");
            DiagnosticsService.SetRecording(true);
            await Step("launch", 9000);
            if (app.Phase != Phase.LoggedIn)
            {
                Log($"phase {app.Phase}");
                await Step("login view", 3000);
                Finish(0);
                return;
            }
            await Shot("01-review-requests");
            var pr = app.DetailRoot;
            Log($"detail {pr?.Key ?? "none"}");
            await Step("pr conversation", 9000);
            await Shot("03-pr-conversation");
            if (ShortLink.Of(pr) is { } shortLink)
            {
                ShellView.CopyShortLink(shortLink);
                await Step("short link", 300);
                await Shot("03b-pr-short-link");
                await Step("short link toast", 1500);
            }
            var root = window.Content.XamlRoot;
            string? blameRef = null;
            string? blamePath = null;
            if (pr is { Kind: RouteKind.PullRequest, Item: { } item } && app.PrModel(item) is { } model)
            {
                model.Tab = PRTab.Files;
                await Step("pr files", 12000);
                await Shot("04-pr-files");
                blameRef = model.Pr?.HeadRefOid;
                blamePath = model.Files.Where(f => f.Status == "modified" && !f.Id.EndsWith(".md", StringComparison.OrdinalIgnoreCase)).OrderBy(f => f.Additions + f.Deletions).FirstOrDefault()?.Id;
                model.Tab = PRTab.Commits;
                await Step("pr commits", 3000);
                await Shot("05-pr-commits");
                model.Tab = PRTab.Checks;
                await Step("pr checks", 4000);
                await Shot("06-pr-checks");
                await StackScreens(model, item, root);
                model.Tab = PRTab.Conversation;
                await Step("pr conversation again", 2000);
                Dialogs.Review(root, model).Forget();
                await Step("review sheet", 2500);
                await Shot("07-review-sheet");
                CloseDialogs(root);
                await Step("close", 800);
                Dialogs.Merge(root, model).Forget();
                await Step("merge sheet", 2500);
                await Shot("08-merge-sheet");
                CloseDialogs(root);
                await Step("close", 800);
                Dialogs.FixWithClaude(root, model).Forget();
                await Step("fix with claude", 3000);
                await Shot("09-fix-with-claude");
                CloseDialogs(root);
                await Step("close", 800);
            }
            var ciLink = AppInfo.Env("TOUR_CI_PR");
            if (GitHubUrl.Parse(ciLink.Length > 0 ? ciLink : "https://github.com/sharkdp/bat/pull/3918") is { Kind: RouteKind.PullRequest, Item: { } ciItem } ciRoute)
            {
                Log($"ci {ciItem}");
                app.Open(ciRoute);
                await Step("ci pr", 9000);
                if (app.PrModel(ciItem) is { } ciModel)
                {
                    await Shot("09b-ci-banner");
                    ciModel.Tab = PRTab.Checks;
                    await Step("ci checks", 3000);
                    await Shot("09c-ci-checks");
                    Dialogs.FixCi(root, ciModel).Forget();
                    await Step("ci fix", 9000);
                    await Shot("09d-ci-fix");
                    CloseDialogs(root);
                    await Step("close", 800);
                    ciModel.Tab = PRTab.Conversation;
                }
            }
            app.Section = Section.MyPrsByRepo;
            await Step("prs by project", 5000);
            await Shot("02-prs-by-project");
            app.Section = Section.Issues(IssueFilter.Assigned);
            await Step("issues", 4000);
            await Shot("10-issues");
            app.Section = Section.Notifications;
            await Step("notifications", 3000);
            await Shot("12-notifications");
            if (pr?.Repo is { } repo)
            {
                app.Section = Section.Repos;
                app.Select(Route.ForRepo(repo));
                await Step("repo code", 8000);
                await Shot("14-repo");
                if (blameRef is { Length: > 0 } && blamePath is not null)
                {
                    Log($"blame {blamePath}");
                    RepoDetailView.OpenFile(repo, blameRef, blamePath, true);
                    await Step("repo blame", 10000);
                    await Shot("14b-repo-blame");
                }
            }
            if (pr is { Kind: RouteKind.PullRequest, Item: { } stacked } && app.PrModel(stacked) is { CurrentNode: { } node } stackModel)
            {
                StackStore.Shared.Seed(stackModel.CacheAccount, stackModel.Api.Host, stacked.Repo, TourStack(node, stacked.Repo.Full));
                app.Section = Section.Stacks;
                await Step("stacks", 7000);
                stackModel.Tab = PRTab.Stack;
                app.Select(Route.Pr(stacked));
                await Step("stacks pr", 4000);
                await Shot("15b-stacks");
            }
            app.Section = Section.Projects;
            await Step("projects", 3000);
            await Shot("15-projects");
            app.Section = Section.Claude;
            await Step("claude", 5000);
            await Shot("16-claude");
            var prompt = AppInfo.Env("TOUR_PROMPT");
            var tab = app.Claude.NewSession(Demo.Folder ?? Path.GetTempPath(), prompt.Length > 0 ? prompt : null, "Cancel stale searches", null, ClaudeTabKind.Chat);
            await Step("claude chat", 1500);
            Feed(tab.Chat);
            await Step("claude chat feed", 4000);
            await Shot("16-claude-chat");
            app.Section = Section.Prs(PRFilter.ReviewRequested);
            app.RequestSettings();
            await Step("settings", 3000);
            await Shot("17-preferences");
            SettingsDialog.ScrollToEnd();
            await Step("settings support", 3000);
            DiagnosticsWindow.Show();
            await Step("diagnostics", 4000);
            Finish(App.ExitCode);
        }
        catch (Exception e)
        {
            Log("error " + e);
            Finish(5);
        }
    }

    private static async Task StackScreens(PRDetailViewModel model, ItemRef item, XamlRoot root)
    {
        if (model.CurrentNode is not { } current) return;
        Settings.Shared.Set(Keys.StackView, "list");
        Settings.Shared.Set(Keys.StackSupportAsked, false);
        var nodes = TourStack(current, item.Repo.Full);
        StackStore.Shared.Seed(model.CacheAccount, model.Api.Host, item.Repo, nodes);
        StackNotes.Shared.Replace(NoteKey(model, 9003), new[] { new StackNote(Guid.NewGuid(), StackNoteKind.Note, "Rebase after the API client lands.", DateTimeOffset.Now) });
        Memory("before stack tab");
        await model.LoadStack();
        Log($"stack {model.StackTree?.Count ?? 0} nodes");
        model.Tab = PRTab.Stack;
        await Step("stack list", 3000);
        Memory("stack list");
        await Shot("06b-pr-stack-list");
        StackTab.Last?.SetGraph(true);
        await Step("stack support", 2000);
        await Shot("06c-stack-support");
        CloseDialogs(root);
        await Step("stack graph", 1500);
        Memory("stack graph");
        await Shot("06d-pr-stack-graph");
        if (StackTab.Last is { CurrentNumber: { } n } tab)
        {
            StackNotes.Shared.Replace(NoteKey(model, n), new[]
            {
                new StackNote(Guid.NewGuid(), StackNoteKind.Decision, "Merge the API client first, then rebase the screens.", DateTimeOffset.Now),
                new StackNote(Guid.NewGuid(), StackNoteKind.Question, "Do we still need the debounce once stale requests are cancelled?", DateTimeOffset.Now.AddMinutes(-5))
            });
            tab.ShowNotes(n);
            await Step("stack notes", 1500);
            await Shot("06e-pr-stack-notes");
            tab.ShowNotes(null);
            tab.FitGraph();
            await Step("stack fit", 1500);
            Memory("stack fit");
            await Shot("06f-pr-stack-fit");
            tab.SetGraph(false);
        }
        model.Tab = PRTab.Conversation;
        await Step("stack closed", 1500);
        Memory("stack tab closed");
        TextZoom.ZoomIn();
        TextZoom.ZoomIn();
        await Step("text zoom", 1500);
        await Shot("06g-text-zoom-120");
        TextZoom.Reset();
        await Step("text zoom reset", 800);
    }

    private static string NoteKey(PRDetailViewModel model, int number) => StackNotes.Key(model.CacheAccount, model.Api.Host, model.Ref.Repo, number);

    private static void Memory(string label)
    {
        using var p = System.Diagnostics.Process.GetCurrentProcess();
        Log($"memory {label}: working set {p.WorkingSet64 / 1024 / 1024} MB, private {p.PrivateMemorySize64 / 1024 / 1024} MB");
    }

    private static List<StackNode> TourStack(StackNode current, string repo)
    {
        var now = DateTimeOffset.Now;
        StackNode Node(int number, string title, string head, string @base, string? ci = null, string? review = null, bool draft = false) =>
            new(number, title, "OPEN", draft, head, @base, repo, "octocat", now.AddMinutes(-(number - 8990)), review, ci, (0xa1b2c3 + number).ToString("x7"), $"Update {title}");
        var nodes = new List<StackNode>
        {
            Node(9000, "COM-1640 Shared API client", current.BaseRefName, "release", "SUCCESS", "APPROVED"),
            current with { UpdatedAt = now },
            Node(9001, "Search endpoint", "search-api", current.BaseRefName, "PENDING"),
            Node(9002, "PAY-7 Search screen", "search-ui", current.BaseRefName, "FAILURE"),
            Node(9003, "Cancel stale searches", "search-cancel", "search-api", "SUCCESS", "CHANGES_REQUESTED"),
            Node(9004, "Debounce typing", "search-debounce", "search-cancel", draft: true)
        };
        for (var i = 1; i <= 8; i++) nodes.Add(Node(9009 + i, $"Search screen part {i}", $"search-ui-{i}", "search-ui", i % 3 == 1 ? "SUCCESS" : null));
        return nodes;
    }

    private static void Place(MainWindow window)
    {
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        if (area.Width < 1600 || area.Height < 1000)
        {
            if (window.AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
            return;
        }
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - 1600) / 2, area.Y + (area.Height - 1000) / 2, 1600, 1000));
    }

    private static async Task Shot(string name)
    {
        Log("shot " + name);
        await Task.Delay(1500);
    }

    private static void CloseDialogs(XamlRoot root)
    {
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root))
        {
            if (popup.Child is ContentDialog dialog) dialog.Hide();
        }
    }

    private static void Feed(ChatSession? chat)
    {
        var path = AppInfo.Env("TOUR_CHAT");
        if (chat is null || path.Length == 0 || !File.Exists(path)) return;
        var consume = typeof(ChatSession).GetMethod("Consume", BindingFlags.Instance | BindingFlags.NonPublic);
        if (consume is null) return;
        foreach (var line in File.ReadAllLines(path)) consume.Invoke(chat, new object[] { line });
    }

    private static async Task Step(string name, int ms)
    {
        Log("stage " + name);
        await Task.Delay(ms);
    }

    private static void Finish(int code)
    {
        Log($"finish {code}");
        App.ExitCode = code;
        App.Quit();
    }
}
