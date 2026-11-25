using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PullYard.Core.Api;
using PullYard.Core.Auth;
using PullYard.Core.Util;

namespace PullYard.Core.Jira;

public sealed record JiraIssue(
    string Key,
    string Summary,
    string Status,
    string StatusCategory,
    string? Type,
    string? Priority,
    string? Assignee,
    string? AssigneeAvatar,
    string? Reporter,
    string Description,
    string Url,
    DateTimeOffset? Updated,
    string? ParentKey = null,
    string? ParentSummary = null,
    string? ConnectionId = null)
{
    public string SiteBase => Url.IndexOf("/browse/", StringComparison.Ordinal) is var i && i >= 0 ? Url[..i] : Url;
}

public sealed class JiraConnection
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Site { get; set; } = "";
    public string Email { get; set; } = "";
    public string? DisplayName { get; set; }
    public List<string> ProjectKeys { get; set; } = new();
    public DateTimeOffset? ProjectsUpdated { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public Uri? BaseUrl => JiraAuth.BaseUrl(Site);

    [System.Text.Json.Serialization.JsonIgnore]
    public string Host => BaseUrl?.Host ?? Site;

    [System.Text.Json.Serialization.JsonIgnore]
    public string ProjectSummary => ProjectKeys.Count == 0 ? Host : Host + " · " + string.Join(", ", ProjectKeys.Take(5)) + (ProjectKeys.Count > 5 ? $" +{ProjectKeys.Count - 5}" : "");

    public JiraConnection Copy() => new() { Id = Id, Name = Name, Site = Site, Email = Email, DisplayName = DisplayName, ProjectKeys = ProjectKeys.ToList(), ProjectsUpdated = ProjectsUpdated };
}

public enum JiraRouteSource { RepoOverride, OrgOverride, Project, Learned, Only }

public sealed record JiraTransition(string Id, string Name, string To, string ToCategory)
{
    public string Title => Name == To ? Name : $"{Name} → {To}";
}

public static partial class JiraKeys
{
    private static readonly HashSet<string> Ignored = new() { "UTF", "SHA", "ISO", "RFC", "CVE", "GPT", "TLS", "SSL", "HTTP", "MD", "X", "COVID", "ES", "IPV", "AES", "RSA" };

    [GeneratedRegex(@"(?<![A-Za-z0-9])([A-Z][A-Z0-9_]{1,9})-([1-9][0-9]{0,6})(?![A-Za-z0-9])")]
    private static partial Regex Pattern();

    public static List<string> Extract(IEnumerable<string?> texts)
    {
        var seen = new List<string>();
        foreach (var text in texts)
        {
            if (string.IsNullOrEmpty(text)) continue;
            foreach (Match m in Pattern().Matches(text))
            {
                if (Ignored.Contains(m.Groups[1].Value)) continue;
                if (!seen.Contains(m.Value)) seen.Add(m.Value);
            }
        }
        return seen;
    }

    public static List<string> Extract(params string?[] texts) => Extract((IEnumerable<string?>)texts);

    public static List<string> ExtractBranch(string? branch) => Extract(branch?.ToUpperInvariant());

    public static List<string> Detected(string? title, string? branch, string? body)
    {
        var output = new List<string>();
        foreach (var k in Extract(title).Concat(ExtractBranch(branch)).Concat(Extract(body)))
            if (!output.Contains(k)) output.Add(k);
        return output;
    }

    public static List<string> ForPullRequest(IEnumerable<string> linked, string? title, string? branch, string? body, IEnumerable<string>? hidden = null)
    {
        var manual = linked.ToList();
        var skip = new HashSet<string>(hidden ?? Enumerable.Empty<string>());
        var output = new List<string>();
        foreach (var k in manual.Concat(Detected(title, branch, body)))
            if (!output.Contains(k) && (manual.Contains(k) || !skip.Contains(k))) output.Add(k);
        return output;
    }

    public static string? Normalize(string? manual) => Extract(manual?.ToUpperInvariant()).FirstOrDefault();
}

public static partial class JiraText
{
    [GeneratedRegex(@"([+-]\d\d)(\d\d)$")]
    private static partial Regex OffsetPattern();

