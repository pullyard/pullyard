using PullYard.Core.Api;
using PullYard.Core.Html;
using Xunit;

namespace PullYard.Core.Tests;

public class PRRiskTests
{
    private static RiskFile F(string path, int a = 1, int d = 1) => new(path, a, d);

    [Theory]
    [InlineData("db/migrate/20260101_add_users.rb", RiskKind.Migrations)]
    [InlineData("backend/app/migrations/0004_auto.py", RiskKind.Migrations)]
    [InlineData("prisma/migrations/1/migration.sql", RiskKind.Migrations)]
    [InlineData("db/schema.rb", RiskKind.Migrations)]
    [InlineData(".github/workflows/ci.yml", RiskKind.Ci)]
    [InlineData(".gitlab-ci.yml", RiskKind.Ci)]
    [InlineData("ios/fastlane/Fastfile", RiskKind.Ci)]
    [InlineData("Dockerfile.prod", RiskKind.Infrastructure)]
    [InlineData("infra/main.tf", RiskKind.Infrastructure)]
    [InlineData("package-lock.json", RiskKind.Dependencies)]
    [InlineData("app/pubspec.yaml", RiskKind.Dependencies)]
    [InlineData("Package.resolved", RiskKind.Dependencies)]
    [InlineData(".env.production", RiskKind.Secrets)]
    [InlineData("certs/server.pem", RiskKind.Secrets)]
    [InlineData("android/app/google-services.json", RiskKind.Secrets)]
    [InlineData(".github/CODEOWNERS", RiskKind.Access)]
    public void ClassifiesPaths(string path, RiskKind kind) => Assert.Equal(kind, PRRisk.KindOf(path));

    [Theory]
    [InlineData(".env.example")]
    [InlineData("src/components/charts/Line.tsx")]
    [InlineData("api/schema/user.graphql")]
    [InlineData("Sources/App/Login.swift")]
    public void IgnoresOrdinaryPaths(string path) => Assert.Null(PRRisk.KindOf(path));

    [Fact]
    public void LabelsGroupAndOrder()
    {
        var files = new[] { F("src/a.swift"), F("package.json"), F("yarn.lock"), F(".github/workflows/ci.yml"), F("db/migrate/1.rb"), F(".env.local") };
        var labels = PRRisk.Labels(files, 6, 6, 6, null);
        Assert.Equal(new[] { RiskKind.Secrets, RiskKind.Migrations, RiskKind.Ci, RiskKind.Dependencies }, labels.Select(l => l.Kind));
        var deps = labels.First(l => l.Kind == RiskKind.Dependencies);
        Assert.Equal("Dependencies (2)", deps.Title);
        Assert.Equal(new[] { "package.json", "yarn.lock" }, deps.Files);
        Assert.True(labels[0].Strong);
        Assert.False(labels[3].Strong);
    }

    [Fact]
    public void SizeAndOwnership()
    {
        var deletion = PRRisk.Labels(new[] { F("old/a.swift", 10, 700), F("old/b.swift", 0, 50) }, 10, 750, 2, new[] { "old/a.swift" });
        var big = deletion.FirstOrDefault(l => l.Kind == RiskKind.LargeDeletion);
        Assert.Equal("Large deletion (−750)", big?.Title);
        Assert.Equal(new[] { "old/a.swift", "old/b.swift" }, big?.Files);
        Assert.Equal("1 file without an owner", deletion.FirstOrDefault(l => l.Kind == RiskKind.Unowned)?.Title);
        Assert.DoesNotContain(deletion, l => l.Kind == RiskKind.LargeChange);

        var balanced = PRRisk.Labels(Array.Empty<RiskFile>(), 900, 700, 12, Array.Empty<string>());
        Assert.Equal(new[] { RiskKind.LargeChange }, balanced.Select(l => l.Kind));
        Assert.Equal("12 files, +900 −700. Consider reviewing it in parts", balanced[0].Detail);
        Assert.Equal(new[] { RiskKind.LargeChange }, PRRisk.Labels(Array.Empty<RiskFile>(), 1, 1, 60, null).Select(l => l.Kind));
        Assert.Empty(PRRisk.Labels(new[] { F("README.md") }, 3, 1, 1, null));
    }

    [Fact]
    public void ConversationMarksUnresolvedThreads()
    {
        Assert.Contains("data-unresolved", ConversationHtml.Thread(new ReviewThread { Id = "a", Path = "a.cs" }));
        Assert.DoesNotContain("data-unresolved", ConversationHtml.Thread(new ReviewThread { Id = "b", Path = "a.cs", IsResolved = true }));
        Assert.Contains(".thread.focus", ConversationHtml.Css);
    }
}
