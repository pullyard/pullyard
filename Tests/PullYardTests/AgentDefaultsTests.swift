import XCTest
@testable import PullYard

@MainActor
final class AgentDefaultsTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = "AgentDefaultsTests." + UUID().uuidString
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    func testStartsWithCLIDefaults() {
        let d = AgentDefaults(store: store)
        XCTAssertEqual(d.model, "")
        XCTAssertEqual(d.effort, .standard)
        XCTAssertEqual(d.mode, .standard)
        XCTAssertEqual(d.kind, .chat)
        XCTAssertEqual(d.idleMinutes, 15)
        XCTAssertNil(d.modelArgument)
        XCTAssertNil(d.effortArgument)
    }

    func testPersistsAcrossInstances() {
        let d = AgentDefaults(store: store)
        d.mode = .auto
        d.model = "opus"
        d.effort = .high
        d.kind = .terminal
        let next = AgentDefaults(store: store)
        XCTAssertEqual(next.mode, .auto)
        XCTAssertEqual(next.modelArgument, "opus")
        XCTAssertEqual(next.effortArgument, "high")
        XCTAssertEqual(next.kind, .terminal)
    }

    func testComposerChoiceIgnoredUnlessRemembering() {
        let d = AgentDefaults(store: store)
        d.composerChanged(mode: "plan")
        d.composerChanged(model: "sonnet")
        d.composerChanged(effort: "max")
        XCTAssertEqual(d.mode, .standard)
        XCTAssertEqual(d.model, "")
        XCTAssertEqual(d.effort, .standard)
        d.rememberComposerChoice = true
        d.composerChanged(mode: "plan")
        d.composerChanged(model: "sonnet")
        d.composerChanged(effort: "max")
        XCTAssertEqual(d.mode, .plan)
        XCTAssertEqual(d.model, "sonnet")
        XCTAssertEqual(d.effort, .max)
    }

    func testAdoptNormalizesDefaultAndUnknownValues() {
        let d = AgentDefaults(store: store)
        d.model = "opus"
        d.adopt(model: "default")
        XCTAssertNil(d.modelArgument)
        d.adopt(mode: "nonsense")
        XCTAssertEqual(d.mode, .standard)
        d.adopt(effort: "nonsense")
        XCTAssertEqual(d.effort, .standard)
    }

    func testModelChoicesPreferLiveListAndKeepSavedModel() {
        let d = AgentDefaults(store: store)
        XCTAssertEqual(d.modelChoices.map(\.value), ["opus", "sonnet", "haiku", "fable"])
        d.remember(models: [
            ChatModelOption(value: "default", displayName: "Default", description: "", efforts: []),
            ChatModelOption(value: "opus[1m]", displayName: "Opus 1M", description: "Long context", efforts: ["low", "high"])
        ])
        XCTAssertEqual(d.modelChoices.map(\.value), ["opus[1m]"])
        d.model = "haiku"
        XCTAssertEqual(d.modelChoices.map(\.value), ["opus[1m]", "haiku"])
        XCTAssertEqual(d.modelTitle, "haiku")
        XCTAssertEqual(AgentDefaults(store: store).knownModels.count, 2)
    }

    func testResetRestoresDefaults() {
        let d = AgentDefaults(store: store)
        d.mode = .auto
        d.model = "opus"
        d.idleMinutes = 60
        d.rememberComposerChoice = true
        d.reset()
        XCTAssertEqual(d.mode, .standard)
        XCTAssertNil(d.modelArgument)
        XCTAssertEqual(d.idleMinutes, 15)
        XCTAssertFalse(d.rememberComposerChoice)
    }
}
