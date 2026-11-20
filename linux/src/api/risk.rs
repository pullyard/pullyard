#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RiskFile {
    pub path: String,
    pub additions: i64,
    pub deletions: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RiskKind {
    Migrations,
    Ci,
    Infrastructure,
    Dependencies,
    Secrets,
    Access,
    LargeDeletion,
    LargeChange,
    Unowned,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RiskLabel {
    pub kind: RiskKind,
    pub title: String,
    pub detail: String,
    pub files: Vec<String>,
}

impl RiskLabel {
    pub fn icon(&self) -> &'static str {
        match self.kind {
            RiskKind::Migrations => "sy-archive-symbolic",
            RiskKind::Ci => "sy-bolt-symbolic",
            RiskKind::Infrastructure => "sy-terminal-symbolic",
            RiskKind::Dependencies => "sy-folder-symbolic",
            RiskKind::Secrets => "sy-key-symbolic",
            RiskKind::Access => "sy-lock-symbolic",
            RiskKind::LargeDeletion => "sy-plusminus-symbolic",
            RiskKind::LargeChange => "sy-stack-symbolic",
            RiskKind::Unowned => "sy-person-symbolic",
        }
    }

    pub fn strong(&self) -> bool {
        matches!(self.kind, RiskKind::Secrets | RiskKind::Migrations | RiskKind::Access)
    }

    pub fn tooltip(&self) -> String {
        if self.files.is_empty() {
            return self.detail.clone();
        }
        let mut out = format!("{}\n\n{}", self.detail, self.files.iter().take(12).cloned().collect::<Vec<_>>().join("\n"));
        if self.files.len() > 12 {
            out.push_str(&format!("\n…and {} more", self.files.len() - 12));
        }
        out
    }
}

pub const LARGE_CHANGE_LINES: i64 = 1500;
pub const LARGE_CHANGE_FILES: i64 = 50;
pub const LARGE_DELETION_LINES: i64 = 500;

const LOCK_FILES: &[&str] = &["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb", "podfile.lock", "package.resolved", "cargo.lock", "go.sum", "poetry.lock", "pipfile.lock", "uv.lock", "gemfile.lock", "composer.lock", "pubspec.lock", "gradle.lockfile", "packages.lock.json", "flake.lock", "mix.lock"];
const MANIFESTS: &[&str] = &["package.json", "podfile", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pipfile", "gemfile", "composer.json", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "mix.exs"];
const CI_FILES: &[&str] = &[".gitlab-ci.yml", "bitbucket-pipelines.yml", "jenkinsfile", "azure-pipelines.yml", ".travis.yml", "codemagic.yaml", "appveyor.yml", ".drone.yml", "cloudbuild.yaml", "fastfile"];
const CI_DIRS: &[&str] = &[".github/workflows/", ".github/actions/", ".circleci/", ".buildkite/", ".gitlab/ci/", "fastlane/"];
const INFRA_FILES: &[&str] = &["dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "chart.yaml", "values.yaml", "kustomization.yaml", "serverless.yml", "app.yaml", "fly.toml", "vercel.json", "netlify.toml", "procfile"];
const INFRA_DIRS: &[&str] = &["terraform/", "infra/", "infrastructure/", "k8s/", "kubernetes/", "helm/", "deploy/", "deployment/", "ansible/"];
const INFRA_EXTS: &[&str] = &["tf", "tfvars", "hcl"];
const MIGRATION_DIRS: &[&str] = &["/migrations/", "/migrate/", "db/migrate/", "/alembic/", "/flyway/", "/liquibase/", "prisma/migrations/"];
const MIGRATION_FILES: &[&str] = &["schema.rb", "structure.sql", "schema.prisma", "schema.sql"];
const SECRET_FILES: &[&str] = &[".env", "id_rsa", "id_ed25519", "credentials.json", "service-account.json", ".npmrc", ".pypirc", ".netrc", "secrets.yml", "secrets.yaml", "secrets.json", "google-services.json", "googleservice-info.plist"];
const SECRET_EXTS: &[&str] = &["pem", "key", "p12", "pfx", "jks", "keystore", "mobileprovision", "p8", "cer", "crt"];
const ACCESS_FILES: &[&str] = &["codeowners", ".gitattributes", "dependabot.yml", "renovate.json", ".pre-commit-config.yaml"];

fn extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) if i > 0 => &name[i + 1..],
        _ => "",
    }
}

