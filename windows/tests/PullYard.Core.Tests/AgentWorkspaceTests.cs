using System.Text;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class AgentWorkspaceTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "pullyard-agents-" + Guid.NewGuid().ToString("N"));

    public AgentWorkspaceTests() => Directory.CreateDirectory(root);

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static readonly DateTimeOffset T0 = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    private static ClaudeSessionInfo S(string id, int minutes, string? parent = null, bool archived = false) => new()
    {
        Id = id,
        File = $"C:\\p\\{id}.jsonl",
        Cwd = "C:\\code\\app",
        Title = "Session " + id,
        Modified = T0.AddMinutes(minutes),
        ParentId = parent,
        Archived = archived
    };

    [Fact]
    public void TreeNestsChildrenUnderParentAndOrdersByLatestActivity()
    {
        var nodes = SessionTree.Build(new[] { S("a", 0), S("b", 5), S("a1", 10, "a"), S("a2", 2, "a"), S("orphan", 1, "missing"), S("self", 3, "self") });
        Assert.Equal(new[] { "a", "b", "self", "orphan" }, nodes.Select(n => n.Id));
        Assert.Equal(new[] { "a1", "a2" }, nodes[0].Children.Select(c => c.Id));
        Assert.All(nodes.Skip(1), n => Assert.Empty(n.Children));
    }

    [Fact]
    public void PrefsPersistPinsTitlesAndArchive()
    {
        var path = Path.Combine(root, "settings.json");
        var prefs = new AgentSessionPrefs(new Settings(path));
        var changes = 0;
        prefs.Changed += () => changes++;
        prefs.TogglePin("a");
        prefs.TogglePin("b");
        prefs.Rename("a", "  Renamed  ");
        prefs.SetArchived("b", true);
        Assert.Equal(4, changes);

        var reloaded = new AgentSessionPrefs(new Settings(path));
        Assert.Equal(new[] { "a" }, reloaded.Pinned);
        Assert.Equal("Renamed", reloaded.Title(S("a", 0)));
        Assert.Equal("Renamed", reloaded.Apply(S("a", 0)).Title);
        Assert.True(reloaded.IsArchived(S("b", 0)));
        Assert.True(reloaded.IsArchived(S("c", 0, archived: true)));

        reloaded.Rename("a", " ");
        reloaded.SetArchived("b", false);
        reloaded.TogglePin("a");
        var third = new AgentSessionPrefs(new Settings(path));
        Assert.Equal("Session a", third.Title(S("a", 0)));
        Assert.False(third.IsArchived(S("b", 0)));
        Assert.Empty(third.Pinned);
    }

    [Fact]
    public void SeenTracksUnreadAgainstBaselineAndMarks()
    {
        var path = Path.Combine(root, "seen.json");
        var now = T0;
        var seen = new SessionSeen(new Settings(path), () => now);
        Assert.False(seen.IsUnread("x", T0.AddMinutes(-1)));
        Assert.True(seen.IsUnread("x", T0.AddMinutes(1)));
        now = T0.AddMinutes(2);
        seen.Mark("x");
        Assert.False(seen.IsUnread("x", T0.AddMinutes(1)));
        Assert.True(seen.IsUnread("x", T0.AddMinutes(3)));

        var reloaded = new SessionSeen(new Settings(path), () => T0.AddDays(1));
        Assert.Equal(T0, reloaded.Baseline);
        Assert.False(reloaded.IsUnread("x", T0.AddMinutes(1)));
    }

    [Fact]
    public void IndicatorsFollowTabStateAndClosedSessionAge()
    {
        Assert.Equal(SessionIndicator.Waiting, SessionIndicators.ForTab(ClaudeTabState.Waiting, true));
        Assert.Equal(SessionIndicator.Working, SessionIndicators.ForTab(ClaudeTabState.Working, false));
        Assert.Equal(SessionIndicator.Done, SessionIndicators.ForTab(ClaudeTabState.Active, true));
        Assert.Equal(SessionIndicator.None, SessionIndicators.ForTab(ClaudeTabState.Sleeping, false));
        var seen = new SessionSeen(new Settings(Path.Combine(root, "s.json")), () => T0);
        Assert.Equal(SessionIndicator.Working, SessionIndicators.ForClosed(S("a", 10), seen, T0.AddMinutes(10).AddSeconds(5)));
        Assert.Equal(SessionIndicator.Done, SessionIndicators.ForClosed(S("a", 10), seen, T0.AddMinutes(20)));
        Assert.Equal(SessionIndicator.None, SessionIndicators.ForClosed(S("a", -10), seen, T0.AddMinutes(20)));
    }

    [Fact]
    public void DesktopMetadataParsesAndLinksParents()
    {
        Assert.Null(DesktopSessionIndex.ParseRecord("{\"sessionId\":\"local_1\"}"));
        Assert.Null(DesktopSessionIndex.ParseRecord("not json"));
        var spawned = DesktopSessionIndex.ParseRecord("{\"sessionId\":\"local_2\",\"cliSessionId\":\"cli-2\",\"spawnedFrom\":{\"sessionId\":\"local_1\"},\"title\":\"Child\",\"isArchived\":true}");
        Assert.Equal(new DesktopRecord("local_2", "cli-2", "local_1", "Child", true), spawned);
        var forked = DesktopSessionIndex.ParseRecord("{\"sessionId\":\"local_3\",\"cliSessionId\":\"cli-3\",\"forkedFromSessionId\":\"local_1\"}");
        Assert.Equal("local_1", forked!.ParentLocal);

        var account = Path.Combine(root, "desktop", "acct", "org");
        Directory.CreateDirectory(account);
        File.WriteAllText(Path.Combine(account, "local_1.json"), "{\"sessionId\":\"local_1\",\"cliSessionId\":\"cli-1\",\"title\":\"Parent\"}");
        File.WriteAllText(Path.Combine(account, "local_2.json"), "{\"sessionId\":\"local_2\",\"cliSessionId\":\"cli-2\",\"spawnedFrom\":{\"sessionId\":\"local_1\"}}");
        File.WriteAllText(Path.Combine(account, "local_4.json"), "{\"sessionId\":\"local_4\",\"cliSessionId\":\"cli-4\",\"spawnedFrom\":{\"sessionId\":\"local_gone\"}}");
        File.WriteAllText(Path.Combine(account, "broken.json"), "{");
        var links = DesktopSessionIndex.Load(new[] { Path.Combine(root, "desktop"), Path.Combine(root, "missing") });
        Assert.Equal(3, links.Count);
        Assert.Equal("cli-1", links["cli-2"].Parent);
        Assert.Null(links["cli-4"].Parent);
        Assert.Equal("Parent", links["cli-1"].Title);
        Assert.Equal("local_2", links["cli-2"].Local);
    }

    [Fact]
    public void LoadAllAppliesDesktopLinks()
    {
        var dir = Path.Combine(root, "projects", "C--code-app");
        Directory.CreateDirectory(dir);
        string Line(string type, string text) => $"{{\"type\":\"{type}\",\"cwd\":\"C:\\\\code\\\\app\",\"message\":{{\"role\":\"{type}\",\"content\":\"{text}\"}}}}\n";
        File.WriteAllText(Path.Combine(dir, "cli-1.jsonl"), Line("user", "first prompt"));
        File.WriteAllText(Path.Combine(dir, "cli-2.jsonl"), Line("user", "second prompt"));
        var links = new Dictionary<string, DesktopLink> { ["cli-2"] = new("local_2", "cli-1", "Desktop title", true) };
        var projects = ClaudeSessionParser.LoadAll(Path.Combine(root, "projects"), links);
        var sessions = projects.Single().Sessions.ToDictionary(s => s.Id);
        Assert.Equal("first prompt", sessions["cli-1"].Title);
        Assert.Equal("Desktop title", sessions["cli-2"].Title);
        Assert.Equal("cli-1", sessions["cli-2"].ParentId);
        Assert.Equal("local_2", sessions["cli-2"].DesktopId);
        Assert.True(sessions["cli-2"].Archived);
    }

    private string Transcript(string name, params string[] lines)
    {
        var path = Path.Combine(root, name);
        File.WriteAllText(path, string.Join("\n", lines) + "\n");
        return path;
    }

    [Fact]
    public void ExtractKeepsPromptsAndAssistantTextOnly()
    {
        var file = Transcript("a.jsonl",
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Fix the Login bug\"}}",
            "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"role\":\"user\",\"content\":\"meta noise\"}}",
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/clear</command-name>\"}}",
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"tool output secret\"}]}}",
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hidden thought\"},{\"type\":\"text\",\"text\":\"Done with the FIX\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"rm stuff\"}}]}}",
            "{\"type\":\"summary\",\"summary\":\"summary text\"}",
            "garbage line");
        var text = SessionIndex.Extract(file);
        Assert.Equal("fix the login bug\ndone with the fix", text);
    }

    [Fact]
    public void SearchFindsMatchesWithSnippetsAndRefreshesChangedFiles()
    {
        var a = Transcript("a.jsonl", "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Please refactor the payment gateway module\"}}");
        var b = Transcript("b.jsonl", "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Nothing related here\"}]}}");
        var index = new SessionIndex(Path.Combine(root, "index"));
        var hits = index.Search("Payment Gateway", new[] { a, b });
        Assert.Single(hits);
        Assert.Equal("please refactor the payment gateway module", hits[a]);
        Assert.True(File.Exists(Path.Combine(root, "index", SessionIndex.Key(a) + ".txt")));

        File.WriteAllText(b, "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Updated the payment gateway tests\"}]}}\n");
        File.SetLastWriteTimeUtc(b, DateTime.UtcNow.AddMinutes(1));
        var again = new SessionIndex(Path.Combine(root, "index")).Search("payment gateway", new[] { a, b });
        Assert.Equal(2, again.Count);
        Assert.Contains("payment gateway tests", again[b]);
        Assert.Empty(index.Search("   ", new[] { a }));
    }

    [Fact]
    public void WarmRunsOnce()
    {
        var a = Transcript("a.jsonl", "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}");
        var index = new SessionIndex(Path.Combine(root, "warm"));
        Assert.True(index.Warm(new[] { a }));
        Assert.False(index.Warm(new[] { a }));
        Assert.True(File.Exists(Path.Combine(root, "warm", "stamps.json")));
    }

    [Fact]
    public void SnippetTrimsAroundMatch()
    {
        var text = new string('a', 200) + "needle" + new string('b', 200);
        var data = Encoding.UTF8.GetBytes(text);
        var snippet = SessionIndex.Snippet(data, 200, 6);
        Assert.StartsWith("…", snippet);
        Assert.EndsWith("…", snippet);
        Assert.Contains("needle", snippet);
        Assert.Equal(90 + 6 + 140 + 2, snippet.Length);
        Assert.Equal("x needle y", SessionIndex.Snippet(Encoding.UTF8.GetBytes("x\nneedle y"), 2, 6));
        var multi = Encoding.UTF8.GetBytes("x" + new string('é', 60) + "z" + "needle");
        Assert.DoesNotContain('\uFFFD', SessionIndex.Snippet(multi, multi.Length - 6, 6));
    }

    private sealed class FakeProbe : IAppProbe
    {
        public readonly HashSet<string> Files = new(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, string> Path = new();

        public string Expand(string path) => path
            .Replace("%LOCALAPPDATA%", @"C:\Users\me\AppData\Local")
            .Replace("%ProgramFiles%", @"C:\Program Files")
            .Replace("%SystemRoot%", @"C:\Windows");

        public bool FileExists(string path) => Files.Contains(path);

        public IEnumerable<string> Directories(string parent, string pattern)
        {
            var prefix = pattern.TrimEnd('*');
            return Files.Select(f => f.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase) ? f[(parent.Length + 1)..].Split('\\')[0] : null)
                .Where(n => n is not null && n.Length > 0 && n.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && Files.Any(f => f.StartsWith(parent + "\\" + n + "\\", StringComparison.OrdinalIgnoreCase)))
                .Distinct()
                .Select(n => parent + "\\" + n);
        }

        public string? OnPath(string name) => Path.TryGetValue(name, out var p) ? p : null;
    }

    [Fact]
    public void DetectsInstalledEditorsAndTerminals()
    {
        var probe = new FakeProbe();
        probe.Files.Add(@"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe");
        probe.Files.Add(@"C:\Program Files\JetBrains\IntelliJ IDEA 2025.1\bin\idea64.exe");
        probe.Files.Add(@"C:\Program Files\JetBrains\IntelliJ IDEA 2025.10\bin\idea64.exe");
        probe.Files.Add(@"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe");
        probe.Files.Add(@"C:\Program Files\Android\Android Studio\bin\studio64.exe");
        probe.Files.Add(@"C:\Users\me\AppData\Local\Microsoft\WindowsApps\wt.exe");
        probe.Files.Add(@"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe");
        probe.Files.Add(@"C:\Windows\System32\cmd.exe");
        probe.Path["cursor"] = @"D:\tools\cursor\cursor.cmd";
        var apps = ExternalApps.Detect(probe);
        var ids = apps.Select(a => a.Id).ToList();
        Assert.Equal(new[] { "vscode", "cursor", "intellij", "androidstudio", "visualstudio", "wt", "powershell", "cmd", "explorer" }, ids);
        Assert.Equal(@"C:\Program Files\JetBrains\IntelliJ IDEA 2025.10\bin\idea64.exe", apps.Single(a => a.Id == "intellij").Path);
        Assert.Equal(@"D:\tools\cursor\cursor.cmd", apps.Single(a => a.Id == "cursor").Path);
        Assert.Equal("explorer.exe", apps.Single(a => a.Id == "explorer").Path);
        Assert.Equal(ExternalAppKind.Terminal, apps.Single(a => a.Id == "wt").Kind);

        probe.Files.Add(@"C:\Program Files\PowerShell\7\pwsh.exe");
        var withPwsh = ExternalApps.Detect(probe).Select(a => a.Id).ToList();
        Assert.Contains("pwsh", withPwsh);
        Assert.DoesNotContain("powershell", withPwsh);
    }

    [Fact]
    public void PrimaryPrefersRememberedChoiceThenFirstEditor()
    {
        var apps = new List<ExternalApp>
        {
            new("wt", "Windows Terminal", ExternalAppKind.Terminal, "wt.exe"),
            new("zed", "Zed", ExternalAppKind.Editor, "zed.exe"),
            new("explorer", "File Explorer", ExternalAppKind.Explorer, "explorer.exe")
        };
        Assert.Equal("wt", ExternalApps.Primary(apps, "wt")!.Id);
        Assert.Equal("zed", ExternalApps.Primary(apps, "gone")!.Id);
        Assert.Equal("zed", ExternalApps.Primary(apps, null)!.Id);
        Assert.Null(ExternalApps.Primary(new List<ExternalApp>(), null));
    }

    [Fact]
    public void LaunchSpecsMatchEachAppKind()
    {
        const string folder = @"C:\code\my app";
        var wt = ExternalApps.Launch(new ExternalApp("wt", "", ExternalAppKind.Terminal, "wt.exe"), folder);
        Assert.Equal(new[] { "-d", folder }, wt.Args);
        var pwsh = ExternalApps.Launch(new ExternalApp("pwsh", "", ExternalAppKind.Terminal, "pwsh.exe"), folder);
        Assert.True(pwsh.Console);
        Assert.Equal(folder, pwsh.WorkingDirectory);
        Assert.Equal(new[] { "-NoExit" }, pwsh.Args);
        var explorer = ExternalApps.Launch(new ExternalApp("explorer", "", ExternalAppKind.Explorer, "explorer.exe"), folder);
        Assert.Equal(new[] { folder }, explorer.Args);
        Assert.Null(explorer.WorkingDirectory);
        var code = ExternalApps.Launch(new ExternalApp("vscode", "", ExternalAppKind.Editor, "Code.exe"), folder);
        Assert.Equal("Code.exe", code.File);
        Assert.Equal(new[] { folder }, code.Args);
        Assert.False(code.Console);
    }

    [Fact]
    public void BadgeBitmapDrawsCircleAndLabel()
    {
        Assert.Equal("", BadgeBitmap.Label(0));
        Assert.Equal("3", BadgeBitmap.Label(3));
        Assert.Equal("9+", BadgeBitmap.Label(42));
        var empty = BadgeBitmap.Render(0, 16);
        Assert.All(empty, b => Assert.Equal(0, b));
        var px = BadgeBitmap.Render(1, 16);
        Assert.Equal(16 * 16 * 4, px.Length);
        Assert.Equal(0, px[3]);
        var center = (8 * 16 + 8) * 4;
        Assert.Equal(255, px[center + 3]);
        var whites = Enumerable.Range(0, 256).Count(i => px[i * 4] == 255 && px[i * 4 + 1] == 255 && px[i * 4 + 2] == 255);
        Assert.True(whites >= 7);
    }

    [Fact]
    public void SnippetHelperFlattensAndTruncates()
    {
        Assert.Equal("", ClaudeWorkspace.Snippet(null));
        Assert.Equal("a b c", ClaudeWorkspace.Snippet(" a\n b\t\tc "));
        Assert.Equal(new string('x', 10) + "…", ClaudeWorkspace.Snippet(new string('x', 30), 10));
    }
}
