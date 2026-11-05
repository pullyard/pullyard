import XCTest
@testable import PullYard
import StackNotesKit

@MainActor
final class PRContextTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prctx-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snapshot(threads: [PRContextSnapshot.Thread]? = nil) -> PRContextSnapshot {
        PRContextSnapshot(
            repo: "o/r", number: 7, title: "Fix login", url: "https://github.com/o/r/pull/7", state: "OPEN", isDraft: false, author: "alice",
            baseRef: "main", headRef: "fix", headOid: "abcdef1234", body: "Body text", mergeStatus: "1 required check failed",
            requirements: [.init(state: "blocking", title: "1 required check failed", detail: "build"), .init(state: "met", title: "No conflicts with main", detail: nil)],
            checks: [.init(name: "lint", outcome: "success", required: false, url: nil), .init(name: "CI / build", outcome: "failure", required: true, url: "https://ci/1")],
            reviews: [.init(login: "bob", state: "CHANGES_REQUESTED")],
            threads: threads ?? [
                .init(path: "a.swift", line: 3, resolved: false, outdated: false, comments: [.init(author: "bob", body: "Rename this")]),
                .init(path: "b.swift", line: nil, resolved: true, outdated: true, comments: [.init(author: "bob", body: "Done")])
            ],
            files: ["a.swift", "b.swift", "README.md"],
            codeOwners: [.init(owners: ["@core"], files: ["a.swift", "b.swift"])], unownedFiles: ["README.md"],
            reviewedOid: "1111111aaa", commitsSinceReview: 2, captured: Date(timeIntervalSince1970: 0)
        )
    }

    private func call(_ server: StackNotesMCPServer.Server, _ name: String, _ args: [String: Any]) throws -> (String, Bool) {
        let reply = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    func testStoreRoundTripAndSafeFileName() throws {
        let key = StackNotesFile.key(account: "Me", host: "github.com", repo: "O/R", number: 7)
        XCTAssertFalse(PRContextStore.fileName(key: key).contains("/"))
        XCTAssertFalse(PRContextStore.fileName(key: key).contains("|"))
        try PRContextStore.write(snapshot(), key: key, directory: dir)
        XCTAssertEqual(PRContextStore.read(key: key, directory: dir), snapshot())
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPruneDropsOldFiles() throws {
        try PRContextStore.write(snapshot(), key: "k1", directory: dir)
        let file = dir.appendingPathComponent(PRContextStore.fileName(key: "k1"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 3600)], ofItemAtPath: file.path)
        PRContextStore.prune(directory: dir)
        XCTAssertNil(PRContextStore.read(key: "k1", directory: dir))
    }

    func testToolsReadSnapshot() throws {
        let server = StackNotesMCPServer.Server(account: "me", host: "github.com", contextDirectory: dir)
        try PRContextStore.write(snapshot(), key: StackNotesFile.key(account: "me", host: "github.com", repo: "o/r", number: 7), directory: dir)
        let (overview, err) = try call(server, "get_pull_request", ["repo": "o/r", "pr": 7])
        XCTAssertFalse(err)
        XCTAssertTrue(overview.contains("Merge status: 1 required check failed"))
        XCTAssertTrue(overview.contains("- [blocking] 1 required check failed — build"))
        XCTAssertTrue(overview.contains("@bob (changes requested)"))
        XCTAssertTrue(overview.contains("Code owners: @core (2 files)"))
        XCTAssertTrue(overview.contains("last reviewed commit 1111111, 2 commit(s) ago"))
        XCTAssertTrue(overview.contains("1 unresolved review thread(s), 1 failing check(s), 3 changed file(s)."))

        let (threads, _) = try call(server, "list_review_threads", ["repo": "o/r", "pr": 7])
        XCTAssertEqual(threads, "1. a.swift:3\n   @bob: Rename this")
        let (all, _) = try call(server, "list_review_threads", ["repo": "o/r", "pr": 7, "include_resolved": true])
        XCTAssertTrue(all.contains("2. b.swift (resolved, outdated)"))

        let (checks, _) = try call(server, "list_checks", ["repo": "o/r", "pr": "7"])
        XCTAssertEqual(checks, "- [failure] CI / build · required · https://ci/1\n- [success] lint · optional")

        let (files, _) = try call(server, "list_changed_files", ["repo": "o/r", "pr": 7])
        XCTAssertEqual(files, "a.swift — @core\nb.swift — @core\nREADME.md")
    }

    func testMissingSnapshotIsAnError() throws {
        let server = StackNotesMCPServer.Server(account: "me", host: "github.com", contextDirectory: dir)
        let (text, err) = try call(server, "get_pull_request", ["repo": "o/r", "pr": 8])
        XCTAssertTrue(err)
        XCTAssertTrue(text.contains("open that pull request in PullYard"))
    }

    func testOtherAccountSnapshotIsNotVisible() throws {
        try PRContextStore.write(snapshot(), key: StackNotesFile.key(account: "work", host: "github.com", repo: "o/r", number: 7), directory: dir)
        let server = StackNotesMCPServer.Server(account: "me", host: "github.com", contextDirectory: dir)
        XCTAssertTrue(try call(server, "list_checks", ["repo": "o/r", "pr": 7]).1)
    }

    func testPublisherMapsModel() throws {
        let json: [String: Any] = [
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED", "body": "b", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main",
            "headRefOid": "h", "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": ["nodes": []], "assignees": ["nodes": []],
            "reviewRequests": ["nodes": [["requestedReviewer": ["__typename": "Team", "name": "Core", "combinedSlug": "o/core"]]]],
            "latestOpinionatedReviews": ["nodes": []],
            "lastCommit": ["nodes": [["commit": ["oid": "h", "statusCheckRollup": ["state": "FAILURE", "contexts": ["nodes": [
                ["__typename": "CheckRun", "databaseId": 1, "name": "build", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": true,
                 "checkSuite": ["workflowRun": ["databaseId": 9, "workflow": ["name": "CI"]]]]
            ]]]]]]],
            "allCommits": ["nodes": []], "timelineItems": ["nodes": []],
            "reviewThreads": ["nodes": [["id": "t", "isResolved": false, "isOutdated": false, "path": "a", "line": 2, "diffSide": "RIGHT", "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true,
                                         "comments": ["nodes": [["id": "c", "author": ["login": "bob", "avatarUrl": ""], "body": "fix", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z"]]]]]]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(PullRequestDetail.self, from: JSONSerialization.data(withJSONObject: json))
        let ref = ItemRef(repo: RepoRef(owner: "o", name: "r"), number: 7)
        let reqs = MergeReadiness.requirements(pr, rules: .loading)
        let s = PRContextPublisher.snapshot(ref: ref, pr: pr, requirements: reqs, ownership: nil, files: ["a"], reviewed: nil)
        XCTAssertEqual(s.checks, [.init(name: "CI / build", outcome: "failure", required: true, url: nil)])
        XCTAssertEqual(s.reviews, [.init(login: "o/core", state: "REVIEW_REQUESTED")])
        XCTAssertEqual(s.threads.first?.comments, [.init(author: "bob", body: "fix")])
        XCTAssertEqual(s.mergeStatus, "1 required check failed")
        XCTAssertNil(s.codeOwners)
    }
}