pub fn kind_of(path: &str) -> Option<RiskKind> {
    let lower = path.to_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);
    let ext = extension(name);
    let padded = format!("/{lower}");
    let in_dir = |dirs: &[&str]| dirs.iter().any(|d| lower.starts_with(d) || padded.contains(&format!("/{d}")));
    let env_file = name.starts_with(".env.") && !name.ends_with(".example") && !name.ends_with(".sample") && !name.ends_with(".template");
    if SECRET_FILES.contains(&name) || env_file || SECRET_EXTS.contains(&ext) {
        return Some(RiskKind::Secrets);
    }
    if ACCESS_FILES.contains(&name) {
        return Some(RiskKind::Access);
    }
    if MIGRATION_FILES.contains(&name) || MIGRATION_DIRS.iter().any(|d| padded.contains(d)) || ext == "sql" {
        return Some(RiskKind::Migrations);
    }
    if CI_FILES.contains(&name) || in_dir(CI_DIRS) {
        return Some(RiskKind::Ci);
    }
    if INFRA_FILES.contains(&name) || name.starts_with("dockerfile") || INFRA_EXTS.contains(&ext) || in_dir(INFRA_DIRS) {
        return Some(RiskKind::Infrastructure);
    }
    if LOCK_FILES.contains(&name) || MANIFESTS.contains(&name) {
        return Some(RiskKind::Dependencies);
    }
    None
}

