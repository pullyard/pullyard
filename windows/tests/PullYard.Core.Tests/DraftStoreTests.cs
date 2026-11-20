using PullYard.Core.Drafts;
using Xunit;

namespace PullYard.Core.Tests;

public class DraftStoreTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), $"drafts-{Guid.NewGuid()}");

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    [Fact]
    public void ReviewDraftRoundTripsAndEmptyDraftRemovesFile()
    {
        var key = DraftStore.Key("me", "github.com", "acme/app", 7);
        var store = new DraftStore(dir);
        var draft = new SavedReviewDraft
        {
            Pending = { new DraftComment("a/b.cs", 12, "RIGHT", "Rename this") },
            Composer = new DraftComment("a/b.cs", 20, "LEFT", "half typed"),
            Replies = { ["T1"] = "agreed" },
            Summary = "Looks good overall"
        };
        store.Save(draft, key);
        Assert.True(draft.SameAs(new DraftStore(dir).Review(key)));
        Assert.Null(new DraftStore(dir).Review(DraftStore.Key("me", "github.com", "acme/app", 8)));
        store.Save(new SavedReviewDraft { Replies = { ["T1"] = "  " }, Comment = "\n" }, key);
        Assert.Null(new DraftStore(dir).Review(key));
        Assert.Empty(Directory.GetFiles(dir));
    }

    [Fact]
    public void TextDrafts()
    {
        var key = DraftStore.Key(null, "github.com", "acme/app", 3, "issue");
        var store = new DraftStore(dir);
        Assert.Equal("", store.Text(key));
        store.SetText("Repro steps", key);
        Assert.Equal("Repro steps", new DraftStore(dir).Text(key));
        store.SetText("  ", key);
        Assert.Equal("", new DraftStore(dir).Text(key));
    }

    [Fact]
    public void KeysSeparateAccountHostKindAndNumber()
    {
        var keys = new[]
        {
            DraftStore.Key("me", "github.com", "acme/app", 7),
            DraftStore.Key("you", "github.com", "acme/app", 7),
            DraftStore.Key("me", "ghe.acme.dev", "acme/app", 7),
            DraftStore.Key("me", "github.com", "acme/app", 7, "issue"),
            DraftStore.Key("me", "github.com", "acme/app", 8),
            DraftStore.Key(null, "github.com", "acme/app", 7)
        };
        Assert.Equal(keys.Length, keys.Distinct().Count());
    }

    [Fact]
    public void MemoryStoreWorksWithoutDirectoryAndIgnoresCorruptFiles()
    {
        var memory = new DraftStore(null);
        var key = DraftStore.Key("me", "github.com", "acme/app", 1);
        memory.Save(new SavedReviewDraft { Comment = "hello" }, key);
        Assert.Equal("hello", memory.Review(key)?.Comment);
        memory.Save(new SavedReviewDraft(), key);
        Assert.Null(memory.Review(key));
        var disk = new DraftStore(dir);
        disk.SetText("{not json", key);
        Assert.Null(disk.Review(key));
    }

    [Fact]
    public void IsEmptyIgnoresWhitespace()
    {
        Assert.True(new SavedReviewDraft().IsEmpty);
        Assert.True(new SavedReviewDraft { Composer = new DraftComment("a", 1, "RIGHT", " "), Summary = "\t" }.IsEmpty);
        Assert.False(new SavedReviewDraft { Composer = new DraftComment("a", 1, "RIGHT", "x") }.IsEmpty);
        Assert.False(new SavedReviewDraft { Replies = { ["T"] = "x" } }.IsEmpty);
    }
}
