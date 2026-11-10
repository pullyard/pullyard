using PullYard.Core.Claude;
using PullYard.Core.Jira;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class JiraFollowUpTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "pullyard-jira-followup-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    private static JiraIssue Issue(string key, string status, string category) =>
        new(key, "s", status, category, null, null, null, null, null, "", $"https://x.atlassian.net/browse/{key}", null);

    [Fact]
    public void OpenIssuesAndDoneTransition()
    {
        var issues = new[] { Issue("AB-1", "In Review", "indeterminate"), Issue("AB-2", "Done", "done"), Issue("AB-3", "To Do", "new"), Issue("AB-4", "Closed", "DONE") };
        Assert.Equal(new[] { "AB-1", "AB-3" }, JiraFollowUp.Open(issues).Select(i => i.Key));
        var transitions = new[]
        {
            new JiraTransition("1", "Back to progress", "In Progress", "indeterminate"),
            new JiraTransition("2", "Ship it", "Released", "done"),
            new JiraTransition("3", "Finish", "Done", "done")
        };
        Assert.Equal("3", JiraFollowUp.DoneTransition(transitions)?.Id);
        Assert.Equal("2", JiraFollowUp.DoneTransition(transitions.Take(2))?.Id);
        Assert.Null(JiraFollowUp.DoneTransition(new[] { transitions[0] }));
        Assert.Null(JiraFollowUp.DoneTransition(Array.Empty<JiraTransition>()));
        Assert.Equal("5", JiraFollowUp.DoneTransition(new[] { transitions[1], new JiraTransition("5", "Resolve", "RESOLVED", "Done") })?.Id);
    }

    [Fact]
    public void DismissIsRememberedPerPR()
    {
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        Assert.False(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/1"));
        JiraFollowUp.Dismiss(settings, "https://github.com/o/r/pull/1");
        JiraFollowUp.Dismiss(settings, "https://github.com/o/r/pull/1");
        Assert.True(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/1"));
        Assert.False(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/2"));
        Assert.Single(settings.GetObject<List<string>>(JiraFollowUp.DismissedKey)!);
    }

    [Fact]
    public void DismissKeepsTheLatestFiveHundred()
    {
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        for (var i = 0; i < 505; i++) JiraFollowUp.Dismiss(settings, $"https://github.com/o/r/pull/{i}");
        var list = settings.GetObject<List<string>>(JiraFollowUp.DismissedKey)!;
        Assert.Equal(500, list.Count);
        Assert.False(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/4"));
        Assert.True(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/5"));
        Assert.True(JiraFollowUp.IsDismissed(settings, "https://github.com/o/r/pull/504"));
    }

    [Fact]
    public void ShipPromptMentionsJiraKey()
    {
        Assert.Equal("The branch refers to Jira issue SOC-1235. Start the title with SOC-1235 and mention SOC-1235 in the description.", JiraFollowUp.ShipStep("fix/soc-1235-public-search"));
        Assert.Equal("The branch refers to Jira issues SOC-1, PAY-2. Start the title with SOC-1 and mention SOC-1, PAY-2 in the description.", JiraFollowUp.ShipStep("soc-1-pay-2"));
        Assert.Null(JiraFollowUp.ShipStep("feature/login"));
        var prompt = AgentShip.OpenPRPrompt("fix/SOC-1235-search", "main", true, 0);
        Assert.Contains("Start the title with SOC-1235", prompt);
        Assert.DoesNotContain("Jira", AgentShip.OpenPRPrompt("main", "main", true, 0));
        Assert.DoesNotContain("Jira", AgentShip.OpenPRPrompt("feature/login", "main", true, 0));
    }
}
