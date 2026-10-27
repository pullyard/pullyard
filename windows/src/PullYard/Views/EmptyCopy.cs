using PullYard.Core.Util;
using PullYard.Services;
using PullYard.ViewModels;

namespace PullYard.Views;

public sealed record EmptyCopy(string Title, string Message)
{
    private static string Lead(string s) => s.Length == 0 ? s : char.ToUpper(s[0], Fmt.Culture) + s[1..];

    public static EmptyCopy Prs(PRFilter filter, string? noun = null, StateFilter state = StateFilter.Open)
    {
        var nouns = (noun ?? L.T("Provider_PullRequest", "pull request")) + "s";
        var lead = Lead(nouns);
        var message = filter switch
        {
            PRFilter.ReviewRequested => L.T("Empty_ReviewMessage", "When someone requests your review, it shows up here."),
            PRFilter.Mine => L.F("Empty_MineMessage", "{0} you open show up here.", lead),
            PRFilter.Assigned => L.F("Empty_AssignedMessage", "{0} assigned to you show up here.", lead),
            PRFilter.Mentioned => L.F("Empty_MentionedMessage", "{0} that mention you show up here.", lead),
            _ => L.F("Empty_ReviewedMessage", "{0} you’ve reviewed show up here.", lead)
        };
        if (state == StateFilter.Closed) return new(L.F("Empty_NoClosed", "No closed {0}", nouns), message);
        var title = filter switch
        {
            PRFilter.ReviewRequested => L.T("Empty_NoReviews", "No reviews waiting"),
            PRFilter.Mine => state == StateFilter.Open ? L.F("Empty_NoOpen", "No open {0}", nouns) : L.F("Empty_NoneYet", "No {0} yet", nouns),
            PRFilter.Assigned => L.T("Empty_NothingAssigned", "Nothing assigned to you"),
            PRFilter.Mentioned => L.T("Empty_NoMentions", "No mentions"),
            _ => L.T("Empty_NothingReviewed", "Nothing reviewed yet")
        };
        return new(title, message);
    }

    public static EmptyCopy Issues(IssueFilter filter, StateFilter state = StateFilter.Open)
    {
        var message = filter switch
        {
            IssueFilter.Assigned => L.T("Empty_IssuesAssignedMessage", "Issues assigned to you show up here."),
            IssueFilter.Mine => L.T("Empty_IssuesMineMessage", "Issues you open show up here."),
            _ => L.T("Empty_IssuesMentionedMessage", "Issues that mention you show up here.")
        };
        if (state == StateFilter.Closed) return new(L.T("Empty_NoClosedIssues", "No closed issues"), message);
        var title = filter switch
        {
            IssueFilter.Assigned => L.T("Empty_NoIssuesAssigned", "No issues assigned to you"),
            IssueFilter.Mine => state == StateFilter.Open ? L.T("Empty_NoOpenIssues", "No open issues") : L.T("Empty_NoIssuesYet", "No issues yet"),
            _ => L.T("Empty_NoMentions", "No mentions")
        };
        return new(title, message);
    }

    public static EmptyCopy Search(string kind, string baseQuery, StateFilter state)
    {
        if (kind == "issue" && Enum.GetValues<IssueFilter>().Where(f => f.Query() == baseQuery).Select(f => (IssueFilter?)f).FirstOrDefault() is { } issue) return Issues(issue, state);
        if (kind == "pr" && Enum.GetValues<PRFilter>().Where(f => f.Query() == baseQuery).Select(f => (PRFilter?)f).FirstOrDefault() is { } pr) return Prs(pr, state: state);
        return List(kind == "issue" ? L.T("Empty_IssuesNoun", "issues") : L.T("Empty_PullRequestsNoun", "pull requests"), state, null);
    }

    public static EmptyCopy List(string nouns, StateFilter state, string? where)
    {
        var title = state switch
        {
            StateFilter.All => L.F("Empty_NoItems", "No {0}", nouns),
            StateFilter.Closed => L.F("Empty_NoClosed", "No closed {0}", nouns),
            _ => L.F("Empty_NoOpen", "No open {0}", nouns)
        };
        var message = where is null ? L.F("Empty_Matching", "Matching {0} show up here.", nouns) : L.F("Empty_InRepo", "{0} in {1} show up here.", Lead(nouns), where);
        return new(title, message);
    }
}