    [GeneratedRegex(@"(?is)<pre[^>]*>.*?</pre>")]
    private static partial Regex PreBlock();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex(@"[ \t\u00A0]+")]
    private static partial Regex Spaces();

    private static readonly (string Pattern, string Replacement)[] Tags =
    {
        (@"<br\s*/?>", "\n"),
        (@"</(p|div|h[1-6]|tr|table|blockquote|pre)>", "\n"),
        (@"<li[^>]*>", "\n• "),
        (@"</t[dh]>", " · "),
        (@"<[^>]+>", "")
    };

    private static readonly (string Entity, string Char)[] Entities =
    {
        ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")
    };

    public static string PlainText(string html)
    {
        var s = CollapseWhitespace(html);
        foreach (var (pattern, replacement) in Tags) s = Regex.Replace(s, pattern, replacement, RegexOptions.IgnoreCase);
        foreach (var (entity, ch) in Entities) s = s.Replace(entity, ch);
        var output = new List<string>();
        foreach (var raw in s.Split('\n'))
        {
            var line = Spaces().Replace(raw, " ").Trim();
            while (line.EndsWith('·')) line = line[..^1].Trim();
            while (line.StartsWith('·')) line = line[1..].Trim();
            if (line.Length == 0 && (output.Count == 0 || output[^1].Length == 0)) continue;
            output.Add(line);
        }
        return string.Join("\n", output).Replace('\u0001', '\n').Trim();
    }

    private static string CollapseWhitespace(string html)
    {
        var sb = new StringBuilder();
        var last = 0;
        foreach (Match m in PreBlock().Matches(html))
        {
            sb.Append(Whitespace().Replace(html[last..m.Index], " "));
            sb.Append(m.Value.Replace('\n', '\u0001'));
            last = m.Index + m.Length;
        }
        sb.Append(Whitespace().Replace(html[last..], " "));
        return sb.ToString();
    }

    public static DateTimeOffset? Date(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        var fixedOffset = OffsetPattern().Replace(raw, "$1:$2");
        return DateTimeOffset.TryParse(fixedOffset, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;
    }
}

public static class JiraAuth
{
    public static string Authorization(string email, string token) =>
        string.IsNullOrEmpty(email) ? $"Bearer {token}" : "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{email}:{token}"));

    private static readonly string[] UiPaths = { "/browse/", "/secure/", "/projects/", "/issues/", "/rest/", "/plugins/", "/servicedesk/" };

    public static Uri? BaseUrl(string? site)
    {
        var s = (site ?? "").Trim();
        if (s.Length == 0) return null;
        if (!s.StartsWith("http", StringComparison.OrdinalIgnoreCase)) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps || string.IsNullOrEmpty(url.Host)) return null;
        var path = url.AbsolutePath;
        if (url.Host.EndsWith(".atlassian.net", StringComparison.OrdinalIgnoreCase)) path = "";
        else
        {
            foreach (var marker in UiPaths)
            {
                var i = path.IndexOf(marker, StringComparison.Ordinal);
                if (i >= 0) path = path[..i];
            }
        }
        path = path.TrimEnd('/');
        return new Uri($"https://{url.Authority}{path}");
    }

    public static string BaseString(Uri url) => url.GetLeftPart(UriPartial.Path).TrimEnd('/');
}

