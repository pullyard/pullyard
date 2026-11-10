namespace PullYard.Core.Api;

public sealed record RiskFile(string Path, int Additions, int Deletions);

public enum RiskKind { Migrations, Ci, Infrastructure, Dependencies, Secrets, Access, LargeDeletion, LargeChange, Unowned }

public sealed record RiskLabel(RiskKind Kind, string Title, string Detail, List<string> Files)
{
    public bool Strong => Kind is RiskKind.Secrets or RiskKind.Migrations or RiskKind.Access;
}

public static class PRRisk
{
    public const int LargeChangeLines = 1500;
    public const int LargeChangeFiles = 50;
    public const int LargeDeletionLines = 500;

    private static readonly HashSet<string> LockFiles = new() { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb", "podfile.lock", "package.resolved", "cargo.lock", "go.sum", "poetry.lock", "pipfile.lock", "uv.lock", "gemfile.lock", "composer.lock", "pubspec.lock", "gradle.lockfile", "packages.lock.json", "flake.lock", "mix.lock" };
    private static readonly HashSet<string> Manifests = new() { "package.json", "podfile", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pipfile", "gemfile", "composer.json", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "mix.exs" };
    private static readonly HashSet<string> CiFiles = new() { ".gitlab-ci.yml", "bitbucket-pipelines.yml", "jenkinsfile", "azure-pipelines.yml", ".travis.yml", "codemagic.yaml", "appveyor.yml", ".drone.yml", "cloudbuild.yaml", "fastfile" };
    private static readonly string[] CiDirs = { ".github/workflows/", ".github/actions/", ".circleci/", ".buildkite/", ".gitlab/ci/", "fastlane/" };
    private static readonly HashSet<string> InfraFiles = new() { "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "chart.yaml", "values.yaml", "kustomization.yaml", "serverless.yml", "app.yaml", "fly.toml", "vercel.json", "netlify.toml", "procfile" };
    private static readonly string[] InfraDirs = { "terraform/", "infra/", "infrastructure/", "k8s/", "kubernetes/", "helm/", "deploy/", "deployment/", "ansible/" };
    private static readonly HashSet<string> InfraExts = new() { "tf", "tfvars", "hcl" };
    private static readonly string[] MigrationDirs = { "/migrations/", "/migrate/", "db/migrate/", "/alembic/", "/flyway/", "/liquibase/", "prisma/migrations/" };
    private static readonly HashSet<string> MigrationFiles = new() { "schema.rb", "structure.sql", "schema.prisma", "schema.sql" };
    private static readonly HashSet<string> SecretFiles = new() { ".env", "id_rsa", "id_ed25519", "credentials.json", "service-account.json", ".npmrc", ".pypirc", ".netrc", "secrets.yml", "secrets.yaml", "secrets.json", "google-services.json", "googleservice-info.plist" };
    private static readonly HashSet<string> SecretExts = new() { "pem", "key", "p12", "pfx", "jks", "keystore", "mobileprovision", "p8", "cer", "crt" };
    private static readonly HashSet<string> AccessFiles = new() { "codeowners", ".gitattributes", "dependabot.yml", "renovate.json", ".pre-commit-config.yaml" };

    public static List<RiskLabel> Labels(IReadOnlyList<RiskFile> files, int additions, int deletions, int changedFiles, IReadOnlyList<string>? unowned)
    {
        var groups = new Dictionary<RiskKind, List<string>>();
        foreach (var f in files)
        {
            if (KindOf(f.Path) is not { } kind) continue;
            if (!groups.TryGetValue(kind, out var list)) groups[kind] = list = new();
            list.Add(f.Path);
        }
        var output = new List<RiskLabel>();
        void Add(RiskKind kind, string title, string detail)
        {
            if (!groups.TryGetValue(kind, out var paths) || paths.Count == 0) return;
            output.Add(new RiskLabel(kind, $"{title} ({paths.Count})", detail, paths));
        }
        Add(RiskKind.Secrets, "Possible secrets", "Key, certificate or environment files changed. Make sure no credentials are committed");
        Add(RiskKind.Migrations, "Migrations", "Database schema or migration files changed. Check that they are reversible and safe to run on production data");
        Add(RiskKind.Access, "Repository rules", "CODEOWNERS or repository automation changed");
        Add(RiskKind.Ci, "CI config", "Build or deployment pipelines changed");
        Add(RiskKind.Infrastructure, "Infrastructure", "Containers, deployment or cloud configuration changed");
        Add(RiskKind.Dependencies, "Dependencies", "Package manifests or lock files changed");

        var removed = Math.Max(deletions, files.Sum(f => f.Deletions));
        var added = Math.Max(additions, files.Sum(f => f.Additions));
        if (removed >= LargeDeletionLines && removed > added * 2)
        {
            var biggest = files.Where(f => f.Deletions > 0).OrderByDescending(f => f.Deletions).Take(5).Select(f => f.Path).ToList();
            output.Add(new RiskLabel(RiskKind.LargeDeletion, $"Large deletion (−{removed})", "Much more code is removed than added", biggest));
        }
        var count = Math.Max(changedFiles, files.Count);
        if (added + removed >= LargeChangeLines || count >= LargeChangeFiles)
            output.Add(new RiskLabel(RiskKind.LargeChange, "Large change", $"{count} files, +{added} −{removed}. Consider reviewing it in parts", new()));
        if (unowned is { Count: > 0 })
            output.Add(new RiskLabel(RiskKind.Unowned, unowned.Count == 1 ? "1 file without an owner" : $"{unowned.Count} files without an owner", "No CODEOWNERS rule covers these files", unowned.ToList()));
        return output;
    }

    public static RiskKind? KindOf(string path)
    {
        var lower = path.ToLowerInvariant();
        var slash = lower.LastIndexOf('/');
        var name = slash >= 0 ? lower[(slash + 1)..] : lower;
        var dot = name.LastIndexOf('.');
        var ext = dot > 0 ? name[(dot + 1)..] : "";
        var padded = "/" + lower;
        bool UnderDir(string dir) => lower.StartsWith(dir, StringComparison.Ordinal) || padded.Contains("/" + dir, StringComparison.Ordinal);
        if (SecretFiles.Contains(name)
            || name.StartsWith(".env.", StringComparison.Ordinal) && !name.EndsWith(".example", StringComparison.Ordinal) && !name.EndsWith(".sample", StringComparison.Ordinal) && !name.EndsWith(".template", StringComparison.Ordinal)
            || SecretExts.Contains(ext))
            return RiskKind.Secrets;
        if (AccessFiles.Contains(name)) return RiskKind.Access;
        if (MigrationFiles.Contains(name) || MigrationDirs.Any(d => padded.Contains(d, StringComparison.Ordinal)) || ext == "sql") return RiskKind.Migrations;
        if (CiFiles.Contains(name) || CiDirs.Any(UnderDir)) return RiskKind.Ci;
        if (InfraFiles.Contains(name) || name.StartsWith("dockerfile", StringComparison.Ordinal) || InfraExts.Contains(ext) || InfraDirs.Any(UnderDir)) return RiskKind.Infrastructure;
        if (LockFiles.Contains(name) || Manifests.Contains(name)) return RiskKind.Dependencies;
        return null;
    }
}
