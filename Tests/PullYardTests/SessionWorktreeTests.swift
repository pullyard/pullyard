import XCTest
@testable import PullYard

final class SessionWorktreeTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.appendingPathComponent("app").path }

    @discardableResult
    private func git(_ args: [String], in dir: String) throws -> String {
        try PRWorktrees.git(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo + "/ios/App", withIntermediateDirectories: true)
        try git(["init", "--quiet", "-b", "main"], in: repo)
        try "a".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: repo + "/ios/App/x.swift", atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "--quiet", "-m", "base"], in: repo)
        try git(["checkout", "--quiet", "-b", "develop"], in: repo)
        try "d".write(toFile: repo + "/d.txt", atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "--quiet", "-m", "develop work"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func create(from folder: String, title: String) async throws -> String {
        switch await SessionWorktree.create(from: folder, title: title) {
        case .success(let path): return path
        case .failure(let error): throw error
        }
    }

    // MARK: slug

    func testSlugFromEnglishTitle() {
        XCTAssertEqual(SessionWorktree.slug("Second test"), "second-test")
        XCTAssertEqual(SessionWorktree.slug("Fix login crash on iOS 18!"), "fix-login-crash-on-ios")
    }

    func testSlugTransliteratesRussian() {
        let slug = SessionWorktree.slug("Падение приложения при открытии видео")
        XCTAssertTrue(slug.hasPrefix("padenie-prilozenia"), slug)
        XCTAssertTrue(slug.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }, slug)
    }

    func testSlugIsBoundedAndNeverEmpty() {
        XCTAssertEqual(SessionWorktree.slug("!!! ???"), "session")
        XCTAssertEqual(SessionWorktree.slug(""), "session")
        let long = SessionWorktree.slug("one two three four five six seven eight")
        XCTAssertEqual(long, "one-two-three-four-five")
        XCTAssertLessThanOrEqual(SessionWorktree.slug(String(repeating: "abcdefghij", count: 10)).count, 40)
        XCTAssertFalse(SessionWorktree.slug(String(repeating: "abcdefghij", count: 10)).hasSuffix("-"))
    }

    // MARK: titles

    func testCleansModelReplies() {
        XCTAssertEqual(SessionTitler.clean("Second test\n"), "Second test")
        XCTAssertEqual(SessionTitler.clean("\"Fix the build.\""), "Fix the build")
        XCTAssertEqual(SessionTitler.clean("Title: refactor sidebar"), "Refactor sidebar")
        XCTAssertEqual(SessionTitler.clean("**Jira video crash**\nmore text"), "Jira video crash")
        XCTAssertNil(SessionTitler.clean("   "))
        XCTAssertNil(SessionTitler.clean(String(repeating: "word ", count: 30)))
    }

    func testFallbackTitleUsesFirstWords() {
        XCTAssertEqual(SessionTitler.fallback("second test"), "Second test")
        XCTAssertEqual(SessionTitler.fallback("почему падает апп когда открываю видео в jira"), "Почему падает апп когда открываю видео")
        XCTAssertEqual(SessionTitler.fallback("   "), "New session")
    }

    // MARK: worktrees

    func testCreatesWorktreeFromCurrentBranchUnderParentProject() async throws {
        let path = try await create(from: repo, title: "Second test")
        let name = (path as NSString).lastPathComponent
        XCTAssertTrue(name.hasPrefix("second-test-"), name)
        XCTAssertEqual(name.count, "second-test-".count + 6)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path,
                       URL(fileURLWithPath: repo).appendingPathComponent(".claude/worktrees").path)
        XCTAssertEqual(try git(["branch", "--show-current"], in: path), "claude/" + name)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: path), try git(["rev-parse", "develop"], in: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/d.txt"))
        XCTAssertEqual(try git(["branch", "--show-current"], in: repo), "develop")
        XCTAssertEqual(try git(["status", "--porcelain"], in: repo), "", "worktree folder must be git-excluded")
        XCTAssertEqual(ProjectRoot.of(path), repo)
        XCTAssertEqual(ClaudeSessionParser.projectRoot(for: path), repo)
        XCTAssertTrue(SessionWorktree.isWorktree(path))
    }

    func testKeepsSubfolderOfTheProject() async throws {
        let path = try await create(from: repo + "/ios/App", title: "Watch app")
        XCTAssertTrue(path.hasSuffix("/ios/App"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/x.swift"))
        XCTAssertTrue(path.contains("/.claude/worktrees/watch-app-"), path)
    }

    func testTwoSessionsWithSameTitleGetSeparateWorktrees() async throws {
        let a = try await create(from: repo, title: "Same")
        let b = try await create(from: repo, title: "Same")
        XCTAssertNotEqual(a, b)
    }

    func testFailsOutsideGit() async {
        let plain = root.appendingPathComponent("plain").path
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let result = await SessionWorktree.create(from: plain, title: "x")
        if case .success = result { XCTFail("expected failure outside a repository") }
    }

    func testOffersWorktreeOnlyForPlainCheckouts() async throws {
        let ok = await SessionWorktree.canCreate(in: repo)
        XCTAssertTrue(ok)
        let path = try await create(from: repo, title: "Nested")
        let insideWorktree = await SessionWorktree.canCreate(in: path)
        XCTAssertFalse(insideWorktree)
        let plain = root.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let outside = await SessionWorktree.canCreate(in: plain)
        XCTAssertFalse(outside)
    }
}