public sealed class JiraClient
{
    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(30) };

    public Uri Base { get; }
    public string Authorization { get; }
    private readonly HttpClient http;

    public JiraClient(Uri baseUrl, string authorization, HttpClient? http = null)
    {
        Base = baseUrl;
        Authorization = authorization;
        this.http = http ?? SharedHttp;
    }

    private async Task<byte[]> Request(string path, HttpMethod? method = null, JsonObject? body = null, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(JiraAuth.BaseString(Base) + path, UriKind.Absolute, out var url) || url.Host != Base.Host || url.Scheme != Uri.UriSchemeHttps)
            throw new ApiException("Invalid Jira address");
        using var req = new HttpRequestMessage(method ?? HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("Authorization", Authorization);
        req.Headers.Accept.ParseAdd("application/json");
        req.Headers.TryAddWithoutValidation("X-Atlassian-Token", "no-check");
        req.Headers.UserAgent.ParseAdd(AppInfo.UserAgent);
        if (body is not null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(req, ct).ConfigureAwait(false);
        var data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is >= 200 and < 300) return data;
        throw Failure(status, data, response.ReasonPhrase);
    }

    public static ApiException Failure(int status, byte[] data, string? reason = null)
    {
        string? message = null;
        try
        {
            if (data.Length > 0 && JsonNode.Parse(data) is JsonObject o)
                message = o.Arr("errorMessages")?.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).FirstOrDefault(s => s is not null) ?? o.Str("message");
        }
        catch (JsonException)
        {
        }
        return status switch
        {
            401 => new ApiException("Jira rejected the credentials (401). Check the email and API token.", 401),
            403 => new ApiException(message ?? "No permission in Jira (403)", 403),
            404 => new ApiException(message ?? "Not found in Jira (404)", 404),
            _ => new ApiException($"Jira {status}: {message ?? reason ?? "error"}", status)
        };
    }

    private static JsonObject Parse(byte[] data)
    {
        try
        {
            if (JsonNode.Parse(data) is JsonObject o) return o;
        }
        catch (JsonException)
        {
        }
        throw new ApiException("Jira sent a web page instead of data. Check the address: it should be just your site, like acme.atlassian.net.");
    }

    public async Task<string> Myself(CancellationToken ct = default)
    {
        var o = Parse(await Request("/rest/api/2/myself", ct: ct).ConfigureAwait(false));
        return o.Str("displayName") ?? o.Str("name") ?? "Jira";
    }

    public async Task<JiraIssue> Issue(string key, CancellationToken ct = default)
    {
        const string fields = "summary,status,issuetype,priority,assignee,reporter,description,updated,parent";
        var o = Parse(await Request($"/rest/api/2/issue/{Uri.EscapeDataString(key)}?fields={fields}&expand=renderedFields", ct: ct).ConfigureAwait(false));
        return ParseIssue(o, Base);
    }

    public async Task<List<JiraTransition>> Transitions(string key, CancellationToken ct = default)
    {
        var o = Parse(await Request($"/rest/api/2/issue/{Uri.EscapeDataString(key)}/transitions", ct: ct).ConfigureAwait(false));
        return ParseTransitions(o);
    }

    public async Task<List<string>> ProjectKeys(CancellationToken ct = default)
    {
        var keys = new List<string>();
        var start = 0;
        try
        {
            while (true)
            {
                var o = Parse(await Request($"/rest/api/3/project/search?startAt={start}&maxResults=50", ct: ct).ConfigureAwait(false));
                var values = o.Arr("values").Objects().ToList();
                keys.AddRange(values.Select(v => v.Str("key")).OfType<string>());
                var total = o.Int("total") ?? keys.Count;
                start += values.Count;
                if (values.Count == 0 || o.Bool("isLast") == true || start >= total || start > 5000) break;
            }
            return keys;
        }
        catch (ApiException e) when (e.Status == 404)
        {
            var data = await Request("/rest/api/2/project", ct: ct).ConfigureAwait(false);
            try
            {
                return JsonNode.Parse(data) is JsonArray list ? list.OfType<JsonObject>().Select(v => v.Str("key")).OfType<string>().ToList() : new List<string>();
            }
            catch (JsonException)
            {
                return new List<string>();
            }
        }
    }

    public async Task Transition(string key, string id, CancellationToken ct = default)
    {
        await Request($"/rest/api/2/issue/{Uri.EscapeDataString(key)}/transitions", HttpMethod.Post, new JsonObject { ["transition"] = new JsonObject { ["id"] = id } }, ct).ConfigureAwait(false);
    }

    public static List<JiraTransition> ParseTransitions(JsonObject o)
    {
        var output = new List<JiraTransition>();
        foreach (var t in o.Arr("transitions").Objects())
        {
            if (t.Str("id") is not { } id || t.Str("name") is not { } name) continue;
            var to = t.Obj("to");
            output.Add(new JiraTransition(id, name, to.Str("name") ?? name, to.Obj("statusCategory").Str("key") ?? ""));
        }
        return output;
    }

    public static JiraIssue ParseIssue(JsonObject o, Uri baseUrl)
    {
        var key = o.Str("key") ?? "";
        var f = o.Obj("fields") ?? new JsonObject();
        var status = f.Obj("status");
        var rendered = o.Obj("renderedFields").Str("description");
        var assignee = f.Obj("assignee");
        var parent = f.Obj("parent");
        return new JiraIssue(
            key,
            f.Str("summary") ?? "",
            status.Str("name") ?? "",
            status.Obj("statusCategory").Str("key") ?? "",
            f.Obj("issuetype").Str("name"),
            f.Obj("priority").Str("name"),
            assignee.Str("displayName"),
            assignee.Obj("avatarUrls").Str("48x48"),
            f.Obj("reporter").Str("displayName"),
            rendered is not null ? JiraText.PlainText(rendered) : f.Str("description") ?? "",
            JiraAuth.BaseString(baseUrl) + "/browse/" + key,
            JiraText.Date(f.Str("updated")),
            parent.Str("key"),
            parent.Obj("fields").Str("summary"));
    }
}

