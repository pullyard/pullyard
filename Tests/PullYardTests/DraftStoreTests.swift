import XCTest
@testable import PullYard

@MainActor
final class DraftStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReviewDraftRoundTripsAndEmptyDraftRemovesFile() {
        let key = DraftStore.key(account: "me", host: "github.com", repo: "acme/app", number: 7)
        let store = DraftStore(directory: dir)
        var draft = ReviewDraft()
        draft.pending = [.init(path: "a/b.swift", line: 12, side: "RIGHT", body: "Rename this")]
        draft.composer = .init(path: "a/b.swift", line: 20, side: "LEFT", body: "half typed")
        draft.replies = ["T1": "agreed"]
        draft.summary = "Looks good overall"
        store.save(draft, key: key)
        XCTAssertEqual(DraftStore(directory: dir).review(key), draft)
        XCTAssertNil(DraftStore(directory: dir).review(DraftStore.key(account: "me", host: "github.com", repo: "acme/app", number: 8)))
        store.save(ReviewDraft(replies: ["T1": "  "], comment: "\n"), key: key)
        XCTAssertNil(DraftStore(directory: dir).review(key))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0, 0)
    }

    func testTextDrafts() {
        let key = DraftStore.key(account: nil, host: "github.com", repo: "acme/app", number: 3, kind: "issue")
        let store = DraftStore(directory: dir)
        XCTAssertEqual(store.text(key), "")
        store.setText("Repro steps", key: key)
        XCTAssertEqual(DraftStore(directory: dir).text(key), "Repro steps")
        store.setText("  ", key: key)
        XCTAssertEqual(DraftStore(directory: dir).text(key), "")
    }

    func testModelRestoresPendingCommentsAfterRelaunch() {
        let store = DraftStore(directory: dir)
        let ref = ItemRef(repo: RepoRef(owner: "acme", name: "app"), number: 9)
        let api = GitHubAPI(token: "t")
        let first = PRDetailModel(ref: ref, api: api)
        first.drafts = store
        first.restoreDrafts()
        first.pending.append(PendingComment(path: "x.swift", line: 4, side: "RIGHT", body: "Nit"))
        first.summaryDraft = "Summary"
        first.saveDraftsNow()
        let second = PRDetailModel(ref: ref, api: api)
        second.drafts = store
        second.restoreDrafts()
        XCTAssertEqual(second.pending.map(\.body), ["Nit"])
        XCTAssertEqual(second.summaryDraft, "Summary")
        XCTAssertTrue(second.restoredDrafts)
    }
}
