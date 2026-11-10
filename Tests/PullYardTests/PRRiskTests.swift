import XCTest
@testable import PullYard

final class PRRiskTests: XCTestCase {
    private func f(_ path: String, _ a: Int = 1, _ d: Int = 1) -> RiskFile { RiskFile(path: path, additions: a, deletions: d) }

    func testClassifiesPaths() {
        XCTAssertEqual(PRRisk.kind(of: "db/migrate/20260101_add_users.rb"), .migrations)
        XCTAssertEqual(PRRisk.kind(of: "backend/app/migrations/0004_auto.py"), .migrations)
        XCTAssertEqual(PRRisk.kind(of: "prisma/migrations/1/migration.sql"), .migrations)
        XCTAssertEqual(PRRisk.kind(of: "db/schema.rb"), .migrations)
        XCTAssertEqual(PRRisk.kind(of: ".github/workflows/ci.yml"), .ci)
        XCTAssertEqual(PRRisk.kind(of: ".gitlab-ci.yml"), .ci)
        XCTAssertEqual(PRRisk.kind(of: "ios/fastlane/Fastfile"), .ci)
        XCTAssertEqual(PRRisk.kind(of: "Dockerfile.prod"), .infrastructure)
        XCTAssertEqual(PRRisk.kind(of: "infra/main.tf"), .infrastructure)
        XCTAssertEqual(PRRisk.kind(of: "package-lock.json"), .dependencies)
        XCTAssertEqual(PRRisk.kind(of: "app/pubspec.yaml"), .dependencies)
        XCTAssertEqual(PRRisk.kind(of: "Package.resolved"), .dependencies)
        XCTAssertEqual(PRRisk.kind(of: ".env.production"), .secrets)
        XCTAssertEqual(PRRisk.kind(of: "certs/server.pem"), .secrets)
        XCTAssertEqual(PRRisk.kind(of: "android/app/google-services.json"), .secrets)
        XCTAssertEqual(PRRisk.kind(of: ".github/CODEOWNERS"), .access)
        XCTAssertNil(PRRisk.kind(of: ".env.example"))
        XCTAssertNil(PRRisk.kind(of: "src/components/charts/Line.tsx"))
        XCTAssertNil(PRRisk.kind(of: "api/schema/user.graphql"))
        XCTAssertNil(PRRisk.kind(of: "Sources/App/Login.swift"))
    }

    func testLabelsGroupAndOrder() {
        let files = [f("src/a.swift"), f("package.json"), f("yarn.lock"), f(".github/workflows/ci.yml"), f("db/migrate/1.rb"), f(".env.local")]
        let labels = PRRisk.labels(files: files, additions: 6, deletions: 6, changedFiles: 6, unowned: nil)
        XCTAssertEqual(labels.map(\.kind), [.secrets, .migrations, .ci, .dependencies])
        XCTAssertEqual(labels.first { $0.kind == .dependencies }?.title, "Dependencies (2)")
        XCTAssertEqual(labels.first { $0.kind == .dependencies }?.files, ["package.json", "yarn.lock"])
        XCTAssertTrue(labels[0].strong)
        XCTAssertFalse(labels[3].strong)
    }

    func testSizeAndOwnership() {
        let deletion = PRRisk.labels(files: [f("old/a.swift", 10, 700), f("old/b.swift", 0, 50)], additions: 10, deletions: 750, changedFiles: 2, unowned: ["old/a.swift"])
        let big = deletion.first { $0.kind == .largeDeletion }
        XCTAssertEqual(big?.title, "Large deletion (−750)")
        XCTAssertEqual(big?.files, ["old/a.swift", "old/b.swift"])
        XCTAssertEqual(deletion.first { $0.kind == .unowned }?.title, "1 file without an owner")
        XCTAssertNil(deletion.first { $0.kind == .largeChange })

        let balanced = PRRisk.labels(files: [], additions: 900, deletions: 700, changedFiles: 12, unowned: [])
        XCTAssertEqual(balanced.map(\.kind), [.largeChange])
        XCTAssertEqual(balanced.first?.detail, "12 files, +900 −700. Consider reviewing it in parts")
        XCTAssertEqual(PRRisk.labels(files: [], additions: 1, deletions: 1, changedFiles: 60, unowned: nil).map(\.kind), [.largeChange])
        XCTAssertTrue(PRRisk.labels(files: [f("README.md")], additions: 3, deletions: 1, changedFiles: 1, unowned: nil).isEmpty)
    }

    func testConversationMarksUnresolvedThreads() throws {
        XCTAssertTrue(HTMLView.focusScript.contains("details.thread[data-unresolved]"))
    }
}
