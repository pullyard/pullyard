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
    DateTimeOffset? Updated);

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

    public static List<string> ForPullRequest(IEnumerable<string> linked, string? title, string? branch, string? body)
    {
        var output = new List<string>();
        foreach (var k in linked.Concat(Detected(title, branch, body)))
            if (!output.Contains(k)) output.Add(k);
        return output;
    }

    public static string? Normalize(string? manual) => Extract(manual?.ToUpperInvariant()).FirstOrDefault();
}

public static partial class JiraText
{
    [GeneratedRegex(@"([+-]\d\d)(\d\d)$")]
    private static partial Regex OffsetPattern();

    [GeneratedRegex(@"\n{3,}")]
    private static partial Regex BlankLines();

    private static readonly (string Pattern, string Replacement)[] Tags =
    {
        (@"<br\s*/?>", "\n"),
        ("</p>", "\n\n"),
        ("<li>", "• "),
        ("</li>", "\n"),
        ("</h[1-6]>", "\n\n"),
        ("<[^>]+>", "")
    };

    private static readonly (string Entity, string Char)[] Entities =
    {
        ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")
    };

    public static string PlainText(string html)
    {
        var s = html;
        foreach (var (pattern, replacement) in Tags) s = Regex.Replace(s, pattern, replacement, RegexOptions.IgnoreCase);
        foreach (var (entity, ch) in Entities) s = s.Replace(entity, ch);
        s = BlankLines().Replace(s, "\n\n");
        return s.Trim();
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
        const string fields = "summary,status,issuetype,priority,assignee,reporter,description,updated";
        var o = Parse(await Request($"/rest/api/2/issue/{Uri.EscapeDataString(key)}?fields={fields}&expand=renderedFields", ct: ct).ConfigureAwait(false));
        return ParseIssue(o, Base);
    }

    public async Task<List<JiraTransition>> Transitions(string key, CancellationToken ct = default)
    {
        var o = Parse(await Request($"/rest/api/2/issue/{Uri.EscapeDataString(key)}/transitions", ct: ct).ConfigureAwait(false));
        return ParseTransitions(o);
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
            JiraText.Date(f.Str("updated")));
    }
}

public sealed class JiraAccount
{
    public const string TokenKey = "jira-token";
    private const string SiteKey = "jira.site";
    private const string EmailKey = "jira.email";
    private const string HasTokenKey = "jira.hasToken";
    private const string NameKey = "jira.name";
    private const string LinksPrefix = "jira.links.";
    public static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(60);

    private readonly Settings settings;
    private readonly ICredentialVault vault;
    private readonly HttpClient? http;
    private readonly Func<DateTimeOffset> now;
    private readonly object gate = new();
    private readonly Dictionary<string, (JiraIssue Issue, DateTimeOffset At)> cache = new();
    private string? token;

    public event Action? Changed;

    public JiraAccount(Settings settings, ICredentialVault vault, HttpClient? http = null, Func<DateTimeOffset>? now = null)
    {
        this.settings = settings;
        this.vault = vault;
        this.http = http;
        this.now = now ?? (() => DateTimeOffset.Now);
    }

    public string Site => settings.GetString(SiteKey) ?? "";
    public string Email => settings.GetString(EmailKey) ?? "";
    public bool HasToken => settings.GetBool(HasTokenKey, false);
    public string? DisplayName => settings.GetString(NameKey);
    public Uri? BaseUrl => JiraAuth.BaseUrl(Site);
    public bool IsConfigured => BaseUrl is not null && HasToken;

    public async Task Connect(string site, string email, string tokenValue, CancellationToken ct = default)
    {
        settings.Set(SiteKey, site.Trim());
        settings.Set(EmailKey, email.Trim());
        var t = tokenValue.Trim();
        if (BaseUrl is not { } baseUrl) throw new ApiException("Enter your Jira address, for example acme.atlassian.net");
        if (t.Length == 0) throw new ApiException("Enter your API token");
        var client = new JiraClient(baseUrl, JiraAuth.Authorization(Email, t), http);
        var name = await client.Myself(ct).ConfigureAwait(false);
        vault.Save(TokenKey, t);
        lock (gate)
        {
            token = t;
            cache.Clear();
        }
        settings.Set(HasTokenKey, true);
        settings.Set(NameKey, name);
        Changed?.Invoke();
    }

    public void Disconnect()
    {
        vault.Delete(TokenKey);
        lock (gate)
        {
            token = null;
            cache.Clear();
        }
        settings.Set(HasTokenKey, false);
        settings.Remove(NameKey);
        Changed?.Invoke();
    }

    public JiraClient? Client()
    {
        if (!HasToken || BaseUrl is not { } baseUrl) return null;
        string? t;
        lock (gate)
        {
            token ??= vault.Load(TokenKey);
            t = token;
        }
        return string.IsNullOrEmpty(t) ? null : new JiraClient(baseUrl, JiraAuth.Authorization(Email, t), http);
    }

    public JiraIssue? CachedIssue(string key)
    {
        lock (gate) return cache.TryGetValue(key, out var hit) && now() - hit.At < CacheLifetime ? hit.Issue : null;
    }

    public void Remember(JiraIssue issue)
    {
        lock (gate) cache[issue.Key] = (issue, now());
    }

    public List<string> LinkedKeys(string prUrl) => settings.GetObject<List<string>>(LinksPrefix + prUrl) ?? new List<string>();

    public void SetLinkedKeys(string prUrl, List<string> keys)
    {
        if (keys.Count == 0) settings.Remove(LinksPrefix + prUrl);
        else settings.Set(LinksPrefix + prUrl, keys);
        Changed?.Invoke();
    }

    public string? Link(string prUrl, string manual)
    {
        if (JiraKeys.Normalize(manual) is not { } key) return null;
        var linked = LinkedKeys(prUrl);
        if (!linked.Contains(key)) linked.Add(key);
        SetLinkedKeys(prUrl, linked);
        return key;
    }

    public void Unlink(string prUrl, string key) => SetLinkedKeys(prUrl, LinkedKeys(prUrl).Where(k => k != key).ToList());

    public List<string> Keys(PullRequestDetail pr) => JiraKeys.ForPullRequest(LinkedKeys(pr.Url), pr.Title, pr.HeadRefName, pr.Body);

    public bool ShowsTab(PullRequestDetail pr) => IsConfigured || Keys(pr).Count > 0;

    public async Task<JiraIssue> Load(string key, bool useCache = true, CancellationToken ct = default)
    {
        if (useCache && CachedIssue(key) is { } hit) return hit;
        if (Client() is not { } client) throw new ApiException("Connect Jira in Settings first");
        var issue = await client.Issue(key, ct).ConfigureAwait(false);
        Remember(issue);
        return issue;
    }
}
