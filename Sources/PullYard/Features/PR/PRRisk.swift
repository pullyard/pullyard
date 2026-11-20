import SwiftUI

struct RiskFile: Equatable {
    let path: String
    let additions: Int
    let deletions: Int
}

struct RiskLabel: Identifiable, Equatable {
    enum Kind: String {
        case migrations, ci, infrastructure, dependencies, secrets, access, largeDeletion, largeChange, unowned
    }

    let kind: Kind
    let title: String
    let detail: String
    let files: [String]

    var id: String { kind.rawValue }

    var icon: String {
        switch kind {
        case .migrations: return "cylinder.split.1x2"
        case .ci: return "gearshape.2"
        case .infrastructure: return "server.rack"
        case .dependencies: return "shippingbox"
        case .secrets: return "key"
        case .access: return "person.badge.key"
        case .largeDeletion: return "minus.square"
        case .largeChange: return "square.stack.3d.up"
        case .unowned: return "person.crop.circle.badge.questionmark"
        }
    }

    var strong: Bool { kind == .secrets || kind == .migrations || kind == .access }
}

enum PRRisk {
    static let largeChangeLines = 1500
    static let largeChangeFiles = 50
    static let largeDeletionLines = 500

    private static let lockFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb", "podfile.lock", "package.resolved", "cargo.lock", "go.sum", "poetry.lock", "pipfile.lock", "uv.lock", "gemfile.lock", "composer.lock", "pubspec.lock", "gradle.lockfile", "packages.lock.json", "flake.lock", "mix.lock"]
    private static let manifests: Set<String> = ["package.json", "podfile", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pipfile", "gemfile", "composer.json", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "mix.exs"]
    private static let ciFiles: Set<String> = [".gitlab-ci.yml", "bitbucket-pipelines.yml", "jenkinsfile", "azure-pipelines.yml", ".travis.yml", "codemagic.yaml", "appveyor.yml", ".drone.yml", "cloudbuild.yaml", "fastfile"]
    private static let ciDirs = [".github/workflows/", ".github/actions/", ".circleci/", ".buildkite/", ".gitlab/ci/", "fastlane/"]
    private static let infraFiles: Set<String> = ["dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "chart.yaml", "values.yaml", "kustomization.yaml", "serverless.yml", "app.yaml", "fly.toml", "vercel.json", "netlify.toml", "procfile"]
    private static let infraDirs = ["terraform/", "infra/", "infrastructure/", "k8s/", "kubernetes/", "helm/", "deploy/", "deployment/", "ansible/"]
    private static let infraExts: Set<String> = ["tf", "tfvars", "hcl"]
    private static let migrationDirs = ["/migrations/", "/migrate/", "db/migrate/", "/alembic/", "/flyway/", "/liquibase/", "prisma/migrations/"]
    private static let migrationFiles: Set<String> = ["schema.rb", "structure.sql", "schema.prisma", "schema.sql"]
    private static let secretFiles: Set<String> = [".env", "id_rsa", "id_ed25519", "credentials.json", "service-account.json", ".npmrc", ".pypirc", ".netrc", "secrets.yml", "secrets.yaml", "secrets.json", "google-services.json", "googleservice-info.plist"]
    private static let secretExts: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "mobileprovision", "p8", "cer", "crt"]
    private static let accessFiles: Set<String> = ["codeowners", ".gitattributes", "dependabot.yml", "renovate.json", ".pre-commit-config.yaml"]

    static func labels(files: [RiskFile], additions: Int, deletions: Int, changedFiles: Int, unowned: [String]?) -> [RiskLabel] {
        var groups: [RiskLabel.Kind: [String]] = [:]
        for f in files {
            if let kind = kind(of: f.path) { groups[kind, default: []].append(f.path) }
        }
        var out: [RiskLabel] = []
        func add(_ kind: RiskLabel.Kind, _ title: String, _ detail: String) {
            guard let paths = groups[kind], !paths.isEmpty else { return }
            out.append(RiskLabel(kind: kind, title: "\(title) (\(paths.count))", detail: detail, files: paths))
        }
        add(.secrets, "Possible secrets", "Key, certificate or environment files changed. Make sure no credentials are committed")
        add(.migrations, "Migrations", "Database schema or migration files changed. Check that they are reversible and safe to run on production data")
        add(.access, "Repository rules", "CODEOWNERS or repository automation changed")
        add(.ci, "CI config", "Build or deployment pipelines changed")
        add(.infrastructure, "Infrastructure", "Containers, deployment or cloud configuration changed")
        add(.dependencies, "Dependencies", "Package manifests or lock files changed")

        let fileDeletions = files.reduce(0) { $0 + $1.deletions }
        let fileAdditions = files.reduce(0) { $0 + $1.additions }
        let removed = max(deletions, fileDeletions)
        let added = max(additions, fileAdditions)
        if removed >= largeDeletionLines, removed > added * 2 {
            let biggest = files.filter { $0.deletions > 0 }.sorted { $0.deletions > $1.deletions }.prefix(5).map(\.path)
            out.append(RiskLabel(kind: .largeDeletion, title: "Large deletion (−\(removed))", detail: "Much more code is removed than added", files: Array(biggest)))
        }
        let count = max(changedFiles, files.count)
        if added + removed >= largeChangeLines || count >= largeChangeFiles {
            out.append(RiskLabel(kind: .largeChange, title: "Large change", detail: "\(count) files, +\(added) −\(removed). Consider reviewing it in parts", files: []))
        }
        if let unowned, !unowned.isEmpty {
            out.append(RiskLabel(kind: .unowned, title: unowned.count == 1 ? "1 file without an owner" : "\(unowned.count) files without an owner", detail: "No CODEOWNERS rule covers these files", files: unowned))
        }
        return out
    }

    static func kind(of path: String) -> RiskLabel.Kind? {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let padded = "/" + lower
        if secretFiles.contains(name) || name.hasPrefix(".env.") && !name.hasSuffix(".example") && !name.hasSuffix(".sample") && !name.hasSuffix(".template") || secretExts.contains(ext) {
            return .secrets
        }
        if accessFiles.contains(name) { return .access }
        if migrationFiles.contains(name) || migrationDirs.contains(where: { padded.contains($0) }) || ext == "sql" { return .migrations }
        if ciFiles.contains(name) || ciDirs.contains(where: { lower.hasPrefix($0) || padded.contains("/" + $0) }) { return .ci }
        if infraFiles.contains(name) || name.hasPrefix("dockerfile") || infraExts.contains(ext) || infraDirs.contains(where: { lower.hasPrefix($0) || padded.contains("/" + $0) }) { return .infrastructure }
        if lockFiles.contains(name) || manifests.contains(name) { return .dependencies }
        return nil
    }
}

struct RiskStrip: View {
    let model: PRDetailModel
    let risks: [RiskLabel]

    var body: some View {
        if !risks.isEmpty {
            HStack(spacing: 6) {
                Text("Look closer:").font(.syCaption).foregroundStyle(Color.syMuted)
                ForEach(risks) { r in
                    Button {
                        if let first = r.files.first {
                            model.revealFile(first)
                            Task { await model.loadFiles() }
                        }
                    } label: {
                        Label(r.title, systemImage: r.icon)
                            .font(.syCaption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((r.strong ? Color.ghYellow : Color.syMuted).opacity(Tint.banner)))
                            .foregroundStyle(r.strong ? Color.syText : Color.syMuted)
                    }
                    .buttonStyle(.plain)
                    .help(r.detail + (r.files.isEmpty ? "" : "\n\n" + r.files.prefix(12).joined(separator: "\n") + (r.files.count > 12 ? "\n…and \(r.files.count - 12) more" : "")))
                    .accessibilityLabel(r.title)
                    .accessibilityHint(r.detail)
                }
            }
            .lineLimit(1)
        }
    }
}
