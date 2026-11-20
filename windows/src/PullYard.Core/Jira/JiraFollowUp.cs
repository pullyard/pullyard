using PullYard.Core.Util;

namespace PullYard.Core.Jira;

public static class JiraFollowUp
{
    public const string DismissedKey = "jira.mergeFollowUpDismissed";
    private const int DismissedLimit = 500;
    private static readonly string[] PreferredTargets = { "done", "closed", "resolved", "complete", "completed" };

    public static List<JiraIssue> Open(IEnumerable<JiraIssue> issues) =>
        issues.Where(i => !string.Equals(i.StatusCategory, "done", StringComparison.OrdinalIgnoreCase)).ToList();

    public static JiraTransition? DoneTransition(IEnumerable<JiraTransition> transitions)
    {
        var done = transitions.Where(t => string.Equals(t.ToCategory, "done", StringComparison.OrdinalIgnoreCase)).ToList();
        return done.FirstOrDefault(t => PreferredTargets.Contains(t.To.ToLowerInvariant())) ?? done.FirstOrDefault();
    }

    public static bool IsDismissed(Settings settings, string prUrl) =>
        (settings.GetObject<List<string>>(DismissedKey) ?? new List<string>()).Contains(prUrl);

    public static void Dismiss(Settings settings, string prUrl)
    {
        var list = settings.GetObject<List<string>>(DismissedKey) ?? new List<string>();
        if (list.Contains(prUrl)) return;
        list.Add(prUrl);
        settings.Set(DismissedKey, list.Skip(Math.Max(0, list.Count - DismissedLimit)).ToList());
    }

    public static string? ShipStep(string branch)
    {
        var keys = JiraKeys.ExtractBranch(branch);
        if (keys.Count == 0) return null;
        var list = string.Join(", ", keys);
        return $"The branch refers to Jira issue{(keys.Count == 1 ? "" : "s")} {list}. Start the title with {keys[0]} and mention {list} in the description.";
    }
}
