import XCTest
@testable import PullYard

@MainActor
final class StackNotesTests: XCTestCase {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stack-notes-\(UUID().uuidString).json")
    }

    func testNotesSurviveReload() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = StackNotes(file: file)
        let key = StackNotes.key(account: "me", host: "github.com", repo: RepoRef(owner: "Acme", name: "App"), number: 7)
        store.replace(key, with: [StackNote(kind: .decision, text: "Merge API first")])
        store.flush()
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let reloaded = StackNotes(file: file)
        XCTAssertEqual(reloaded.notes(key).map(\.text), ["Merge API first"])
        XCTAssertEqual(reloaded.notes(key).first?.kind, .decision)
        XCTAssertTrue(reloaded.hasNotes(key))
    }

    func testEmptyDraftsAreNotStored() {
        let store = StackNotes(file: tempFile())
        store.replace("k", with: [StackNote(), StackNote(text: "  \n")])
        XCTAssertTrue(store.notes("k").isEmpty)
        XCTAssertFalse(store.hasNotes("k"))
    }

    func testKeySeparatesAccounts() {
        XCTAssertNotEqual(StackNotes.key(account: "alice", host: "github.com", repo: RepoRef(owner: "acme", name: "app"), number: 1),
                          StackNotes.key(account: "bob", host: "github.com", repo: RepoRef(owner: "acme", name: "app"), number: 1))
    }

    func testKeyIgnoresRepoCase() {
        XCTAssertEqual(StackNotes.key(account: "me", host: "github.com", repo: RepoRef(owner: "Acme", name: "App"), number: 1),
                       StackNotes.key(account: "me", host: "github.com", repo: RepoRef(owner: "acme", name: "app"), number: 1))
    }

    func testReplaceKeepsUnchangedTimestampAndDropsRemoved() {
        let store = StackNotes(file: tempFile())
        let a = StackNote(text: "one", updated: Date(timeIntervalSince1970: 1))
        let b = StackNote(text: "two", updated: Date(timeIntervalSince1970: 1))
        store.replace("k", with: [a, b])
        let stamped = store.notes("k")[0].updated
        var edited = store.notes("k")[1]
        edited.text = "two!"
        store.replace("k", with: [store.notes("k")[0], edited])
        XCTAssertEqual(store.notes("k")[0].updated, stamped)
        XCTAssertEqual(store.notes("k")[1].text, "two!")
        store.replace("k", with: [store.notes("k")[1]])
        XCTAssertEqual(store.notes("k").map(\.text), ["two!"])
    }
}

final class StackEntryTests: XCTestCase {
    private func pr(_ number: Int, head: String, base: String) -> StackNode {
        StackNode(number: number, title: "PR \(number)", state: "OPEN", isDraft: false, headRefName: head, baseRefName: base,
                  headRepo: "acme/app", author: "me", updatedAt: Date(timeIntervalSince1970: TimeInterval(number)), reviewDecision: nil,
                  ci: nil, commitOid: nil, commitHeadline: nil)
    }

    func testOneEntryPerStack() {
        let open = [pr(1, head: "a", base: "dev"), pr(2, head: "b", base: "a"), pr(3, head: "c", base: "a"), pr(4, head: "lone", base: "dev")]
        let entries = StackEntry.collect(repo: RepoRef(owner: "acme", name: "app"), mine: [2, 3, 4], open: open)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.tree.root, 1)
        XCTAssertEqual(entries.first?.mine, [2, 3])
        XCTAssertEqual(entries.first?.ordered.map(\.number), [1, 2, 3])
    }
}
