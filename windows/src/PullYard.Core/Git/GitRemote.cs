using PullYard.Core.Api;
using PullYard.Core.Auth;

namespace PullYard.Core.Git;

public enum GitRemoteKind { GitHub, GitLab, Bitbucket, Other }

public sealed record GitRemote(string Host, string Path)
{
    public GitRemoteKind Kind
    {
        get
        {
            var h = Host.ToLowerInvariant();
            if (h.Contains("github")) return GitRemoteKind.GitHub;
            if (h.Contains("gitlab")) return GitRemoteKind.GitLab;
            if (h.Contains("bitbucket")) return GitRemoteKind.Bitbucket;
            return GitRemoteKind.Other;
        }
    }

    public string WebUrl => $"https://{Host}/{Path}";

    public RepoRef? Repo => Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ? RepoRef.Parse(Path) : null;

    public GitRemoteKind KindFor(GitProvider? provider) => provider switch
    {
        GitProvider.GitHub or GitProvider.GitHubEnterprise => GitRemoteKind.GitHub,
        GitProvider.GitLab => GitRemoteKind.GitLab,
        GitProvider.Bitbucket => GitRemoteKind.Bitbucket,
        GitProvider.Gitea => GitRemoteKind.Other,
        _ => Kind
    };

    public static string RequestNoun(GitRemoteKind kind) => kind == GitRemoteKind.GitLab ? "merge request" : "pull request";

    public string NewRequestUrl(string branch, GitRemoteKind kind)
    {
        var b = Uri.EscapeDataString(branch).Replace("%2F", "/");
        return kind switch
        {
            GitRemoteKind.GitHub => $"{WebUrl}/pull/new/{b}",
            GitRemoteKind.GitLab => $"{WebUrl}/-/merge_requests/new?merge_request%5Bsource_branch%5D={b}",
            GitRemoteKind.Bitbucket => $"{WebUrl}/pull-requests/new?source={b}",
            _ => $"{WebUrl}/pulls"
        };
    }

    public static GitRemote? Parse(string? raw)
    {
        var url = (raw ?? "").Trim();
        if (url.Length == 0) return null;
        string host, path;
        var scheme = url.IndexOf("://", StringComparison.Ordinal);
        var colon = url.IndexOf(':');
        if (scheme >= 0)
        {
            url = url[(scheme + 3)..];
            var slash = url.IndexOf('/');
            if (slash < 0) return null;
            host = url[..slash];
            path = url[(slash + 1)..];
            var at = host.LastIndexOf('@');
            if (at >= 0) host = host[(at + 1)..];
            var port = host.IndexOf(':');
            if (port >= 0) host = host[..port];
        }
        else if (colon >= 0 && !url[..colon].Contains('/') && !url[..colon].Contains('\\') && colon != 1)
        {
            host = url[..colon];
            path = url[(colon + 1)..];
            var at = host.LastIndexOf('@');
            if (at >= 0) host = host[(at + 1)..];
        }
        else
        {
            return null;
        }
        path = path.Trim('/');
        if (path.EndsWith(".git", StringComparison.Ordinal)) path = path[..^4];
        if (host.Length == 0 || !path.Contains('/')) return null;
        return new GitRemote(host, path);
    }
}
