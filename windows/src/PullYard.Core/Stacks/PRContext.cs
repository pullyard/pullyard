using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using PullYard.Core.Api;
using PullYard.Core.Util;

namespace PullYard.Core.Stacks;

public sealed record PRContextRequirement(string State, string Title, string? Detail);

public sealed record PRContextCheck(string Name, string Outcome, bool? Required, string? Url);

public sealed record PRContextReview(string Login, string State);

public sealed record PRContextComment(string Author, string Body);

public sealed record PRContextThread(string Path, int? Line, bool Resolved, bool Outdated, List<PRContextComment> Comments);

public sealed record PRContextOwnerGroup(List<string> Owners, List<string> Files);

public sealed record PRContextSnapshot
{
    public string Repo { get; init; } = "";
    public int Number { get; init; }
    public string Title { get; init; } = "";
    public string Url { get; init; } = "";
    public string State { get; init; } = "";
    public bool IsDraft { get; init; }
    public string? Author { get; init; }
    public string BaseRef { get; init; } = "";
    public string HeadRef { get; init; } = "";
    public string HeadOid { get; init; } = "";
    public string Body { get; init; } = "";
    public string MergeStatus { get; init; } = "";
    public List<PRContextRequirement> Requirements { get; init; } = new();
    public List<PRContextCheck> Checks { get; init; } = new();
    public List<PRContextReview> Reviews { get; init; } = new();
    public List<PRContextThread> Threads { get; init; } = new();
    public List<string> Files { get; init; } = new();
    public List<PRContextOwnerGroup>? CodeOwners { get; init; }
    public List<string>? UnownedFiles { get; init; }
    public string? ReviewedOid { get; init; }
    public int? CommitsSinceReview { get; init; }
    public DateTimeOffset Captured { get; init; } = DateTimeOffset.UtcNow;
}

