import XCTest
@testable import PullYard

@MainActor
final class PromptLibraryTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = "PromptLibraryTests." + UUID().uuidString
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    func testAddDeduplicatesAndPersists() {
        let lib = PromptLibrary(store: store)
        XCTAssertNil(lib.add(text: "   "))
        let first = lib.add(text: "  Review my changes\nand list risks  ")
        XCTAssertEqual(first?.title, "Review my changes")
        XCTAssertEqual(lib.add(text: "Review my changes\nand list risks")?.id, first?.id)
        XCTAssertEqual(lib.prompts.count, 1)
        XCTAssertEqual(PromptLibrary(store: store).prompts, lib.prompts)
    }

    func testUpdateAndRemove() {
        let lib = PromptLibrary(store: store)
        guard var prompt = lib.add(text: "one", title: "First") else { return XCTFail("not added") }
        prompt.text = "two"
        lib.update(prompt)
        XCTAssertEqual(lib.prompts.first?.text, "two")
        lib.remove(prompt.id)
        XCTAssertTrue(PromptLibrary(store: store).prompts.isEmpty)
    }

    func testLongTitleIsShortened() {
        XCTAssertEqual(PromptLibrary.title(for: String(repeating: "a", count: 80)).count, 48)
    }
}
