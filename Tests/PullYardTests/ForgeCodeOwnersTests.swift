import XCTest
@testable import PullYard

@MainActor
final class ForgeCodeOwnersTests: XCTestCase {
    override func setUp() {
        StubProtocol.routes = [:]
        StubProtocol.queryRoutes = []
        StubProtocol.requests = []
        ForgeHTTP.protocolClasses = [StubProtocol.self]
    }

    override func tearDown() {
        ForgeHTTP.protocolClasses = []
    }

    private let gitlabText = """
    * @everyone
    [Backend] @backend-team
    app/
    app/billing/ @billing @alice
    ^[Docs][2] @docs/writers
    *.md
    [Security]
    app/auth/ @security
    """

    func testGitLabSectionsUnionOwners() {
        let o = CodeOwners(text: gitlabText, path: "CODEOWNERS", flavor: .gitlab)
        XCTAssertTrue(o.invalidLines.isEmpty)
        XCTAssertEqual(o.owners(for: "app/billing/pay.rb"), ["@everyone", "@billing", "@alice"])
        XCTAssertEqual(o.owners(for: "app/models/user.rb"), ["@everyone", "@backend-team"])
        XCTAssertEqual(o.owners(for: "app/README.md"), ["@everyone", "@backend-team", "@docs/writers"])
        XCTAssertEqual(o.owners(for: "app/auth/login.rb"), ["@everyone", "@backend-team", "@security"])
        XCTAssertEqual(o.owners(for: "Gemfile"), ["@everyone"])

        let github = CodeOwners(text: gitlabText)
        XCTAssertFalse(github.invalidLines.isEmpty)
        XCTAssertEqual(CodeOwners.sectionHeader("^[Docs][2] @docs/writers"), ["@docs/writers"])
        XCTAssertEqual(CodeOwners.sectionHeader("[Security]"), [])
        XCTAssertNil(CodeOwners.sectionHeader("app/ @x"))
        XCTAssertNil(CodeOwners.sectionHeader("[]"))
    }

    func testGitLabBackendReadsFirstExistingFile() async throws {
        StubProtocol.routes = [
            "/repository/files/docs/CODEOWNERS/raw": (200, "[Docs] @writers\n*.md\n")
        ]
        let account = GitAccount(id: "t", provider: .gitlab, host: "gitlab.example.com", login: "s", email: nil, userID: nil, keychainKey: "t")
        let backend = GitLabPRBackend(client: GitLabClient(account: account, credential: GitCredential(token: "x")))
        let owners = try await backend.codeOwners(ItemRef(repo: RepoRef(owner: "group", name: "app"), number: 1), base: "base1")
        XCTAssertEqual(owners?.path, "docs/CODEOWNERS")
        XCTAssertEqual(owners?.flavor, .gitlab)
        XCTAssertEqual(owners?.owners(for: "README.md"), ["@writers"])
        let urls = StubProtocol.requests.compactMap { $0.url?.absoluteString }
        XCTAssertTrue(urls.contains { $0.contains("files/CODEOWNERS/raw?ref=base1") })
        XCTAssertTrue(urls.contains { $0.contains("files/docs%2FCODEOWNERS/raw?ref=base1") })
        XCTAssertFalse(urls.contains { $0.contains(".gitlab") })
    }

    func testBitbucketBackendAndMissingFile() async throws {
        StubProtocol.routes = ["/src/base9/.bitbucket/CODEOWNERS": (200, "src/ @acme/core\n")]
        let account = GitAccount(id: "t", provider: .bitbucket, host: "bitbucket.org", login: "s", email: "s@x", userID: "{u}", keychainKey: "t")
        let backend = BitbucketPRBackend(client: BitbucketClient(account: account, credential: GitCredential(token: "t")))
        let ref = ItemRef(repo: RepoRef(owner: "acme", name: "api"), number: 5)
        let owners = try await backend.codeOwners(ref, base: "base9")
        XCTAssertEqual(owners?.path, ".bitbucket/CODEOWNERS")
        XCTAssertEqual(owners?.owners(for: "src/a.swift"), ["@acme/core"])
        StubProtocol.routes = [:]
        let none = try await backend.codeOwners(ref, base: "base9")
        XCTAssertNil(none)
    }

    func testOwnersOfFile() throws {
        let json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main", "headRefOid": "h",
            "additions": 1, "deletions": 1, "changedFiles": 2, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []], "reviewRequests": ["nodes": []],
            "latestOpinionatedReviews": ["nodes": [["state": "APPROVED", "author": ["login": "alice", "avatarUrl": ""]]]],
            "lastCommit": ["nodes": []], "allCommits": ["nodes": []], "timelineItems": ["nodes": []], "reviewThreads": ["nodes": []]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
        let summary = OwnershipSummary.build(owners: CodeOwners(text: "app/ @alice @bob"), files: ["app/a.rb", "README.md"], pr: pr)
        XCTAssertEqual(summary.owners(of: "app/a.rb")?.map(\.handle), ["alice", "bob"])
        XCTAssertEqual(summary.owners(of: "app/a.rb")?.first?.status, .approved)
        XCTAssertNil(summary.owners(of: "README.md"))
        XCTAssertEqual(summary.unowned, ["README.md"])
    }
}
