import XCTest
@testable import PullYard

final class CodeOwnersTests: XCTestCase {
    private let sample = """
    # comment
    *       @global-owner1 @global-owner2
    *.js    @js-owner #This is an inline comment.
    *.go docs@example.com
    *.txt @octo-org/octocats
    /build/logs/ @doctocat
    docs/*  docs@example.com
    apps/ @octocat
    /docs/ @doctocat
    /scripts/ @doctocat @octocat
    **/logs @octocat
    /apps/ @octocat
    /apps/github
    /lib/features/chat/   @chat-owner
    \\#hash.md @hash-owner
    !negated @nobody
    [abc].md @nobody
    bad-owner notanowner
    """

    private var owners: CodeOwners { CodeOwners(text: sample) }

    func testLastMatchWins() {
        XCTAssertEqual(owners.owners(for: "README.md"), ["@global-owner1", "@global-owner2"])
        XCTAssertEqual(owners.owners(for: "src/app.js"), ["@js-owner"])
        XCTAssertEqual(owners.owners(for: "main.go"), ["docs@example.com"])
        XCTAssertEqual(owners.owners(for: "notes.txt"), ["@octo-org/octocats"])
    }

    func testDirectoryPatterns() {
        XCTAssertEqual(owners.owners(for: "build/logs/a/b.log"), ["@octocat"])
        XCTAssertEqual(owners.owners(for: "scripts/deploy.sh"), ["@doctocat", "@octocat"])
        XCTAssertEqual(owners.owners(for: "deeply/nested/logs/x.txt"), ["@octocat"])
        XCTAssertEqual(owners.owners(for: "lib/features/chat/view/chat_page.dart"), ["@chat-owner"])
        XCTAssertEqual(owners.owners(for: "other/lib/features/chat/x.dart"), ["@global-owner1", "@global-owner2"])
    }

    func testRootDocsAndSingleLevelWildcard() {
        XCTAssertEqual(owners.owners(for: "docs/getting-started.md"), ["@doctocat"])
        let onlyStar = CodeOwners(text: "docs/* @docs-team")
        XCTAssertEqual(onlyStar.owners(for: "docs/getting-started.md"), ["@docs-team"])
        XCTAssertEqual(onlyStar.owners(for: "docs/build-app/troubleshooting.md"), [])
    }

    func testRuleWithoutOwnersClearsOwnership() {
        XCTAssertEqual(owners.owners(for: "apps/github/main.swift"), [])
        XCTAssertEqual(owners.owners(for: "apps/other/main.swift"), ["@octocat"])
        XCTAssertNotNil(owners.rule(for: "apps/github/main.swift"))
    }

    func testEscapesAndUnsupportedSyntax() {
        XCTAssertEqual(owners.owners(for: "#hash.md"), ["@hash-owner"])
        XCTAssertEqual(owners.invalidLines.count, 3)
        XCTAssertEqual(owners.owners(for: "negated"), ["@global-owner1", "@global-owner2"])
    }

    func testUnanchoredFileNameAndDoubleStar() {
        let o = CodeOwners(text: "Makefile @make\nsrc/**/test_*.py @py\n")
        XCTAssertEqual(o.owners(for: "a/b/Makefile"), ["@make"])
        XCTAssertEqual(o.owners(for: "src/test_x.py"), ["@py"])
        XCTAssertEqual(o.owners(for: "src/a/b/test_x.py"), ["@py"])
        XCTAssertEqual(o.owners(for: "lib/src/test_x.py"), [])
    }

    func testSummaryGroupsAndStatuses() throws {
        let json = """
        {"id":"PR_1","number":1,"title":"T","url":"u","state":"OPEN","isDraft":false,"merged":false,"mergeable":"MERGEABLE",
         "body":"","bodyHTML":"","createdAt":"2026-01-01T00:00:00Z","headRefName":"f","baseRefName":"main","headRefOid":"h",
         "additions":1,"deletions":1,"changedFiles":3,"viewerCanUpdate":true,"viewerDidAuthor":true,
         "labels":{"nodes":[]},"assignees":{"nodes":[]},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"Octocats","combinedSlug":"octo-org/octocats"}}]},
         "latestOpinionatedReviews":{"nodes":[{"state":"APPROVED","author":{"login":"JS-Owner","avatarUrl":""}}]},
         "lastCommit":{"nodes":[]},"allCommits":{"nodes":[]},"timelineItems":{"nodes":[]},"reviewThreads":{"nodes":[]}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(PullRequestDetail.self, from: Data(json.utf8))
        let o = CodeOwners(text: "*.js @js-owner\n*.txt @octo-org/octocats\n/scripts/ @doctocat\n")
        let s = OwnershipSummary.build(owners: o, files: ["a.js", "b.txt", "scripts/run.sh", "README.md"], pr: pr)
        XCTAssertEqual(s.unowned, ["README.md"])
        XCTAssertEqual(s.groups.map { $0.owners.map(\.status) }, [[.approved], [.requested], [.notRequested]])
        XCTAssertTrue(s.groups[1].owners[0].isTeam)
        XCTAssertEqual(s.suggestions(excluding: []).map(\.handle), ["doctocat"])
        XCTAssertEqual(s.suggestions(excluding: ["doctocat"]).map(\.handle), [])
    }
}
