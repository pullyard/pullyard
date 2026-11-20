using PullYard.Core.Api;
using PullYard.Core.Auth;

namespace PullYard.Core.Git;

public enum GitRemoteKind { GitHub, GitLab, Bitbucket, Other }

public sealed record GitRemote(string Host, string Path, GitRemoteKind Kind)
{
    public GitRemote(string Host, string Path) : this(Host, Path, KindOf(Host))
    {
    }

    public static GitRemoteKind KindOf(string host)
    {
        var h = host.ToLowerInvariant();
        if (h.Contains("github")) return GitRemoteKind.GitHub;
        if (h.Contains("gitlab")) return GitRemoteKind.GitLab;
        if (h.Contains("bitbucket")) return GitRemoteKind.Bitbucket;
        return GitRemoteKind.Other;
    }

    public RepoRef? GitHubRepo => Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ? RepoRef.Parse(Path) : null;

    public RepoRef? Repo => GitHubRepo;

    public string WebUrl => $"https://{Host}/{Path}";

    public string Noun => RequestNoun(Kind);

    public GitRemoteKind KindFor(GitProvider? provider) => provider switch
    {
        GitProvider.GitHub or GitProvider.GitHubEnterprise => GitRemoteKind.GitHub,
        GitProvider.GitLab => GitRemoteKind.GitLab,
        GitProvider.Bitbucket => GitRemoteKind.Bitbucket,
        GitProvider.Gitea => GitRemoteKind.Other,
        _ => Kind
    };

    public static string RequestNoun(GitRemoteKind kind) => kind == GitRemoteKind.GitLab ? "merge request" : "pull request";

    public string NewRequestUrl(string branch) => RequestUrl(branch, Kind, WebUrl);

    public string NewRequestUrl(string branch, GitRemoteKind kind) => RequestUrl(branch, kind, $"{WebUrl}/pulls");

    private string RequestUrl(string branch, GitRemoteKind kind, string fallback)
    {
        var b = Uri.EscapeDataString(branch).Replace("%2F", "/");
        return kind switch
        {
            GitRemoteKind.GitHub => $"{WebUrl}/pull/new/{b}",
            GitRemoteKind.GitLab => $"{WebUrl}/-/merge_requests/new?merge_request%5Bsource_branch%5D={b}",
            GitRemoteKind.Bitbucket => $"{WebUrl}/pull-requests/new?source={b}",
            _ => fallback
        };
    }

    public static GitRemote? Parse(string? raw)
    {
        var url = (raw ?? "").Trim().TrimEnd('/');
        if (url.Length == 0) return null;
        if (url.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) url = url[..^4];
        string host, path;
        var scheme = url.IndexOf("://", StringComparison.Ordinal);
        var colon = url.IndexOf(':');
        if (scheme >= 0)
        {
            url = url[(scheme + 3)..];
            var slash = url.IndexOf('/');
            if (slash < 0) return null;
            host = url[..slash];
            path = Uri.UnescapeDataString(url[(slash + 1)..]);
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
        host = host.ToLowerInvariant();
        path = path.Trim('/');
        if (host == "ssh.github.com") host = "github.com";
        if (host.StartsWith("altssh.", StringComparison.Ordinal)) host = host["altssh.".Length..];
        if (host == "bitbucket.org" && path.StartsWith("scm/", StringComparison.Ordinal)) path = path["scm/".Length..];
        if (host.Length == 0 || !path.Contains('/')) return null;
        return new GitRemote(host, path, KindOf(host));
    }
}
