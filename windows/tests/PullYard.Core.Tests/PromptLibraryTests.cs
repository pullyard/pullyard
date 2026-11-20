using PullYard.Core.Claude;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class PromptLibraryTests
{
    private static string TempFile() => Path.Combine(Path.GetTempPath(), $"prompts-{Guid.NewGuid()}.json");

    [Fact]
    public void AddDeduplicatesAndPersists()
    {
        var file = TempFile();
        try
        {
            var lib = new PromptLibrary(new Settings(file));
            Assert.Null(lib.Add("   "));
            var first = lib.Add("  Review my changes\nand list risks  ");
            Assert.Equal("Review my changes", first?.Title);
            Assert.Equal(first?.Id, lib.Add("Review my changes\nand list risks")?.Id);
            Assert.Single(lib.Prompts);
            Assert.Equal(lib.Prompts, new PromptLibrary(new Settings(file)).Prompts);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void UpdateAndRemove()
    {
        var file = TempFile();
        try
        {
            var lib = new PromptLibrary(new Settings(file));
            var changes = 0;
            lib.Changed += () => changes++;
            var prompt = lib.Add("one", "First");
            Assert.NotNull(prompt);
            Assert.Equal("First", prompt!.Title);
            lib.Update(prompt with { Text = "two" });
            Assert.Equal("two", lib.Prompts[0].Text);
            lib.Remove(prompt.Id);
            Assert.Equal(3, changes);
            Assert.Empty(new PromptLibrary(new Settings(file)).Prompts);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void LongTitleIsShortened()
    {
        Assert.Equal(48, PromptLibrary.TitleFor(new string('a', 80)).Length);
    }
}
