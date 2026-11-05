using PullYard.Core.Api;
using PullYard.Core.Claude;
using PullYard.Core.Util;

namespace PullYard.Core.Git;

public sealed record PRWorktree(string Path, string Branch, string Remote, string HeadOid, bool Reused, bool Dirty);

public sealed class GitException(string message) : Exception(message);

public static class PRWorktrees
{
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static string Normalize(string path) => System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path));

    public static string Path(string clone, int number)
    {
        var full = Normalize(clone);
        var parent = System.IO.Path.GetDirectoryName(full) ?? full;
        return System.IO.Path.Combine(parent, System.IO.Path.GetFileName(full) + "-worktrees", $"pr-{number}");
    }

    public static string Branch(int number) => $"pullyard/pr-{number}";

    public static async Task<string> Git(IEnumerable<string> args, string dir, CancellationToken ct = default)
    {
        var list = args.ToList();
        var r = await Proc.Run(GitCli.Binary, new[] { "-C", dir, "-c", "core.quotepath=off", "--no-pager" }.Concat(list), env: new Dictionary<string, string?>
        {
            ["LC_ALL"] = "C",
            ["GIT_TERMINAL_PROMPT"] = "0"
        }, timeout: TimeSpan.FromMinutes(5), ct: ct).ConfigureAwait(false);
        if (!r.Ok)
        {
            var msg = r.Err.Trim();
            throw new GitException($"git {list.FirstOrDefault() ?? ""} failed: {(msg.Length == 0 ? $"exit {r.Code}" : msg)}");
        }
        return r.Out.Trim();
    }

    public static string? Remote(RepoRef repo, string remotes)
    {
        var target = repo.Full.ToLowerInvariant();
        foreach (var line in remotes.Replace("\r", "").Split('\n'))
        {
            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            var url = parts[1].ToLowerInvariant();
            if (url.EndsWith(".git")) url = url[..^4];
            if (url.EndsWith("/" + target) || url.EndsWith(":" + target)) return parts[0];
        }
        return null;
    }

    public static HashSet<string> Registered(string porcelain) =>
        porcelain.Replace("\r", "").Split('\n')
            .Where(l => l.StartsWith("worktree "))
            .Select(l => Normalize(l["worktree ".Length..]))
            .ToHashSet(PathComparer);

    private static async Task<bool> IsRegistered(string clone, string path, CancellationToken ct)
    {
        var known = Registered(await Git(new[] { "worktree", "list", "--porcelain" }, clone, ct).ConfigureAwait(false));
        if (known.Contains(Normalize(path))) return true;
        if (!Directory.Exists(path)) return false;
        try
        {
            var top = await Git(new[] { "rev-parse", "--show-toplevel" }, path, ct).ConfigureAwait(false);
            return known.Contains(Normalize(top));
        }
        catch (GitException)
        {
            return false;
        }
    }

    public static async Task<PRWorktree> Prepare(string clone, RepoRef repo, int number, CancellationToken ct = default)
    {
        string remotes;
        try
        {
            remotes = await Git(new[] { "remote", "-v" }, clone, ct).ConfigureAwait(false);
        }
        catch (GitException)
        {
            remotes = "";
        }
        var remote = Remote(repo, remotes) ?? "origin";
        await Git(new[] { "fetch", "--quiet", remote, $"pull/{number}/head" }, clone, ct).ConfigureAwait(false);
        var head = await Git(new[] { "rev-parse", "FETCH_HEAD" }, clone, ct).ConfigureAwait(false);
        var path = Path(clone, number);
        var branch = Branch(number);
        var registered = await IsRegistered(clone, path, ct).ConfigureAwait(false);
        if (registered && Directory.Exists(path))
        {
            var dirty = (await Git(new[] { "status", "--porcelain" }, path, ct).ConfigureAwait(false)).Length > 0;
            if (!dirty) await Git(new[] { "checkout", "--quiet", "-B", branch, head }, path, ct).ConfigureAwait(false);
            var current = await Git(new[] { "rev-parse", "HEAD" }, path, ct).ConfigureAwait(false);
            return new PRWorktree(path, branch, remote, current, true, dirty);
        }
        if (registered)
        {
            try
            {
                await Git(new[] { "worktree", "prune" }, clone, ct).ConfigureAwait(false);
            }
            catch (GitException)
            {
            }
        }
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        await Git(new[] { "worktree", "add", "--quiet", "-B", branch, path, head }, clone, ct).ConfigureAwait(false);
        return new PRWorktree(path, branch, remote, head, false, false);
    }

    public static async Task<string?> Existing(string clone, int number, CancellationToken ct = default)
    {
        var path = Path(clone, number);
        if (!Directory.Exists(path)) return null;
        try
        {
            return await IsRegistered(clone, path, ct).ConfigureAwait(false) ? path : null;
        }
        catch (GitException)
        {
            return null;
        }
    }

    public static async Task Remove(string clone, int number, CancellationToken ct = default)
    {
        var path = Path(clone, number);
        if ((await Git(new[] { "status", "--porcelain" }, path, ct).ConfigureAwait(false)).Length > 0)
            throw new GitException("The worktree has uncommitted changes. Commit or discard them first.");
        await Git(new[] { "worktree", "remove", path }, clone, ct).ConfigureAwait(false);
        try
        {
            await Git(new[] { "branch", "-D", Branch(number) }, clone, ct).ConfigureAwait(false);
        }
        catch (GitException)
        {
        }
    }

    public static string Adapt(string prompt, PRWorktree worktree, PullRequestDetail pr, RepoRef repo)
    {
        var forkRepo = pr.HeadRepository?.NameWithOwner;
        var fork = forkRepo is not null && !string.Equals(forkRepo, repo.Full, StringComparison.OrdinalIgnoreCase);
        var shortHead = worktree.HeadOid.Length > 12 ? worktree.HeadOid[..12] : worktree.HeadOid;
        var note = $"You are working in an isolated git worktree at {worktree.Path} on local branch {worktree.Branch}, checked out at the pull request head {shortHead}. Do not run `gh pr checkout` and do not switch branches; my main checkout is not affected.";
        if (worktree.Dirty) note += " The worktree already has uncommitted changes from an earlier session; keep them unless they conflict with this task.";
        var output = prompt;
        var checkout = new[] { FixPrompt.CheckoutStep(pr.Number), FixPromptExtractor.CheckoutNote(pr.Number) };
        if (checkout.FirstOrDefault(c => output.Contains(c)) is { } hit)
            output = output.Replace(hit, hit.StartsWith("Before starting") ? "Before starting: " + note : note);
        else
            output = note + "\n\n" + output;
        var push = fork
            ? $"ask me before pushing: this pull request's branch lives in the fork {forkRepo}"
            : $"`git push {worktree.Remote} HEAD:{pr.HeadRefName}`";
        return output.Replace("(`git push`)", $"({push})");
    }
}
