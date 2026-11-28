import XCTest
@testable import PullYard

final class DevUpdateTests: XCTestCase {
    private func payload(notes: String) -> Data {
        let json: [String: Any] = [
            "tag_name": "dev-build",
            "name": "PullYard 2.15.0 dev 42",
            "body": notes,
            "html_url": "https://github.com/pullyard/pullyard/releases/tag/dev-build",
            "published_at": "2026-11-26T12:00:00Z",
            "assets": [
                ["name": "PullYard.dmg", "browser_download_url": "https://example.com/PullYard.dmg", "size": 1000],
                ["name": "PullYard.dmg.sig", "browser_download_url": "https://example.com/PullYard.dmg.sig", "size": 90]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParsesDevReleaseNotes() throws {
        let release = try Updater.parseDevRelease(payload(notes: "build: 42\nversion: 2.15.0\ncommit: abc1234\nmessage: macOS: fix: the sidebar"))
        XCTAssertEqual(release.devBuild, 42)
        XCTAssertEqual(release.version, "2.15.0")
        XCTAssertEqual(release.devCommit, "abc1234")
        XCTAssertEqual(release.notes, "macOS: fix: the sidebar")
        XCTAssertEqual(release.identifier, "dev-42")
        XCTAssertEqual(release.displayVersion, "2.15.0 dev 42")
        XCTAssertNotNil(release.signatureURL)
    }

    func testRejectsDevReleaseWithoutBuild() {
        XCTAssertThrowsError(try Updater.parseDevRelease(payload(notes: "version: 2.15.0")))
    }
}
