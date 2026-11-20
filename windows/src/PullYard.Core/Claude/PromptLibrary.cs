using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public sealed record SavedPrompt(Guid Id, string Title, string Text);

public sealed class PromptLibrary
{
    private static PromptLibrary? shared;

    public static PromptLibrary Shared => shared ??= new PromptLibrary(Settings.Shared);

    private readonly Settings store;
    private readonly List<SavedPrompt> prompts;

    public event Action? Changed;

    public PromptLibrary(Settings store)
    {
        this.store = store;
        prompts = store.GetObject<List<SavedPrompt>>(Keys.AgentsSavedPrompts)?.Where(p => p is not null && !string.IsNullOrEmpty(p.Text)).ToList() ?? new();
    }

    public IReadOnlyList<SavedPrompt> Prompts => prompts.ToList();

    public static string TitleFor(string text)
    {
        var line = text.Trim().Split('\n')[0].TrimEnd('\r');
        return line.Length > 48 ? line[..47] + "…" : line;
    }

    public SavedPrompt? Add(string raw, string? title = null)
    {
        var text = raw.Trim();
        if (text.Length == 0) return null;
        if (prompts.FirstOrDefault(p => p.Text == text) is { } existing) return existing;
        var name = title?.Trim() ?? "";
        var prompt = new SavedPrompt(Guid.NewGuid(), name.Length == 0 ? TitleFor(text) : name, text);
        prompts.Add(prompt);
        Save();
        return prompt;
    }

    public void Update(SavedPrompt prompt)
    {
        var i = prompts.FindIndex(p => p.Id == prompt.Id);
        if (i < 0) return;
        prompts[i] = prompt;
        Save();
    }

    public void Remove(Guid id)
    {
        if (prompts.RemoveAll(p => p.Id == id) == 0) return;
        Save();
    }

    private void Save()
    {
        store.Set(Keys.AgentsSavedPrompts, prompts.ToList());
        Changed?.Invoke();
    }
}