public sealed class JiraConnections
{
    public const string LegacyTokenKey = "jira-token";
    private const string ListKey = "jira.connections";
    private const string OrgKey = "jira.overrides.org";
    private const string RepoKey = "jira.overrides.repo";
    private const string LearnedKey = "jira.learned";
    private const string LegacySiteKey = "jira.site";
    private const string LegacyEmailKey = "jira.email";
    private const string LegacyNameKey = "jira.name";
    private const string LegacyHasTokenKey = "jira.hasToken";
    private const string LinksPrefix = "jira.links.";
    private const string HiddenPrefix = "jira.hidden.";
    public static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan ProjectsMaxAge = TimeSpan.FromMinutes(10);

    private readonly Settings settings;
    private readonly ICredentialVault vault;
    private readonly HttpClient? http;
    private readonly Func<DateTimeOffset> now;
    private readonly object gate = new();
    private List<JiraConnection> connections;
    private Dictionary<string, string> orgOverrides;
    private Dictionary<string, string> repoOverrides;
    private Dictionary<string, string> learned;
    private readonly Dictionary<string, string?> tokens = new();
    private readonly Dictionary<string, Dictionary<string, (JiraIssue Issue, DateTimeOffset At)>> cache = new();

    public event Action? Changed;

    public JiraConnections(Settings settings, ICredentialVault vault, HttpClient? http = null, Func<DateTimeOffset>? now = null)
    {
        this.settings = settings;
        this.vault = vault;
        this.http = http;
        this.now = now ?? (() => DateTimeOffset.Now);
        connections = settings.GetObject<List<JiraConnection>>(ListKey) ?? new();
        orgOverrides = settings.GetObject<Dictionary<string, string>>(OrgKey) ?? new();
        repoOverrides = settings.GetObject<Dictionary<string, string>>(RepoKey) ?? new();
        learned = settings.GetObject<Dictionary<string, string>>(LearnedKey) ?? new();
        MigrateLegacy();
    }

    public static string TokenKey(string id) => $"jira-token.{id}";

    public static string NewId() => Guid.NewGuid().ToString().ToLowerInvariant();

    public static string ShortName(string host)
    {
        var first = host.Split('.').FirstOrDefault(p => p.Length > 0) ?? host;
        return first.Length == 0 ? "Jira" : char.ToUpperInvariant(first[0]) + first[1..];
    }

    public static string ProjectKey(string issueKey)
    {
        var i = issueKey.IndexOf('-');
        return (i > 0 ? issueKey[..i] : issueKey).ToUpperInvariant();
    }

    private void MigrateLegacy()
    {
        if (connections.Count > 0 || settings.Contains(ListKey)) return;
        var site = settings.GetString(LegacySiteKey);
        if (string.IsNullOrWhiteSpace(site)) return;
        var token = vault.Load(LegacyTokenKey);
        if (string.IsNullOrEmpty(token)) return;
        var id = NewId();
        try
        {
            vault.Save(TokenKey(id), token);
        }
        catch
        {
            return;
        }
        var name = JiraAuth.BaseUrl(site)?.Host is { } host ? ShortName(host) : "Jira";
        connections = new List<JiraConnection> { new() { Id = id, Name = name, Site = site.Trim(), Email = settings.GetString(LegacyEmailKey) ?? "", DisplayName = settings.GetString(LegacyNameKey) } };
        tokens[id] = token;
        Save();
        vault.Delete(LegacyTokenKey);
        settings.Remove(LegacyHasTokenKey);
        RefreshProjects(id).Forget();
    }

