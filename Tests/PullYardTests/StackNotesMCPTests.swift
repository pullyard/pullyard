import XCTest
@testable import PullYard
import StackNotesKit

final class StackNotesMCPTests: XCTestCase {
    private let server = StackNotesMCPServer.Server(account: "me", host: "github.com")

    func testInitializeAdvertisesTools() throws {
        let reply = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testToolsList() throws {
        let reply = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["add_stack_note", "list_stack_notes"])
    }

    func testRejectsBadArguments() throws {
        let reply = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "add_stack_note", "arguments": ["repo": "nope", "pr": 1, "text": "x"]]]))
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        let empty = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "add_stack_note", "arguments": ["repo": "a/b", "pr": 1, "text": "  "]]]))
        XCTAssertEqual((empty["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testUnknownMethod() throws {
        let reply = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 5, "method": "resources/list"]))
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testConfigShape() throws {
        let json = try XCTUnwrap(StackNotesMCP.config(account: "me", host: "github.com", command: "/tmp/pullyard-mcp"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let server = try XCTUnwrap((obj["mcpServers"] as? [String: Any])?["pullyard"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, "/tmp/pullyard-mcp")
        XCTAssertEqual(server["args"] as? [String], ["--host", "github.com", "--account", "me"])
    }
}
