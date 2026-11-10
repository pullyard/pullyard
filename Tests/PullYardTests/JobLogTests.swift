import XCTest
@testable import PullYard

@MainActor
final class JobLogTests: XCTestCase {
    override func setUp() {
        StubProtocol.routes = [:]
        StubProtocol.queryRoutes = []
        StubProtocol.requests = []
        ForgeHTTP.protocolClasses = [StubProtocol.self]
    }

    override func tearDown() {
        ForgeHTTP.protocolClasses = []
    }

    private func check(_ typename: String, id: Int?, conclusion: String? = "FAILURE", link: String? = nil) -> CheckContext {
        CheckContext(typename: typename, databaseId: id, name: "unit", status: conclusion == nil ? "IN_PROGRESS" : "COMPLETED", conclusion: conclusion,
                     detailsUrl: link, startedAt: nil, completedAt: nil, checkSuite: nil, context: nil, state: nil, targetUrl: nil, description: nil)
    }

    func testGitLabTraceCleanup() {
        let raw = "section_start:1700000000:prepare_script\r\u{1B}[0K\u{1B}[0K\u{1B}[36;1mPreparing\u{1B}[0;m\nprogress 10%\rprogress 100%\n\u{1B}[31mERROR: tests failed\u{1B}[0m\nsection_end:1700000001:prepare_script\r\u{1B}[0K"
        XCTAssertEqual(GitLabReviewMapper.cleanTrace(raw), "Preparing\nprogress 100%\nERROR: tests failed\n")
    }

    func testGitLabJobLog() async throws {
        StubProtocol.routes = ["/jobs/3/trace": (200, "line one\nERROR boom")]
        let account = GitAccount(id: "t", provider: .gitlab, host: "gitlab.example.com", login: "s", email: nil, userID: nil, keychainKey: "t")
        let backend = GitLabPRBackend(client: GitLabClient(account: account, credential: GitCredential(token: "x")))
        let ref = ItemRef(repo: RepoRef(owner: "group", name: "app"), number: 1)
        XCTAssertTrue(backend.canShowLog(check("GitLabJob", id: 3)))
        XCTAssertFalse(backend.canShowLog(check("GitLabJob", id: 3, conclusion: nil)))
        XCTAssertFalse(backend.canShowLog(check("CheckRun", id: 3)))
        let log = try await backend.jobLog(ref, check: check("GitLabJob", id: 3))
        XCTAssertEqual(log, "line one\nERROR boom")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Accept"), "text/plain")
    }

    func testBitbucketBuildNumber() {
        XCTAssertEqual(BitbucketClient.buildNumber("https://bitbucket.org/acme/api/pipelines/results/42"), 42)
        XCTAssertEqual(BitbucketClient.buildNumber("https://bitbucket.org/acme/api/addon/pipelines/home#!/results/7"), 7)
        XCTAssertNil(BitbucketClient.buildNumber("https://ci.example.com/build/9"))
        XCTAssertNil(BitbucketClient.buildNumber(nil))
    }

    func testBitbucketPipelineLog() async throws {
        StubProtocol.routes = [
            "/pipelines/42": (200, #"{"uuid":"{p-1}","build_number":42,"state":{"name":"COMPLETED","result":{"name":"FAILED"}}}"#),
            "/steps": (200, #"{"values":[{"uuid":"{s-1}","name":"Build","state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},{"uuid":"{s-2}","name":"Test","state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}"#),
            "/steps/{s-1}/log": (200, "compiled\n"),
            "/steps/{s-2}/log": (200, "\u{1B}[31mFAIL\u{1B}[0m test_a\n")
        ]
        let account = GitAccount(id: "t", provider: .bitbucket, host: "bitbucket.org", login: "s", email: "s@x", userID: "{u}", keychainKey: "t")
        let backend = BitbucketPRBackend(client: BitbucketClient(account: account, credential: GitCredential(token: "t")))
        let ref = ItemRef(repo: RepoRef(owner: "acme", name: "api"), number: 5)
        let build = check("BitbucketStatus", id: 1, link: "https://bitbucket.org/acme/api/pipelines/results/42")
        XCTAssertTrue(backend.canShowLog(build))
        XCTAssertFalse(backend.canShowLog(check("BitbucketStatus", id: 1, link: "https://ci.example.com/9")))
        let log = try await backend.jobLog(ref, check: build)
        XCTAssertEqual(log, "=== Build (successful) ===\ncompiled\n\n=== Test (failed) ===\nFAIL test_a")
    }

    func testGitHubOnlyShowsActionsJobs() {
        let api = GitHubAPI(token: "x")
        let backend = GitHubPRBackend(api: api)
        let job = CheckContext(typename: "CheckRun", databaseId: 5, name: "build", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: nil, startedAt: nil, completedAt: nil,
                               checkSuite: CheckSuite(workflowRun: WorkflowRun(databaseId: 9, workflow: WorkflowInfo(name: "CI"))), context: nil, state: nil, targetUrl: nil, description: nil)
        XCTAssertTrue(backend.canShowLog(job))
        XCTAssertFalse(backend.canShowLog(check("StatusContext", id: nil)))
    }
}
