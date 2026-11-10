using PullYard.Core.Api;

namespace PullYard.Core.Git;

public enum GitRemoteKind { GitHub, GitLab, Bitbucket, Other }

public sealed record GitRemote(string Host, string Path, GitRemoteKind Kind)
{
    public RepoRef? GitHubRepo => Host == "github.com" ? RepoRef.Parse(Path) : null;

    public string WebUrl => $"https://{Host}/{Path}";

    public string Noun => Kind == GitRemoteKind.GitLab ? "merge request" : "pull request";

    public string NewRequestUrl(string branch)
    {
        var b = Uri.EscapeDataString(branch).Replace("%2F", "/");
        return Kind switch
        {
            GitRemoteKind.GitHub => $"{WebUrl}/pull/new/{b}",
            GitRemoteKind.GitLab => $"{WebUrl}/-/merge_requests/new?merge_request%5Bsource_branch%5D={b}",
            GitRemoteKind.Bitbucket => $"{WebUrl}/pull-requests/new?source={b}",
            _ => WebUrl
        };
    }

    public static GitRemote? Parse(string? raw)
    {
        var url = (raw ?? "").Trim();
        if (url.Length == 0) return null;
        url = url.TrimEnd('/');
        if (url.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) url = url[..^4];
        string host, path;
        if (url.Contains("://") && Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Host.Length > 0)
        {
            host = uri.Host;
            path = Uri.UnescapeDataString(uri.AbsolutePath);
        }
        else if (url.IndexOf('@') is var at and >= 0 && url.IndexOf(':', at) is var colon and >= 0)
        {
            host = url[(at + 1)..colon];
            path = url[(colon + 1)..];
        }
        else
        {
            return null;
        }
        host = host.ToLowerInvariant();
        path = path.Trim('/');
        if (host == "ssh.github.com") host = "github.com";
        if (host.StartsWith("altssh.")) host = host["altssh.".Length..];
        if (host == "bitbucket.org" && path.StartsWith("scm/")) path = path["scm/".Length..];
        if (host.Length == 0 || !path.Contains('/')) return null;
        var kind = host.Contains("github") ? GitRemoteKind.GitHub
            : host.Contains("gitlab") ? GitRemoteKind.GitLab
            : host.Contains("bitbucket") ? GitRemoteKind.Bitbucket
            : GitRemoteKind.Other;
        return new GitRemote(host, path, kind);
    }
}