pub fn labels(files: &[RiskFile], additions: i64, deletions: i64, changed_files: i64, unowned: Option<&[String]>) -> Vec<RiskLabel> {
    let mut groups: Vec<(RiskKind, Vec<String>)> = vec![];
    for f in files {
        if let Some(kind) = kind_of(&f.path) {
            match groups.iter_mut().find(|(k, _)| *k == kind) {
                Some((_, paths)) => paths.push(f.path.clone()),
                None => groups.push((kind, vec![f.path.clone()])),
            }
        }
    }
    let mut out = vec![];
    let mut add = |kind: RiskKind, title: &str, detail: &str| {
        if let Some((_, paths)) = groups.iter().find(|(k, _)| *k == kind).filter(|(_, p)| !p.is_empty()) {
            out.push(RiskLabel { kind, title: format!("{title} ({})", paths.len()), detail: detail.to_string(), files: paths.clone() });
        }
    };
    add(RiskKind::Secrets, "Possible secrets", "Key, certificate or environment files changed. Make sure no credentials are committed");
    add(RiskKind::Migrations, "Migrations", "Database schema or migration files changed. Check that they are reversible and safe to run on production data");
    add(RiskKind::Access, "Repository rules", "CODEOWNERS or repository automation changed");
    add(RiskKind::Ci, "CI config", "Build or deployment pipelines changed");
    add(RiskKind::Infrastructure, "Infrastructure", "Containers, deployment or cloud configuration changed");
    add(RiskKind::Dependencies, "Dependencies", "Package manifests or lock files changed");

    let removed = deletions.max(files.iter().map(|f| f.deletions).sum());
    let added = additions.max(files.iter().map(|f| f.additions).sum());
    if removed >= LARGE_DELETION_LINES && removed > added * 2 {
        let mut biggest: Vec<&RiskFile> = files.iter().filter(|f| f.deletions > 0).collect();
        biggest.sort_by(|a, b| b.deletions.cmp(&a.deletions));
        out.push(RiskLabel {
            kind: RiskKind::LargeDeletion,
            title: format!("Large deletion (−{removed})"),
            detail: "Much more code is removed than added".into(),
            files: biggest.into_iter().take(5).map(|f| f.path.clone()).collect(),
        });
    }
    let count = changed_files.max(files.len() as i64);
    if added + removed >= LARGE_CHANGE_LINES || count >= LARGE_CHANGE_FILES {
        out.push(RiskLabel { kind: RiskKind::LargeChange, title: "Large change".into(), detail: format!("{count} files, +{added} −{removed}. Consider reviewing it in parts"), files: vec![] });
    }
    if let Some(unowned) = unowned.filter(|u| !u.is_empty()) {
        out.push(RiskLabel {
            kind: RiskKind::Unowned,
            title: if unowned.len() == 1 { "1 file without an owner".into() } else { format!("{} files without an owner", unowned.len()) },
            detail: "No CODEOWNERS rule covers these files".into(),
            files: unowned.to_vec(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(path: &str, a: i64, d: i64) -> RiskFile {
        RiskFile { path: path.into(), additions: a, deletions: d }
    }

    fn kinds(labels: &[RiskLabel]) -> Vec<RiskKind> {
        labels.iter().map(|l| l.kind).collect()
    }

    #[test]
    fn classifies_paths() {
        assert_eq!(kind_of("db/migrate/20260101_add_users.rb"), Some(RiskKind::Migrations));
        assert_eq!(kind_of("backend/app/migrations/0004_auto.py"), Some(RiskKind::Migrations));
        assert_eq!(kind_of("prisma/migrations/1/migration.sql"), Some(RiskKind::Migrations));
        assert_eq!(kind_of("db/schema.rb"), Some(RiskKind::Migrations));
        assert_eq!(kind_of(".github/workflows/ci.yml"), Some(RiskKind::Ci));
        assert_eq!(kind_of(".gitlab-ci.yml"), Some(RiskKind::Ci));
        assert_eq!(kind_of("ios/fastlane/Fastfile"), Some(RiskKind::Ci));
        assert_eq!(kind_of("Dockerfile.prod"), Some(RiskKind::Infrastructure));
        assert_eq!(kind_of("infra/main.tf"), Some(RiskKind::Infrastructure));
        assert_eq!(kind_of("package-lock.json"), Some(RiskKind::Dependencies));
        assert_eq!(kind_of("app/pubspec.yaml"), Some(RiskKind::Dependencies));
        assert_eq!(kind_of("Package.resolved"), Some(RiskKind::Dependencies));
        assert_eq!(kind_of(".env.production"), Some(RiskKind::Secrets));
        assert_eq!(kind_of("certs/server.pem"), Some(RiskKind::Secrets));
        assert_eq!(kind_of("android/app/google-services.json"), Some(RiskKind::Secrets));
        assert_eq!(kind_of(".github/CODEOWNERS"), Some(RiskKind::Access));
        assert_eq!(kind_of(".env.example"), None);
        assert_eq!(kind_of("src/components/charts/Line.tsx"), None);
        assert_eq!(kind_of("api/schema/user.graphql"), None);
        assert_eq!(kind_of("Sources/App/Login.swift"), None);
    }

    #[test]
    fn labels_group_and_order() {
        let files = [f("src/a.swift", 1, 1), f("package.json", 1, 1), f("yarn.lock", 1, 1), f(".github/workflows/ci.yml", 1, 1), f("db/migrate/1.rb", 1, 1), f(".env.local", 1, 1)];
        let labels = labels(&files, 6, 6, 6, None);
        assert_eq!(kinds(&labels), vec![RiskKind::Secrets, RiskKind::Migrations, RiskKind::Ci, RiskKind::Dependencies]);
        let deps = labels.iter().find(|l| l.kind == RiskKind::Dependencies).unwrap();
        assert_eq!(deps.title, "Dependencies (2)");
        assert_eq!(deps.files, vec!["package.json".to_string(), "yarn.lock".to_string()]);
        assert!(labels[0].strong());
        assert!(!labels[3].strong());
    }

    #[test]
    fn size_and_ownership() {
        let unowned = vec!["old/a.swift".to_string()];
        let deletion = labels(&[f("old/a.swift", 10, 700), f("old/b.swift", 0, 50)], 10, 750, 2, Some(&unowned));
        let big = deletion.iter().find(|l| l.kind == RiskKind::LargeDeletion).unwrap();
        assert_eq!(big.title, "Large deletion (−750)");
        assert_eq!(big.files, vec!["old/a.swift".to_string(), "old/b.swift".to_string()]);
        assert_eq!(deletion.iter().find(|l| l.kind == RiskKind::Unowned).unwrap().title, "1 file without an owner");
        assert!(!deletion.iter().any(|l| l.kind == RiskKind::LargeChange));

        let balanced = labels(&[], 900, 700, 12, Some(&[]));
        assert_eq!(kinds(&balanced), vec![RiskKind::LargeChange]);
        assert_eq!(balanced[0].detail, "12 files, +900 −700. Consider reviewing it in parts");
        assert_eq!(kinds(&labels(&[], 1, 1, 60, None)), vec![RiskKind::LargeChange]);
        assert!(labels(&[f("README.md", 3, 1)], 3, 1, 1, None).is_empty());
    }

    #[test]
    fn tooltip_lists_up_to_twelve_files() {
        let files: Vec<String> = (0..14).map(|i| format!("f{i}")).collect();
        let l = RiskLabel { kind: RiskKind::Unowned, title: String::new(), detail: "d".into(), files };
        let t = l.tooltip();
        assert!(t.starts_with("d\n\nf0\n"));
        assert!(t.contains("f11"));
        assert!(!t.contains("f12"));
        assert!(t.ends_with("…and 2 more"));
    }
}
