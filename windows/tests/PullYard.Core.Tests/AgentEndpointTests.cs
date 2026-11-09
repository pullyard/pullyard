using PullYard.Core.Auth;
using PullYard.Core.Claude;
using PullYard.Core.Util;
using Xunit;

namespace PullYard.Core.Tests;

public class AgentEndpointTests : IDisposable
{
    private readonly string dir = Path.Combine(Path.GetTempPath(), "pullyard-ep-" + Guid.NewGuid().ToString("N"));

    public AgentEndpointTests() => Directory.CreateDirectory(dir);

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
    }

    [Fact]
    public void EnvironmentForOpenRouter()
    {
        var ep = new AgentEndpoint { Kind = AgentEndpointKind.OpenRouter, BaseUrl = AgentEndpoint.OpenRouterUrl, Model = " anthropic/claude-sonnet-4.5 " };
        Assert.Equal(new Dictionary<string, string>
        {
            ["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api",
            ["ANTHROPIC_AUTH_TOKEN"] = "sk-or-1",
            ["ANTHROPIC_API_KEY"] = "",
            ["ANTHROPIC_MODEL"] = "anthropic/claude-sonnet-4.5"
        }, ep.Environment("sk-or-1"));
        var noModel = new AgentEndpoint { Kind = AgentEndpointKind.Custom, BaseUrl = "https://gw.example.com", Model = "  " };
        Assert.False(noModel.Environment("k").ContainsKey("ANTHROPIC_MODEL"));
        Assert.Equal("gw.example.com", noModel.Host);
        Assert.Equal("gw.example.com", noModel.ProviderName);
        Assert.Equal("OpenRouter", ep.ProviderName);
    }

    [Fact]
    public void BaseUrlValidation()
    {
        Assert.Null(AgentEndpoint.Problem("https://openrouter.ai/api/"));
        Assert.Null(AgentEndpoint.Problem("http://localhost:4000"));
        Assert.Null(AgentEndpoint.Problem("http://127.0.0.1:8080"));
        Assert.Null(AgentEndpoint.Problem("http://[::1]:8080"));
        Assert.Equal(AgentEndpointProblem.InsecureScheme, AgentEndpoint.Problem("http://gw.example.com"));
        Assert.Equal(AgentEndpointProblem.MissingAddress, AgentEndpoint.Problem("openrouter.ai/api"));
        Assert.Equal(AgentEndpointProblem.MissingAddress, AgentEndpoint.Problem(""));
        Assert.Equal("https://openrouter.ai/api", AgentEndpoint.Normalized(" https://openrouter.ai/api// "));
    }

    [Fact]
    public void ProfileDecodingKeepsOldDataAndFindsEndpoint()
    {
        var settings = new Settings(Path.Combine(dir, "settings.json"));
        settings.Set(Keys.ClaudeProfiles, System.Text.Json.Nodes.JsonNode.Parse("""[{"id":"default","label":"Main"},{"id":"a","label":"Work","configDir":"/x/a"}]"""));
        Assert.Null(AgentEndpoints.Endpoint("/x/a", settings));
        Assert.Null(AgentEndpoints.Endpoint(null, settings));

        var ep = new AgentEndpoint { Kind = AgentEndpointKind.OpenRouter, BaseUrl = AgentEndpoint.OpenRouterUrl };
        settings.Set(Keys.ClaudeProfiles, new List<ClaudeProfile> { new() { Id = "default", Label = "Main" }, new() { Id = "b", Label = "OR", ConfigDir = "/x/b", Endpoint = ep } });
        var reloaded = new Settings(Path.Combine(dir, "settings.json"));
        var found = AgentEndpoints.Endpoint("/x/b", reloaded);
        Assert.NotNull(found);
        Assert.Equal("b", found.Value.ProfileId);
        Assert.Equal(ep, found.Value.Endpoint);
        Assert.Equal("agent-endpoint-b", AgentEndpoint.CredentialKey("b"));
    }

    private sealed class MemoryVault : ICredentialVault
    {
        public Dictionary<string, string> Values { get; } = new();
        public string? Load(string key) => Values.TryGetValue(key, out var v) ? v : null;
        public void Save(string key, string value) => Values[key] = value;
        public bool Delete(string key) => Values.Remove(key) || true;
    }

    [Fact]
    public void ProfilesStoreUpdateAndRemoveEndpointKeys()
    {
        var vault = new MemoryVault();
        var previous = AgentEndpoints.Vault;
        AgentEndpoints.Vault = vault;
        try
        {
            var profiles = new ClaudeProfiles(new Settings(Path.Combine(dir, "settings.json")), Path.Combine(dir, "accounts"));
            var ep = new AgentEndpoint { Kind = AgentEndpointKind.OpenRouter, BaseUrl = AgentEndpoint.OpenRouterUrl };
            var p = profiles.Add("OR", false, endpoint: ep, key: "sk-or-1");
            Assert.Equal("sk-or-1", vault.Values[AgentEndpoint.CredentialKey(p.Id)]);
            Assert.True(AgentEndpoints.HasKey(p.Id));

            profiles.UpdateEndpoint(p.Id, ep with { Model = "m" }, "");
            Assert.Equal("sk-or-1", vault.Values[AgentEndpoint.CredentialKey(p.Id)]);
            Assert.Equal("m", profiles.Profiles.Single(x => x.Id == p.Id).Endpoint?.Model);
            profiles.UpdateEndpoint(p.Id, ep, "sk-or-2");
            Assert.Equal("sk-or-2", vault.Values[AgentEndpoint.CredentialKey(p.Id)]);

            profiles.UpdateEndpoint(ClaudeProfiles.DefaultId, ep, "x");
            Assert.Null(profiles.Profiles.Single(x => x.IsDefault).Endpoint);

            profiles.Remove(p.Id);
            Assert.Empty(vault.Values);
        }
        finally
        {
            AgentEndpoints.Vault = previous;
        }
    }

    [Fact]
    public void PowerShellPreludeWritesPrivateFileAndSourcesIt()
    {
        Assert.Equal("", AgentEndpoints.PowerShellPrelude(null, dir));
        var line = AgentEndpoints.PowerShellPrelude(new Dictionary<string, string> { ["ANTHROPIC_AUTH_TOKEN"] = "it's secret", ["ANTHROPIC_API_KEY"] = "" }, dir);
        var file = Assert.Single(Directory.GetFiles(dir, "env-*"));
        Assert.DoesNotContain("secret", line);
        Assert.StartsWith(". '" + file + "'", line);
        Assert.Contains("Remove-Item -LiteralPath '" + file + "'", line);
        var body = File.ReadAllText(file);
        Assert.Contains("$env:ANTHROPIC_AUTH_TOKEN = 'it''s secret'", body);
        Assert.Contains("$env:ANTHROPIC_API_KEY = ''", body);
        if (!OperatingSystem.IsWindows()) Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(file));
    }

    [Fact]
    public void SweepRemovesStaleEnvFiles()
    {
        var stale = Path.Combine(dir, "env-old");
        var fresh = Path.Combine(dir, "env-new");
        var other = Path.Combine(dir, "prompt-1.md");
        foreach (var f in new[] { stale, fresh, other }) File.WriteAllText(f, "");
        File.SetLastWriteTimeUtc(stale, DateTime.UtcNow.AddHours(-1));
        File.SetLastWriteTimeUtc(other, DateTime.UtcNow.AddHours(-1));
        AgentEndpoints.Sweep(dir);
        Assert.False(File.Exists(stale));
        Assert.True(File.Exists(fresh));
        Assert.True(File.Exists(other));
    }
}
