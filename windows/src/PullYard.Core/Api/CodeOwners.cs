using System.Text;
using System.Text.RegularExpressions;

namespace PullYard.Core.Api;

public sealed record CodeOwnersRule(string Pattern, List<string> Owners, int Line, Regex Regex, int Section = 0);

public enum CodeOwnersFlavor { GitHub, GitLab }

public sealed class CodeOwners
{
    public static readonly string[] Paths = { ".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS" };
    public static readonly string[] GitLabPaths = { "CODEOWNERS", "docs/CODEOWNERS", ".gitlab/CODEOWNERS" };
    public static readonly string[] BitbucketPaths = { ".bitbucket/CODEOWNERS", "CODEOWNERS" };

    public string Path { get; }
    public CodeOwnersFlavor Flavor { get; }
    public List<CodeOwnersRule> Rules { get; } = new();
    public List<int> InvalidLines { get; } = new();

    public CodeOwners(string text, string path = ".github/CODEOWNERS", CodeOwnersFlavor flavor = CodeOwnersFlavor.GitHub)
    {
        Path = path;
        Flavor = flavor;
        var section = 0;
        var defaults = new List<string>();
        var lines = text.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);
        for (var index = 0; index < lines.Length; index++)
        {
            if (flavor == CodeOwnersFlavor.GitLab && SectionHeader(lines[index]) is { } header)
            {
                section++;
                defaults = header;
                continue;
            }
            var tokens = Tokens(lines[index]);
            if (tokens.Count == 0) continue;
            var pattern = tokens[0];
            var owners = tokens.Skip(1).ToList();
            if (!owners.All(IsOwner) || RegexFor(pattern) is not { } regex)
            {
                InvalidLines.Add(index + 1);
                continue;
            }
            if (owners.Count == 0 && flavor == CodeOwnersFlavor.GitLab) owners = defaults;
            Rules.Add(new CodeOwnersRule(pattern, owners, index + 1, regex, section));
        }
    }

    public static List<string>? SectionHeader(string line)
    {
        var s = line.Trim(' ', '\t');
        if (s.StartsWith('^')) s = s[1..];
        if (!s.StartsWith('[')) return null;
        var close = s.IndexOf(']');
        if (close < 2) return null;
        var rest = s[(close + 1)..];
        if (rest.StartsWith('[') && rest.IndexOf(']') is var count and >= 0) rest = rest[(count + 1)..];
        var owners = Tokens(rest);
        return owners.All(IsOwner) ? owners : null;
    }

    public CodeOwnersRule? RuleFor(string file) => Rules.LastOrDefault(r => r.Regex.IsMatch(file));

    public List<string> OwnersFor(string file)
    {
        if (Flavor != CodeOwnersFlavor.GitLab) return RuleFor(file)?.Owners ?? new();
        var lastBySection = new SortedDictionary<int, CodeOwnersRule>();
        foreach (var r in Rules.Where(r => r.Regex.IsMatch(file))) lastBySection[r.Section] = r;
        var seen = new HashSet<string>();
        return lastBySection.Values.SelectMany(r => r.Owners).Where(o => seen.Add(o.ToLowerInvariant())).ToList();
    }

    public static bool IsOwner(string token) =>
        token.StartsWith('@') ? token.Length > 1 : token.Contains('@');

    private static List<string> Tokens(string line)
    {
        var output = new List<string>();
        var current = new StringBuilder();
        var escaped = false;
        foreach (var ch in line)
        {
            if (escaped)
            {
                current.Append(ch);
                escaped = false;
            }
            else if (ch == '\\') escaped = true;
            else if (ch == '#') break;
            else if (ch is ' ' or '\t')
            {
                if (current.Length > 0) output.Add(current.ToString());
                current.Clear();
            }
            else current.Append(ch);
        }
        if (current.Length > 0) output.Add(current.ToString());
        return output;
    }

    public static Regex? RegexFor(string pattern)
    {
        var p = pattern;
        if (p.StartsWith('!') || p.Contains('[') || p.Contains(']')) return null;
        var dirOnly = p.EndsWith('/');
        if (dirOnly) p = p[..^1];
        var anchored = p.Contains('/');
        if (p.StartsWith('/')) p = p[1..];
        if (p.Length == 0) return null;
        var last = p.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? p;
        var wildcardTail = last.Contains('*') || last.Contains('?');
        var body = new StringBuilder();
        var i = 0;
        while (i < p.Length)
        {
            var c = p[i];
            if (c == '*')
            {
                if (i + 1 < p.Length && p[i + 1] == '*')
                {
                    if (i + 2 < p.Length && p[i + 2] == '/')
                    {
                        body.Append("(?:.*/)?");
                        i += 3;
                    }
                    else
                    {
                        body.Append(".*");
                        i += 2;
                    }
                    continue;
                }
                body.Append("[^/]*");
            }
            else if (c == '?') body.Append("[^/]");
            else body.Append(Regex.Escape(c.ToString()));
            i++;
        }
        var prefix = anchored ? "^" : "^(?:.*/)?";
        var suffix = dirOnly ? "/.*$" : wildcardTail ? "$" : "(?:/.*)?$";
        try
        {
            return new Regex(prefix + body + suffix, RegexOptions.CultureInvariant);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }
}

