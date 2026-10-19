using System.Text.Json;
using PullYard.Core.Api;
using PullYard.Core.Util;

namespace PullYard.Core.Stacks;

public enum StackNoteKind { Note, Question, Decision }

public sealed record StackNote(Guid Id, StackNoteKind Kind, string Text, DateTimeOffset Updated)
{
    public static StackNote Blank() => new(Guid.NewGuid(), StackNoteKind.Note, "", DateTimeOffset.Now);

    public bool IsEmpty => Text.Trim().Length == 0;
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
    public static StackNotes Shared { get; } = new(Path.Combine(AppInfo.DataDirectory, "stack-notes.json"));

    private static readonly JsonSerializerOptions Options = new(Json.Plain) { IgnoreReadOnlyProperties = true };

    private readonly string file;
    private readonly object gate = new();
    private Dictionary<string, List<StackNote>> byPR = new();
    private CancellationTokenSource? pendingSave;
    private Task lastWrite = Task.CompletedTask;

    public event Action<string>? Changed;

    public StackNotes(string file)
    {
        this.file = file;
        try
        {
            if (File.Exists(file) && JsonSerializer.Deserialize<Dictionary<string, List<StackNote>>>(File.ReadAllBytes(file), Options) is { } decoded)
                byPR = decoded.Where(kv => kv.Value.Count > 0).ToDictionary(kv => kv.Key, kv => kv.Value);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            ErrorLog.Write(e, "stack notes load failed");
        }
    }

    public static string Key(string? account, string host, RepoRef repo, int number) =>
        $"{account?.ToLowerInvariant() ?? ""}|{host}|{repo.Full.ToLowerInvariant()}#{number}";

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

    private void Write(Dictionary<string, List<StackNote>> value)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = $"{file}.{Guid.NewGuid():N}.tmp";
            File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(value, Options));
            File.Move(tmp, file, true);
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "stack notes save failed");
        }
    }
}
