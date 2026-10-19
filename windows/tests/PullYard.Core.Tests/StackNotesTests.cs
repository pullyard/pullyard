using PullYard.Core.Api;
using PullYard.Core.Stacks;
using Xunit;

namespace PullYard.Core.Tests;

public class StackNotesTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "pullyard-notes-" + Guid.NewGuid().ToString("N"));

    private string File => Path.Combine(dir, "stack-notes.json");

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    private static StackNote Note(string text, StackNoteKind kind = StackNoteKind.Note) => new(Guid.NewGuid(), kind, text, DateTimeOffset.FromUnixTimeSeconds(1));

    [Fact]
    public async Task NotesSurviveReload()
    {
        var store = new StackNotes(File);
        var key = StackNotes.Key("me", "github.com", new RepoRef("Acme", "App"), 7);
        store.Replace(key, new[] { Note("Merge API first", StackNoteKind.Decision) });
        await store.Flush();
        var reloaded = new StackNotes(File);
        Assert.Equal(new[] { "Merge API first" }, reloaded.Notes(key).Select(n => n.Text));
        Assert.Equal(StackNoteKind.Decision, reloaded.Notes(key)[0].Kind);
        Assert.True(reloaded.HasNotes(key));
    }

    [Fact]
    public void EmptyDraftsAreNotStored()
    {
        var store = new StackNotes(File);
        store.Replace("k", new[] { StackNote.Blank(), Note("  \n") });
        Assert.Empty(store.Notes("k"));
        Assert.False(store.HasNotes("k"));
        Assert.Equal(0, store.Count("k"));
    }

    [Fact]
    public void KeySeparatesAccounts()
    {
        Assert.NotEqual(StackNotes.Key("alice", "github.com", new RepoRef("acme", "app"), 1), StackNotes.Key("bob", "github.com", new RepoRef("acme", "app"), 1));
    }

    [Fact]
    public void KeyIgnoresRepoCase()
    {
        Assert.Equal(StackNotes.Key("me", "github.com", new RepoRef("Acme", "App"), 1), StackNotes.Key("me", "github.com", new RepoRef("acme", "app"), 1));
        Assert.Equal("me|github.com|acme/app#1", StackNotes.Key("Me", "github.com", new RepoRef("Acme", "App"), 1));
    }

    [Fact]
    public void ReplaceKeepsUnchangedTimestampAndDropsRemoved()
    {
        var store = new StackNotes(File);
        store.Replace("k", new[] { Note("one"), Note("two") });
        var stamped = store.Notes("k")[0].Updated;
        var edited = store.Notes("k")[1] with { Text = "two!" };
        store.Replace("k", new[] { store.Notes("k")[0], edited });
        Assert.Equal(stamped, store.Notes("k")[0].Updated);
        Assert.Equal("two!", store.Notes("k")[1].Text);
        store.Replace("k", new[] { store.Notes("k")[1] });
        Assert.Equal(new[] { "two!" }, store.Notes("k").Select(n => n.Text));
    }

    [Fact]
    public void ChangedFiresOnlyOnRealChange()
    {
        var store = new StackNotes(File);
        var fired = new List<string>();
        store.Changed += fired.Add;
        var n = Note("x");
        store.Replace("k", new[] { n });
        store.Replace("k", store.Notes("k"));
        Assert.Equal(new[] { "k" }, fired);
    }
}
