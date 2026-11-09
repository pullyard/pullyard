using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Serialization;
using PullYard.Core.Auth;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum AgentEndpointKind { OpenRouter, Custom }

public enum AgentEndpointProblem { MissingAddress, InsecureScheme }

public sealed record AgentEndpoint
{
    public const string OpenRouterUrl = "https://openrouter.ai/api";
    private static readonly string[] LoopbackHosts = { "localhost", "127.0.0.1", "::1", "[::1]" };

    public AgentEndpointKind Kind { get; set; }
    public string BaseUrl { get; set; } = "";
    public string? Model { get; set; }

    [JsonIgnore]
    public string Host => Uri.TryCreate(BaseUrl, UriKind.Absolute, out var u) && u.Host.Length > 0 ? u.Host : BaseUrl;

    [JsonIgnore]
    public string ProviderName => Kind == AgentEndpointKind.OpenRouter ? "OpenRouter" : Host;

    [JsonIgnore]
    public string? TrimmedModel => Model?.Trim() is { Length: > 0 } m ? m : null;

    public Dictionary<string, string> Environment(string token)
    {
        var env = new Dictionary<string, string>
        {
            ["ANTHROPIC_BASE_URL"] = BaseUrl,
            ["ANTHROPIC_AUTH_TOKEN"] = token,
            ["ANTHROPIC_API_KEY"] = ""
        };
        if (TrimmedModel is { } model) env["ANTHROPIC_MODEL"] = model;
        return env;
    }

    public static string Normalized(string? raw)
    {
        var s = (raw ?? "").Trim();
        return s.TrimEnd('/');
    }

    public static AgentEndpointProblem? Problem(string? baseUrl)
    {
        var s = Normalized(baseUrl);
        if (!s.Contains("://") || !Uri.TryCreate(s, UriKind.Absolute, out var uri) || uri.Host.Length == 0) return AgentEndpointProblem.MissingAddress;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme == "https") return null;
        if (scheme == "http" && LoopbackHosts.Contains(uri.Host.ToLowerInvariant())) return null;
        return AgentEndpointProblem.InsecureScheme;
    }

    public static string CredentialKey(string profileId) => $"agent-endpoint-{profileId}";
}

public static class AgentEndpoints
{
    public static ICredentialVault? Vault { get; set; }

    public static string EnvDirectory => Path.Combine(Path.GetTempPath(), "PullYard", "env");

    public static (string ProfileId, AgentEndpoint Endpoint)? Endpoint(string? configDir, Settings? settings = null)
    {
        if (configDir is null) return null;
        var profiles = (settings ?? Settings.Shared).GetObject<List<ClaudeProfile>>(Keys.ClaudeProfiles);
        if (profiles?.FirstOrDefault(p => p.ConfigDir is { } dir && string.Equals(dir, configDir, StringComparison.OrdinalIgnoreCase)) is not { Endpoint: { } endpoint } profile) return null;
        return (profile.Id, endpoint);
    }

    public static string? LoadKey(string profileId)
    {
        try
        {
            return Vault?.Load(AgentEndpoint.CredentialKey(profileId));
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "loading endpoint key failed");
            return null;
        }
    }

    public static bool HasKey(string profileId) => !string.IsNullOrEmpty(LoadKey(profileId));

    public static void SaveKey(string profileId, string key)
    {
        if (Vault is not { } vault) throw new InvalidOperationException("The credential store is not available.");
        vault.Save(AgentEndpoint.CredentialKey(profileId), key);
    }

    public static void DeleteKey(string profileId)
    {
        try
        {
            Vault?.Delete(AgentEndpoint.CredentialKey(profileId));
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "deleting endpoint key failed");
        }
    }

    public static Dictionary<string, string>? Environment(string? configDir)
    {
        if (Endpoint(configDir) is not { } found) return null;
        return found.Endpoint.Environment(LoadKey(found.ProfileId) ?? "");
    }

    public static string PowerShellPrelude(string? configDir) => PowerShellPrelude(Environment(configDir), EnvDirectory);

    public static string PowerShellPrelude(IReadOnlyDictionary<string, string>? env, string directory)
    {
        if (env is null) return "";
        Directory.CreateDirectory(directory);
        Sweep(directory);
        var file = Path.Combine(directory, $"env-{Guid.NewGuid().ToString("N")[..8]}.ps1");
        var body = new StringBuilder();
        foreach (var key in env.Keys.OrderBy(k => k, StringComparer.Ordinal))
            body.Append("$env:").Append(key).Append(" = ").Append(ClaudeLauncher.PsQuote(env[key])).Append("\r\n");
        WritePrivate(file, body.ToString());
        var quoted = ClaudeLauncher.PsQuote(file);
        return $". {quoted}\r\nRemove-Item -LiteralPath {quoted} -Force -ErrorAction SilentlyContinue\r\n";
    }

    private static void WritePrivate(string file, string text)
    {
        var bytes = new UTF8Encoding(true).GetBytes(text);
        if (OperatingSystem.IsWindows())
        {
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            if (WindowsIdentity.GetCurrent().User is { } user)
                security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
            using var stream = new FileInfo(file).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.None, security);
            stream.Write(bytes, 0, bytes.Length);
            return;
        }
        using (var stream = new FileStream(file, new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite }))
            stream.Write(bytes, 0, bytes.Length);
    }

    public static void Sweep(string directory, DateTime? now = null)
    {
        var at = now ?? DateTime.UtcNow;
        try
        {
            foreach (var f in Directory.EnumerateFiles(directory, "env-*"))
            {
                try
                {
                    if (at - File.GetLastWriteTimeUtc(f) > TimeSpan.FromMinutes(10)) File.Delete(f);
                }
                catch
                {
                }
            }
        }
        catch
        {
        }
    }
}