    public List<JiraConnection> Connections
    {
        get
        {
            lock (gate) return connections.Select(c => c.Copy()).ToList();
        }
    }

    public Dictionary<string, string> OrgOverrides
    {
        get
        {
            lock (gate) return new Dictionary<string, string>(orgOverrides);
        }
    }

    public Dictionary<string, string> RepoOverrides
    {
        get
        {
            lock (gate) return new Dictionary<string, string>(repoOverrides);
        }
    }

    public bool IsConfigured
    {
        get
        {
            lock (gate) return connections.Count > 0;
        }
    }

    public bool HasSeveral
    {
        get
        {
            lock (gate) return connections.Count > 1;
        }
    }

    public JiraConnection? Connection(string? id)
    {
        if (id is null) return null;
        lock (gate) return connections.FirstOrDefault(c => c.Id == id)?.Copy();
    }

    public string? Token(string id)
    {
        lock (gate)
        {
            if (tokens.TryGetValue(id, out var cached) && cached is not null) return cached;
        }
        var value = vault.Load(TokenKey(id));
        lock (gate) tokens[id] = value;
        return value;
    }

    public JiraClient? Client(string? id)
    {
        if (Connection(id) is not { } c || c.BaseUrl is not { } baseUrl || Token(c.Id) is not { Length: > 0 } token) return null;
        return new JiraClient(baseUrl, JiraAuth.Authorization(c.Email, token), http);
    }

    public async Task<JiraConnection> Add(string name, string site, string email, string token, CancellationToken ct = default)
    {
        var id = NewId();
        var connection = await Validated(id, name, site, email, token, ct).ConfigureAwait(false);
        lock (gate) connections.Add(connection);
        Save();
        await RefreshProjects(id, ct).ConfigureAwait(false);
        return Connection(id) ?? connection;
    }

    public async Task Update(string id, string name, string site, string email, string? token, CancellationToken ct = default)
    {
        if (Connection(id) is not { } existing) return;
        var t = token?.Trim();
        var secret = !string.IsNullOrEmpty(t) ? t : Token(id) ?? "";
        var updated = await Validated(id, name, site, email, secret, ct).ConfigureAwait(false);
        updated.ProjectKeys = existing.ProjectKeys;
        updated.ProjectsUpdated = existing.ProjectsUpdated;
        lock (gate)
        {
            var index = connections.FindIndex(c => c.Id == id);
            if (index < 0) return;
            connections[index] = updated;
            cache.Remove(id);
        }
        Save();
        await RefreshProjects(id, ct).ConfigureAwait(false);
    }

    public void Remove(string id)
    {
        vault.Delete(TokenKey(id));
        lock (gate)
        {
            tokens.Remove(id);
            cache.Remove(id);
            connections.RemoveAll(c => c.Id == id);
            orgOverrides = orgOverrides.Where(kv => kv.Value != id).ToDictionary(kv => kv.Key, kv => kv.Value);
            repoOverrides = repoOverrides.Where(kv => kv.Value != id).ToDictionary(kv => kv.Key, kv => kv.Value);
            learned = learned.Where(kv => kv.Value != id).ToDictionary(kv => kv.Key, kv => kv.Value);
        }
        Save();
    }

    private async Task<JiraConnection> Validated(string id, string name, string site, string email, string token, CancellationToken ct)
    {
        var mail = email.Trim();
        var secret = token.Trim();
        if (JiraAuth.BaseUrl(site) is not { } baseUrl) throw new ApiException("Enter your Jira address, for example acme.atlassian.net");
        if (secret.Length == 0) throw new ApiException("Enter an API token");
        var client = new JiraClient(baseUrl, JiraAuth.Authorization(mail, secret), http);
        var me = await client.Myself(ct).ConfigureAwait(false);
        vault.Save(TokenKey(id), secret);
        lock (gate) tokens[id] = secret;
        var label = name.Trim();
        return new JiraConnection { Id = id, Name = label.Length == 0 ? ShortName(baseUrl.Host) : label, Site = JiraAuth.BaseString(baseUrl), Email = mail, DisplayName = me };
    }