public enum CodeOwnersPhase { Loading, Missing, Failed, Loaded }

public sealed record CodeOwnersStatus(CodeOwnersPhase Phase, CodeOwners? Owners = null)
{
    public static readonly CodeOwnersStatus Loading = new(CodeOwnersPhase.Loading);
    public static readonly CodeOwnersStatus Missing = new(CodeOwnersPhase.Missing);
    public static readonly CodeOwnersStatus Failed = new(CodeOwnersPhase.Failed);
    public static CodeOwnersStatus Loaded(CodeOwners owners) => new(CodeOwnersPhase.Loaded, owners);
}

public enum OwnerStatus { ChangesRequested, NotRequested, Requested, Approved }

public sealed record OwnerEntry(string Handle, bool IsTeam, OwnerStatus Status);

public sealed record OwnerGroup(List<OwnerEntry> Owners, List<string> Files)
{
    public string Id => string.Join(",", Owners.Select(o => o.Handle));
    public bool Satisfied => Owners.Any(o => o.Status == OwnerStatus.Approved);
}

public sealed record OwnershipSummary(List<OwnerGroup> Groups, List<string> Unowned, string SourcePath)
{
    public static OwnershipSummary Build(CodeOwners owners, IEnumerable<string> files, PullRequestDetail pr)
    {
        var approved = pr.LatestOpinionatedReviews.Items.Where(r => r.State == "APPROVED" && r.Author is not null).Select(r => r.Author!.Login.ToLowerInvariant()).ToHashSet();
        var blocked = pr.LatestOpinionatedReviews.Items.Where(r => r.State == "CHANGES_REQUESTED" && r.Author is not null).Select(r => r.Author!.Login.ToLowerInvariant()).ToHashSet();
        var requested = pr.ReviewRequests.Items.Where(r => r.RequestedReviewer is not null).Select(r => r.RequestedReviewer!.Display.ToLowerInvariant()).ToHashSet();
        var byOwners = new Dictionary<string, (List<string> Owners, List<string> Files)>();
        var order = new List<string>();
        var unowned = new List<string>();
        foreach (var file in files)
        {
            var list = owners.OwnersFor(file);
            if (list.Count == 0)
            {
                unowned.Add(file);
                continue;
            }
            var key = string.Join(" ", list);
            if (!byOwners.TryGetValue(key, out var entry))
            {
                entry = (list, new List<string>());
                byOwners[key] = entry;
                order.Add(key);
            }
            entry.Files.Add(file);
        }
        var groups = order.Select(key =>
        {
            var (list, groupFiles) = byOwners[key];
            var entries = list.Select(raw =>
            {
                var handle = raw.StartsWith('@') ? raw[1..] : raw;
                var lower = handle.ToLowerInvariant();
                var status = blocked.Contains(lower) ? OwnerStatus.ChangesRequested
                    : approved.Contains(lower) ? OwnerStatus.Approved
                    : requested.Contains(lower) ? OwnerStatus.Requested
                    : OwnerStatus.NotRequested;
                return new OwnerEntry(handle, handle.Contains('/'), status);
            }).ToList();
            return new OwnerGroup(entries, groupFiles);
        }).ToList();
        return new OwnershipSummary(groups, unowned, owners.Path);
    }

    public List<OwnerEntry>? OwnersOf(string file) => Groups.FirstOrDefault(g => g.Files.Contains(file))?.Owners;

    public List<OwnerEntry> Suggestions(ISet<string> excluding)
    {
        var seen = new HashSet<string>();
        return Groups.Where(g => !g.Satisfied).SelectMany(g => g.Owners)
            .Where(o => o.Status == OwnerStatus.NotRequested && !o.Handle.Contains('@') && !excluding.Contains(o.Handle.ToLowerInvariant()) && seen.Add(o.Handle.ToLowerInvariant()))
            .ToList();
    }
}
