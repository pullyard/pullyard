using System.Text;
using System.Text.Json;
using PullYard.Core.Util;

namespace PullYard.Core.Drafts;

public sealed record DraftComment(string Path, int Line, string Side, string Body);

public sealed class ReviewDraft
{
    public List<DraftComment> Pending { get; set; } = new();
    public DraftComment? Composer { get; set; }
    public Dictionary<string, string> Replies { get; set; } = new();
    public string Comment { get; set; } = "";
    public string Summary { get; set; } = "";

    public bool IsEmpty =>
        Pending.Count == 0
        && string.IsNullOrWhiteSpace(Composer?.Body)
        && Replies.Values.All(string.IsNullOrWhiteSpace)
        && string.IsNullOrWhiteSpace(Comment)
        && string.IsNullOrWhiteSpace(Summary);

    public bool SameAs(ReviewDraft? other) =>
        other is not null
        && Pending.SequenceEqual(other.Pending)
        && Equals(Composer, other.Composer)
        && Replies.Count == other.Replies.Count
        && Replies.All(p => other.Replies.TryGetValue(p.Key, out var v) && v == p.Value)
        && Comment == other.Comment
        && Summary == other.Summary;
}

public sealed class DraftStore
{
    public static DraftStore Shared { get; } = new(Path.Combine(AppInfo.DataDirectory, "drafts"));

    private readonly string? directory;
    private readonly Dictionary<string, byte[]> memory = new();
    private readonly object gate = new();

    public DraftStore(string? directory)
    {
        this.directory = directory;
    }

    public static string Key(string? account, string host, string repo, int number, string kind = "pr") =>
        $"{kind}|{account ?? "-"}|{host}|{repo}#{number}";

    private string? FileFor(string key)
    {
        if (directory is null) return null;
        var name = Convert.ToBase64String(Encoding.UTF8.GetBytes(key)).Replace('/', '_').Replace('+', '-');
        return Path.Combine(directory, name + ".json");
    }

    private byte[]? Read(string key)
    {
        lock (gate)
        {
            if (FileFor(key) is not { } file) return memory.TryGetValue(key, out var held) ? held : null;
            try
            {
                return File.Exists(file) ? File.ReadAllBytes(file) : null;
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "reading draft failed");
                return null;
            }
        }
    }

    private void Write(byte[]? data, string key)
    {
        lock (gate)
        {
            if (FileFor(key) is not { } file)
            {
                if (data is null) memory.Remove(key);
                else memory[key] = data;
                return;
            }
            try
            {
                if (data is null)
                {
                    if (File.Exists(file)) File.Delete(file);
                    return;
                }
                Directory.CreateDirectory(directory!);
                var tmp = file + ".tmp";
                File.WriteAllBytes(tmp, data);
                File.Move(tmp, file, true);
            }
            catch (Exception e)
            {
                ErrorLog.Write(e, "saving draft failed");
            }
        }
    }

    public ReviewDraft? Review(string key)
    {
        if (Read(key) is not { } data) return null;
        try
        {
            return JsonSerializer.Deserialize<ReviewDraft>(data, Json.Plain);
        }
        catch
        {
            return null;
        }
    }

    public void Save(ReviewDraft draft, string key) =>
        Write(draft.IsEmpty ? null : JsonSerializer.SerializeToUtf8Bytes(draft, Json.Plain), key);

    public string Text(string key) => Read(key) is { } data ? Encoding.UTF8.GetString(data) : "";

    public void SetText(string text, string key) =>
        Write(string.IsNullOrWhiteSpace(text) ? null : Encoding.UTF8.GetBytes(text), key);
}