public static class PRContextStore
{
    public const int MaxFiles = 200;
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);
    public const string DirectoryName = "pr-context";

    private static readonly JsonSerializerOptions Options = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var o = new JsonSerializerOptions(Json.Plain);
        o.Converters.Add(new Iso8601Converter());
        return o;
    }

    public static string DefaultDirectory => Path.Combine(AppInfo.DataDirectory, DirectoryName);

    public static string DirectoryFor(string notesFile) => Path.Combine(Path.GetDirectoryName(notesFile) ?? ".", DirectoryName);

    public static string FileName(string key) =>
        new string(key.Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_').ToArray()) + ".json";

    public static string Serialize(PRContextSnapshot snapshot) => JsonSerializer.Serialize(snapshot, Options);

    public static PRContextSnapshot? Deserialize(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<PRContextSnapshot>(json, Options);
        }
        catch (Exception e) when (e is JsonException or NotSupportedException or FormatException)
        {
            return null;
        }
    }

    public static void Write(PRContextSnapshot snapshot, string key, string? directory = null)
    {
        var dir = directory ?? DefaultDirectory;
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(dir);
        else Directory.CreateDirectory(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var path = Path.Combine(dir, FileName(key));
        var tmp = $"{path}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(tmp, Serialize(snapshot));
        File.Move(tmp, path, true);
        Prune(dir);
    }

    public static PRContextSnapshot? Read(string key, string? directory = null)
    {
        try
        {
            var path = Path.Combine(directory ?? DefaultDirectory, FileName(key));
            return File.Exists(path) ? Deserialize(File.ReadAllText(path)) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static void Prune(string? directory = null, DateTimeOffset? now = null)
    {
        var dir = directory ?? DefaultDirectory;
        var at = (now ?? DateTimeOffset.Now).UtcDateTime;
        string[] files;
        try
        {
            if (!Directory.Exists(dir)) return;
            files = Directory.GetFiles(dir, "*.json");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
        var dated = files.Select(f =>
        {
            try
            {
                return (Path: f, Modified: File.GetLastWriteTimeUtc(f));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return (Path: f, Modified: DateTime.MinValue);
            }
        }).OrderByDescending(e => e.Modified).ToList();
        for (var i = 0; i < dated.Count; i++)
        {
            if (i < MaxFiles && at - dated[i].Modified <= MaxAge) continue;
            try
            {
                File.Delete(dated[i].Path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    public static string FormatDate(DateTimeOffset date) => date.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private sealed class Iso8601Converter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTimeOffset.Parse(reader.GetString() ?? "", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteStringValue(FormatDate(value));
    }
}

public static class PRContextFormatter
{
    public const int BodyLimit = 6000;
    public const int ListLimit = 300;

    public static string Overview(PRContextSnapshot s)
    {
        var output = new List<string>
        {
            $"{s.Repo}#{s.Number}: {s.Title}",
            $"State: {(s.IsDraft ? "draft, " : "")}{s.State.ToLowerInvariant()} · {s.HeadRef} → {s.BaseRef} · head {Prefix(s.HeadOid, 7)}{(s.Author is { } a ? $" · by @{a}" : "")}",
            $"URL: {s.Url}",
            $"Loaded by PullYard: {PRContextStore.FormatDate(s.Captured)}",
            "",
            $"Merge status: {s.MergeStatus}"
        };
        foreach (var r in s.Requirements)
            output.Add($"- [{r.State}] {r.Title}{(r.Detail is { } d ? $" — {d}" : "")}");
        if (s.Reviews.Count > 0)
        {
            output.Add("");
            output.Add("Reviewers: " + string.Join(", ", s.Reviews.Select(r => $"@{r.Login} ({r.State.ToLowerInvariant().Replace("_", " ")})")));
        }
        if (s.CodeOwners is { } groups)
        {
            output.Add("");
            output.Add("Code owners: " + (groups.Count == 0 ? "none of the changed files have owners" : string.Join("; ", groups.Select(g => $"{string.Join(" ", g.Owners)} ({g.Files.Count} files)"))));
            if (s.UnownedFiles is { Count: > 0 } unowned) output.Add($"Files without a code owner: {unowned.Count}");
        }
        if (s.ReviewedOid is { } oid)
        {
            output.Add("");
            output.Add($"The user last reviewed commit {Prefix(oid, 7)}" + (s.CommitsSinceReview is { } n ? $", {n} commit(s) ago." : "; the branch history was rewritten since."));
        }
        var open = s.Threads.Count(t => !t.Resolved);
        var failing = s.Checks.Count(c => c.Outcome == "failure");
        output.Add("");
        output.Add($"{open} unresolved review thread(s), {failing} failing check(s), {s.Files.Count} changed file(s).");
        var body = s.Body.Trim();
        if (body.Length > 0)
        {
            output.Add("");
            output.Add("Description:");
            output.Add(body.Length > BodyLimit ? body[..BodyLimit] + "\n…(truncated)" : body);
        }
        return string.Join("\n", output);
    }

    public static string Threads(PRContextSnapshot s, bool includeResolved)
    {
        var list = s.Threads.Where(t => includeResolved || !t.Resolved).ToList();
        if (list.Count == 0) return includeResolved ? $"No review threads on {s.Repo}#{s.Number}." : $"No unresolved review threads on {s.Repo}#{s.Number}.";
        return string.Join("\n\n", list.Select((t, index) =>
        {
            var head = $"{index + 1}. {t.Path}{(t.Line is { } l ? $":{l}" : "")}";
            var flags = new List<string>();
            if (t.Resolved) flags.Add("resolved");
            if (t.Outdated) flags.Add("outdated");
            if (flags.Count > 0) head += $" ({string.Join(", ", flags)})";
            var comments = t.Comments.Select(c => $"   @{c.Author}: {c.Body.Replace("\n", "\n   ")}");
            return string.Join("\n", new[] { head }.Concat(comments));
        }));
    }

    public static string Checks(PRContextSnapshot s)
    {
        if (s.Checks.Count == 0) return $"No checks reported for the head commit of {s.Repo}#{s.Number}.";
        static int Rank(string outcome) => outcome switch
        {
            "failure" => 0,
            "pending" => 1,
            "neutral" => 2,
            "skipped" => 3,
            "success" => 4,
            _ => 5
        };
        var sorted = s.Checks.Select((c, i) => (c, i)).OrderBy(e => Rank(e.c.Outcome)).ThenBy(e => e.i).Select(e => e.c);
        return string.Join("\n", sorted.Select(c =>
        {
            var req = c.Required is { } r ? (r ? " · required" : " · optional") : "";
            return $"- [{c.Outcome}] {c.Name}{req}{(c.Url is { } u ? $" · {u}" : "")}";
        }));
    }

    public static string Files(PRContextSnapshot s)
    {
        if (s.Files.Count == 0) return $"No changed files recorded for {s.Repo}#{s.Number}.";
        var owner = new Dictionary<string, string>();
        foreach (var g in s.CodeOwners ?? new())
            foreach (var f in g.Files) owner[f] = string.Join(" ", g.Owners);
        var lines = s.Files.Take(ListLimit).Select(f => owner.TryGetValue(f, out var o) ? $"{f} — {o}" : f).ToList();
        if (s.Files.Count > ListLimit) lines.Add($"…and {s.Files.Count - ListLimit} more");
        return string.Join("\n", lines);
    }

    private static string Prefix(string value, int length) => value.Length > length ? value[..length] : value;
}

public static class PRContextPublisher
{
    public static PRContextSnapshot Snapshot(ItemRef r, PullRequestDetail pr, IEnumerable<MergeRequirement> requirements, OwnershipSummary? ownership, IEnumerable<string> files, ReviewedCommit? reviewed, string mergeStatus, DateTimeOffset? captured = null)
    {
        var reviews = pr.LatestOpinionatedReviews.Items.Where(v => v.Author is not null).Select(v => new PRContextReview(v.Author!.Login, v.State))
            .Concat(pr.ReviewRequests.Items.Where(q => q.RequestedReviewer is not null).Select(q => new PRContextReview(q.RequestedReviewer!.Display, "REVIEW_REQUESTED")))
            .ToList();
        return new PRContextSnapshot
        {
            Repo = r.Repo.Full,
            Number = pr.Number,
            Title = pr.Title,
            Url = pr.Url,
            State = pr.State,
            IsDraft = pr.IsDraft,
            Author = pr.Author?.Login,
            BaseRef = pr.BaseRefName,
            HeadRef = pr.HeadRefName,
            HeadOid = pr.HeadRefOid,
            Body = pr.Body,
            MergeStatus = mergeStatus,
            Requirements = requirements.Select(q => new PRContextRequirement(Label(q.State), q.Title, q.Detail)).ToList(),
            Checks = pr.Checks.Select(c => new PRContextCheck(c.FullTitle, Outcome(c.Outcome), c.IsRequired, c.Link)).ToList(),
            Reviews = reviews,
            Threads = pr.ReviewThreads.Items.Select(t => new PRContextThread(t.Path, t.Line ?? t.OriginalLine, t.IsResolved, t.IsOutdated,
                t.Comments.Items.Select(c => new PRContextComment(c.Author?.Login ?? "ghost", c.Body)).ToList())).ToList(),
            Files = files.ToList(),
            CodeOwners = ownership?.Groups.Select(g => new PRContextOwnerGroup(g.Owners.Select(o => "@" + o.Handle).ToList(), g.Files.ToList())).ToList(),
            UnownedFiles = ownership?.Unowned.ToList(),
            ReviewedOid = reviewed?.Oid,
            CommitsSinceReview = reviewed?.CommitsSince,
            Captured = captured ?? DateTimeOffset.UtcNow
        };
    }

    public static string Label(RequirementState state) => state switch
    {
        RequirementState.Satisfied => "met",
        RequirementState.Missing => "blocking",
        RequirementState.Pending => "in progress",
        RequirementState.Advisory => "does not block",
        _ => "unknown"
    };

    public static string Outcome(CheckOutcome outcome) => outcome switch
    {
        CheckOutcome.Failure => "failure",
        CheckOutcome.Pending => "pending",
        CheckOutcome.Neutral => "neutral",
        CheckOutcome.Skipped => "skipped",
        _ => "success"
    };
}
