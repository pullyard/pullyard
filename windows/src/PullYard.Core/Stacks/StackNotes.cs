using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Util;

namespace PullYard.Core.Stacks;

public enum StackNoteKind { Note, Question, Decision }

public sealed record StackNote(Guid Id, StackNoteKind Kind, string Text, DateTimeOffset Updated, string? Source = null)
{
    public static StackNote Blank() => new(Guid.NewGuid(), StackNoteKind.Note, "", DateTimeOffset.Now);

    public bool IsEmpty => string.IsNullOrWhiteSpace(Text);
}

public static class StackNoteKinds
{
    public static string ColorKey(this StackNoteKind k) => k switch
    {
        StackNoteKind.Question => "sky",
        StackNoteKind.Decision => "green",
        _ => "amber"
    };
}

public sealed class StackNotes
{
    public const string AgentSource = "Claude";

    private static readonly Lazy<StackNotes> SharedStore = new(() =>
    {
        var store = new StackNotes(StackNotesFile.DefaultFile);
        store.WatchInbox();
        return store;
    });

    public static StackNotes Shared => SharedStore.Value;

    private static readonly JsonSerializerOptions Options = new(Json.Plain) { IgnoreReadOnlyProperties = true };

    private readonly string file;
    private readonly object gate = new();
    private Dictionary<string, List<StackNote>> byPR = new();
    private CancellationTokenSource? pendingSave;
    private Task lastWrite = Task.CompletedTask;
    private FileSystemWatcher? watcher;
    private CancellationTokenSource? pendingImport;

    public event Action<string>? Changed;

    private sealed class Stored
    {
        public Guid Id { get; set; }
        public string Kind { get; set; } = "note";
        public string Text { get; set; } = "";
        public DateTimeOffset Updated { get; set; }
        public string? Source { get; set; }
    }

    private static StackNote? FromStored(Stored s)
    {
        if (string.IsNullOrWhiteSpace(s.Text)) return null;
        var kind = Enum.TryParse<StackNoteKind>(s.Kind, true, out var k) ? k : StackNoteKind.Note;
        return new StackNote(s.Id == Guid.Empty ? Guid.NewGuid() : s.Id, kind, s.Text, s.Updated, string.IsNullOrEmpty(s.Source) ? null : s.Source);
    }

    private static Stored ToStored(StackNote n) => new() { Id = n.Id, Kind = n.Kind.ToString().ToLowerInvariant(), Text = n.Text ?? "", Updated = n.Updated, Source = n.Source };

    public StackNotes(string file)
    {
        this.file = file;
        try
        {
            if (File.Exists(file) && JsonSerializer.Deserialize<Dictionary<string, List<Stored>>>(File.ReadAllBytes(file), Options) is { } decoded)
            {
                foreach (var (key, list) in decoded)
                {
                    var notes = (list ?? new()).Where(n => n is not null).Select(FromStored).OfType<StackNote>().ToList();
                    if (notes.Count > 0) byPR[key] = notes;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            ErrorLog.Write(e, "stack notes load failed");
        }
    }

    public string InboxDirectory => Path.Combine(Path.GetDirectoryName(file) ?? ".", StackNotesFile.InboxName);

    public static string Key(string? account, string host, RepoRef repo, int number) => StackNotesFile.Key(account, host, repo.Full, number);

    public int ImportInbox()
    {
        var entries = StackNotesInbox.Drain(InboxDirectory);
        if (entries.Count == 0) return 0;
        var keys = new List<string>();
        lock (gate)
        {
            foreach (var e in entries)
            {
                if (string.IsNullOrWhiteSpace(e.Text)) continue;
                if (!byPR.TryGetValue(e.Key, out var list)) byPR[e.Key] = list = new List<StackNote>();
                list.Add(new StackNote(Guid.NewGuid(), e.KindValue, e.Text, e.Created, AgentSource));
                if (!keys.Contains(e.Key)) keys.Add(e.Key);
            }
            if (keys.Count > 0) ScheduleSave();
        }
        foreach (var k in keys) Changed?.Invoke(k);
        return keys.Count;
    }

    public void WatchInbox()
    {
        if (watcher is not null) return;
        try
        {
            Directory.CreateDirectory(InboxDirectory);
            ImportInbox();
            var w = new FileSystemWatcher(InboxDirectory, "*.json") { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
            w.Created += (_, _) => ScheduleImport();
            w.Renamed += (_, _) => ScheduleImport();
            w.Changed += (_, _) => ScheduleImport();
            w.Error += (_, _) => ScheduleImport();
            w.EnableRaisingEvents = true;
            watcher = w;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or PlatformNotSupportedException)
        {
            ErrorLog.Write(e, "stack notes inbox watch failed");
        }
    }

    private void ScheduleImport()
    {
        CancellationTokenSource cts;
        lock (gate)
        {
            pendingImport?.Cancel();
            cts = new CancellationTokenSource();
            pendingImport = cts;
        }
        Task.Run(async () =>
        {
            try
            {
                await Task.Delay(250, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            ImportInbox();
        }).Forget();
    }

    public List<StackNote> Notes(string key)
    {
        lock (gate) return byPR.TryGetValue(key, out var list) ? list.ToList() : new List<StackNote>();
    }

    public int Count(string key)
    {
        lock (gate) return byPR.TryGetValue(key, out var list) ? list.Count : 0;
    }

    public bool HasNotes(string key)
    {
        lock (gate) return byPR.TryGetValue(key, out var list) && list.Any(n => !n.IsEmpty);
    }

    public void Replace(string key, IEnumerable<StackNote> drafts)
    {
        lock (gate)
        {
            var current = byPR.TryGetValue(key, out var existing) ? existing : new List<StackNote>();
            var old = new Dictionary<Guid, StackNote>();
            foreach (var n in current) old.TryAdd(n.Id, n);
            var kept = new List<StackNote>();
            foreach (var d in drafts)
            {
                if (d.IsEmpty) continue;
                if (old.TryGetValue(d.Id, out var o) && o.Text == d.Text && o.Kind == d.Kind) kept.Add(o);
                else kept.Add(d with { Updated = DateTimeOffset.Now });
            }
            if (kept.SequenceEqual(current)) return;
            if (kept.Count == 0) byPR.Remove(key);
            else byPR[key] = kept;
            ScheduleSave();
        }
        Changed?.Invoke(key);
    }

    public Task Flush()
    {
        Dictionary<string, List<StackNote>> snapshot;
        lock (gate)
        {
            pendingSave?.Cancel();
            pendingSave = null;
            snapshot = byPR.Where(kv => kv.Value.Count > 0).ToDictionary(kv => kv.Key, kv => kv.Value.ToList());
            var previous = lastWrite;
            lastWrite = Task.Run(async () =>
            {
                await previous.ConfigureAwait(false);
                Write(snapshot);
            });
            return lastWrite;
        }
    }

    private void ScheduleSave()
    {
        pendingSave?.Cancel();
        var cts = new CancellationTokenSource();
        pendingSave = cts;
        Task.Run(async () =>
        {
            try
            {
                await Task.Delay(400, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            await Flush().ConfigureAwait(false);
        }).Forget();
    }

    private void Write(Dictionary<string, List<StackNote>> notes)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = $"{file}.{Guid.NewGuid():N}.tmp";
            var value = notes.ToDictionary(kv => kv.Key, kv => kv.Value.Select(ToStored).ToList());
            File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(value, Options));
            File.Move(tmp, file, true);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "stack notes save failed");
        }
    }
}