    public async Task RefreshProjects(string id, CancellationToken ct = default)
    {
        if (Client(id) is not { } client) return;
        List<string> keys;
        try
        {
            keys = await client.ProjectKeys(ct).ConfigureAwait(false);
        }
        catch
        {
            return;
        }
        lock (gate)
        {
            if (connections.FirstOrDefault(c => c.Id == id) is not { } c) return;
            c.ProjectKeys = keys.Distinct().OrderBy(k => k, StringComparer.Ordinal).ToList();
            c.ProjectsUpdated = now();
        }
        Save();
    }

    public async Task RefreshAllProjects(TimeSpan olderThan, CancellationToken ct = default)
    {
        var stamp = now();
        foreach (var c in Connections)
            if (stamp - (c.ProjectsUpdated ?? DateTimeOffset.MinValue) >= olderThan)
                await RefreshProjects(c.Id, ct).ConfigureAwait(false);
    }

    public static (string Id, JiraRouteSource Source)? Route(string issueKey, RepoRef? repo, IReadOnlyList<JiraConnection> connections, IReadOnlyDictionary<string, string> orgOverrides, IReadOnlyDictionary<string, string> repoOverrides, IReadOnlyDictionary<string, string> learned)
    {
        var ids = connections.Select(c => c.Id).ToHashSet();
        if (repo is not null)
        {
            if (repoOverrides.TryGetValue(repo.Full.ToLowerInvariant(), out var r) && ids.Contains(r)) return (r, JiraRouteSource.RepoOverride);
            if (orgOverrides.TryGetValue(repo.Owner.ToLowerInvariant(), out var o) && ids.Contains(o)) return (o, JiraRouteSource.OrgOverride);
        }
        var project = ProjectKey(issueKey);
        var owners = connections.Where(c => c.ProjectKeys.Contains(project)).ToList();
        if (owners.Count == 1) return (owners[0].Id, JiraRouteSource.Project);
        if (learned.TryGetValue(project, out var l) && ids.Contains(l) && (owners.Count == 0 || owners.Any(c => c.Id == l))) return (l, JiraRouteSource.Learned);
        if (connections.Count == 1) return (connections[0].Id, JiraRouteSource.Only);
        return null;
    }

    public (string Id, JiraRouteSource Source)? Route(string issueKey, RepoRef? repo)
    {
        lock (gate) return Route(issueKey, repo, connections, orgOverrides, repoOverrides, learned);
    }

    public string? Resolve(string issueKey, RepoRef? repo) => Route(issueKey, repo)?.Id;

    public (string? Repo, string? Org) Override(RepoRef repo)
    {
        lock (gate) return (repoOverrides.GetValueOrDefault(repo.Full.ToLowerInvariant()), orgOverrides.GetValueOrDefault(repo.Owner.ToLowerInvariant()));
    }

    public void SetRepoOverride(string? id, RepoRef repo) => SetRepoOverride(id, repo.Full);

    public void SetRepoOverride(string? id, string full)
    {
        lock (gate)
        {
            if (id is null) repoOverrides.Remove(full.ToLowerInvariant());
            else repoOverrides[full.ToLowerInvariant()] = id;
        }
        Save();
    }

    public void SetOrgOverride(string? id, string org)
    {
        lock (gate)
        {
            if (id is null) orgOverrides.Remove(org.ToLowerInvariant());
            else orgOverrides[org.ToLowerInvariant()] = id;
        }
        Save();
    }

    public string? ConnectionForRepo(RepoRef repo)
    {
        lock (gate)
        {
            var ids = connections.Select(c => c.Id).ToHashSet();
            if (repoOverrides.TryGetValue(repo.Full.ToLowerInvariant(), out var r) && ids.Contains(r)) return r;
            if (orgOverrides.TryGetValue(repo.Owner.ToLowerInvariant(), out var o) && ids.Contains(o)) return o;
            return connections.Count == 1 ? connections[0].Id : null;
        }
    }

