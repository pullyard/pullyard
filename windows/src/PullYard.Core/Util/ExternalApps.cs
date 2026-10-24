namespace PullYard.Core.Util;

public enum ExternalAppKind { Editor, Terminal, Explorer }

public sealed record ExternalApp(string Id, string Name, ExternalAppKind Kind, string Path);

public sealed record LaunchSpec(string File, IReadOnlyList<string> Args, string? WorkingDirectory, bool Console);

public interface IAppProbe
{
    string Expand(string path);
    bool FileExists(string path);
    IEnumerable<string> Directories(string parent, string pattern);
    string? OnPath(string name);
}

public sealed class SystemAppProbe : IAppProbe
{
    public string Expand(string path) => Environment.ExpandEnvironmentVariables(path);

    public bool FileExists(string path)
    {
        try
        {
            return File.Exists(path);
        }
        catch
        {
            return false;
        }
    }

    public IEnumerable<string> Directories(string parent, string pattern)
    {
        try
        {
            return Directory.Exists(parent) ? Directory.GetDirectories(parent, pattern) : Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    public string? OnPath(string name) => Proc.FindOnPath(name);
}

public static class ExternalApps
{
    public sealed record Candidate(string Id, string Name, ExternalAppKind Kind, string[] Paths, string[] PathNames);

    public const string ExplorerId = "explorer";

    public static readonly Candidate[] Known =
    {
        new("vscode", "VS Code", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe", @"%ProgramFiles%\Microsoft VS Code\Code.exe", @"%ProgramFiles(x86)%\Microsoft VS Code\Code.exe" },
            new[] { "code" }),
        new("cursor", "Cursor", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\cursor\Cursor.exe", @"%ProgramFiles%\Cursor\Cursor.exe" },
            new[] { "cursor" }),
        new("windsurf", "Windsurf", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\Windsurf\Windsurf.exe", @"%ProgramFiles%\Windsurf\Windsurf.exe" },
            new[] { "windsurf" }),
        new("zed", "Zed", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\Zed\Zed.exe", @"%LOCALAPPDATA%\Zed\Zed.exe", @"%ProgramFiles%\Zed\Zed.exe" },
            new[] { "zed" }),
        new("sublime", "Sublime Text", ExternalAppKind.Editor,
            new[] { @"%ProgramFiles%\Sublime Text\sublime_text.exe", @"%ProgramFiles%\Sublime Text 3\sublime_text.exe" },
            new[] { "subl" }),
        new("intellij", "IntelliJ IDEA", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\IntelliJ IDEA*\bin\idea64.exe", @"%ProgramFiles%\JetBrains\IntelliJ IDEA*\bin\idea64.exe", @"%LOCALAPPDATA%\JetBrains\Toolbox\apps\IDEA-*\*\*\bin\idea64.exe" },
            new[] { "idea64", "idea" }),
        new("webstorm", "WebStorm", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\WebStorm*\bin\webstorm64.exe", @"%ProgramFiles%\JetBrains\WebStorm*\bin\webstorm64.exe", @"%LOCALAPPDATA%\JetBrains\Toolbox\apps\WebStorm\*\*\bin\webstorm64.exe" },
            new[] { "webstorm64", "webstorm" }),
        new("pycharm", "PyCharm", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\PyCharm*\bin\pycharm64.exe", @"%ProgramFiles%\JetBrains\PyCharm*\bin\pycharm64.exe", @"%LOCALAPPDATA%\JetBrains\Toolbox\apps\PyCharm-*\*\*\bin\pycharm64.exe" },
            new[] { "pycharm64", "pycharm" }),
        new("rider", "Rider", ExternalAppKind.Editor,
            new[] { @"%LOCALAPPDATA%\Programs\Rider*\bin\rider64.exe", @"%ProgramFiles%\JetBrains\JetBrains Rider*\bin\rider64.exe", @"%LOCALAPPDATA%\JetBrains\Toolbox\apps\Rider\*\*\bin\rider64.exe" },
            new[] { "rider64", "rider" }),
        new("androidstudio", "Android Studio", ExternalAppKind.Editor,
            new[] { @"%ProgramFiles%\Android\Android Studio\bin\studio64.exe", @"%LOCALAPPDATA%\Programs\Android Studio\bin\studio64.exe", @"%LOCALAPPDATA%\JetBrains\Toolbox\apps\AndroidStudio\*\*\bin\studio64.exe" },
            new[] { "studio64" }),
        new("visualstudio", "Visual Studio", ExternalAppKind.Editor,
            new[] { @"%ProgramFiles%\Microsoft Visual Studio\*\*\Common7\IDE\devenv.exe", @"%ProgramFiles(x86)%\Microsoft Visual Studio\*\*\Common7\IDE\devenv.exe" },
            new[] { "devenv" }),
        new("wt", "Windows Terminal", ExternalAppKind.Terminal,
            new[] { @"%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" },
            new[] { "wt" }),
        new("pwsh", "PowerShell", ExternalAppKind.Terminal,
            new[] { @"%ProgramFiles%\PowerShell\7\pwsh.exe", @"%ProgramFiles%\PowerShell\7-preview\pwsh.exe", @"%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" },
            new[] { "pwsh" }),
        new("powershell", "Windows PowerShell", ExternalAppKind.Terminal,
            new[] { @"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" },
            new[] { "powershell" }),
        new("cmd", "Command Prompt", ExternalAppKind.Terminal,
            new[] { @"%SystemRoot%\System32\cmd.exe" },
            new[] { "cmd" }),
        new(ExplorerId, "File Explorer", ExternalAppKind.Explorer,
            new[] { @"%SystemRoot%\explorer.exe" },
            Array.Empty<string>())
    };

    public static List<ExternalApp> Detect(IAppProbe probe)
    {
        var found = new List<ExternalApp>();
        foreach (var c in Known)
        {
            string? path = null;
            foreach (var p in c.Paths)
            {
                path = Resolve(probe.Expand(p), probe);
                if (path is not null) break;
            }
            if (path is null)
            {
                foreach (var n in c.PathNames)
                {
                    path = probe.OnPath(n);
                    if (path is not null) break;
                }
            }
            if (path is null && c.Kind == ExternalAppKind.Explorer) path = "explorer.exe";
            if (path is null) continue;
            found.Add(new ExternalApp(c.Id, c.Name, c.Kind, path));
        }
        if (found.Any(a => a.Id == "pwsh")) found.RemoveAll(a => a.Id == "powershell");
        return found;
    }

    public static string? Resolve(string pattern, IAppProbe probe)
    {
        if (pattern.Contains('%')) return null;
        if (!pattern.Contains('*')) return probe.FileExists(pattern) ? pattern : null;
        var parts = pattern.Split('\\');
        var star = Array.FindIndex(parts, p => p.Contains('*'));
        if (star <= 0) return null;
        var parent = string.Join('\\', parts[..star]);
        var rest = string.Join('\\', parts[(star + 1)..]);
        var matches = probe.Directories(parent, parts[star]).OrderByDescending(d => d, NaturalComparer.Instance);
        foreach (var dir in matches)
        {
            var candidate = rest.Length == 0 ? dir : dir.TrimEnd('\\') + "\\" + rest;
            if (Resolve(candidate, probe) is { } hit) return hit;
        }
        return null;
    }

    public static ExternalApp? Primary(IReadOnlyList<ExternalApp> apps, string? preferred) =>
        apps.FirstOrDefault(a => a.Id == preferred) ?? apps.FirstOrDefault(a => a.Kind == ExternalAppKind.Editor) ?? apps.FirstOrDefault();

    public static LaunchSpec Launch(ExternalApp app, string folder) => app.Id switch
    {
        ExplorerId => new LaunchSpec(app.Path, new[] { folder }, null, false),
        "wt" => new LaunchSpec(app.Path, new[] { "-d", folder }, folder, false),
        "pwsh" or "powershell" => new LaunchSpec(app.Path, new[] { "-NoExit" }, folder, true),
        "cmd" => new LaunchSpec(app.Path, new[] { "/K" }, folder, true),
        _ => new LaunchSpec(app.Path, new[] { folder }, folder, false)
    };

    private sealed class NaturalComparer : IComparer<string>
    {
        public static readonly NaturalComparer Instance = new();

        public int Compare(string? x, string? y)
        {
            var a = x ?? "";
            var b = y ?? "";
            int i = 0, j = 0;
            while (i < a.Length && j < b.Length)
            {
                if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
                {
                    var si = i;
                    var sj = j;
                    while (i < a.Length && char.IsDigit(a[i])) i++;
                    while (j < b.Length && char.IsDigit(b[j])) j++;
                    var na = a[si..i].TrimStart('0');
                    var nb = b[sj..j].TrimStart('0');
                    if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                    var c = string.CompareOrdinal(na, nb);
                    if (c != 0) return c;
                    continue;
                }
                var d = char.ToLowerInvariant(a[i]).CompareTo(char.ToLowerInvariant(b[j]));
                if (d != 0) return d;
                i++;
                j++;
            }
            return (a.Length - i).CompareTo(b.Length - j);
        }
    }
}