    public async Task<JiraIssue> FetchIssue(string key, RepoRef? repo, bool useCache = true, CancellationToken ct = default)
    {
        if (useCache && CachedIssue(key, repo) is { } hit) return hit;
        if (Resolve(key, repo) is { } routed && Client(routed) is { } client)
        {
            var issue = (await client.Issue(key, ct).ConfigureAwait(false)) with { ConnectionId = routed };
            Remember(issue);
            return issue;
        }
        Exception last = new ApiException(IsConfigured ? $"No Jira connection has {key}" : "Connect Jira in Settings first");
        foreach (var c in Connections)
        {
            if (Client(c.Id) is not { } each) continue;
            try
            {
                var issue = (await each.Issue(key, ct).ConfigureAwait(false)) with { ConnectionId = c.Id };
                lock (gate) learned[ProjectKey(key)] = c.Id;
                Save(notify: false);
                Remember(issue);
                return issue;
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                last = e;
            }
        }
        throw last;
    }

    public JiraIssue? CachedIssue(string key, RepoRef? repo)
    {
        var ids = Resolve(key, repo) is { } id ? new List<string> { id } : Connections.Select(c => c.Id).ToList();
        lock (gate)
        {
            foreach (var each in ids)
                if (cache.TryGetValue(each, out var map) && map.TryGetValue(key, out var hit) && now() - hit.At < CacheLifetime) return hit.Issue;
        }
        return null;
    }

    public void Remember(JiraIssue issue)
    {
        if (issue.ConnectionId is not { } id) return;
        lock (gate)
        {
            if (!cache.TryGetValue(id, out var map)) cache[id] = map = new();
            map[issue.Key] = (issue, now());
        }
    }

    public void ClearCache()
    {
        lock (gate) cache.Clear();
    }

    public string Names(IEnumerable<JiraIssue> issues)
    {
        var list = Connections;
        if (list.Count == 1) return list[0].Host;
        var names = issues.Select(i => Connection(i.ConnectionId)?.Name).OfType<string>().Distinct().ToList();
        return string.Join(", ", names);
    }

    private void Save(bool notify = true)
    {
        lock (gate)
        {
            settings.Set(ListKey, connections);
            settings.Set(OrgKey, orgOverrides);
            settings.Set(RepoKey, repoOverrides);
            settings.Set(LearnedKey, learned);
        }
        if (notify) Changed?.Invoke();
    }

    public List<string> LinkedKeys(string prUrl) => settings.GetObject<List<string>>(LinksPrefix + prUrl) ?? new List<string>();

    public void SetLinkedKeys(string prUrl, List<string> keys)
    {
        if (keys.Count == 0) settings.Remove(LinksPrefix + prUrl);
        else settings.Set(LinksPrefix + prUrl, keys);
        Changed?.Invoke();
    }

    public List<string> HiddenKeys(string prUrl) => settings.GetObject<List<string>>(HiddenPrefix + prUrl) ?? new List<string>();

    public void SetHiddenKeys(string prUrl, List<string> keys)
    {
        if (keys.Count == 0) settings.Remove(HiddenPrefix + prUrl);
        else settings.Set(HiddenPrefix + prUrl, keys);
        Changed?.Invoke();
    }

    public void Hide(string prUrl, string key)
    {
        var hidden = HiddenKeys(prUrl);
        if (hidden.Contains(key)) return;
        hidden.Add(key);
        SetHiddenKeys(prUrl, hidden);
    }

    public void ShowHidden(string prUrl) => SetHiddenKeys(prUrl, new List<string>());

    public string? Link(string prUrl, string manual)
    {
        if (JiraKeys.Normalize(manual) is not { } key) return null;
        var hidden = HiddenKeys(prUrl);
        if (hidden.Remove(key)) SetHiddenKeys(prUrl, hidden);
        var linked = LinkedKeys(prUrl);
        if (!linked.Contains(key)) linked.Insert(0, key);
        SetLinkedKeys(prUrl, linked);
        return key;
    }

    public void Unlink(string prUrl, string key) => SetLinkedKeys(prUrl, LinkedKeys(prUrl).Where(k => k != key).ToList());

    public List<string> Keys(PullRequestDetail pr) => JiraKeys.ForPullRequest(LinkedKeys(pr.Url), pr.Title, pr.HeadRefName, pr.Body, HiddenKeys(pr.Url));

    public bool ShowsTab(PullRequestDetail pr) => IsConfigured || Keys(pr).Count > 0;
}
