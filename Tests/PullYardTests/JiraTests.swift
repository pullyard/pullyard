import XCTest
@testable import PullYard

final class JiraTests: XCTestCase {
    func testExtractsKeysAndSkipsNoise() {
        XCTAssertEqual(JiraKeys.extract(["PAY-142: retry webhooks (see PAY-7)", "uses UTF-8 and SHA-256"]), ["PAY-142", "PAY-7"])
        XCTAssertEqual(JiraKeys.extract(branch: "feature/pay-142-retry"), ["PAY-142"])
        XCTAssertEqual(JiraKeys.extract(["xPAY-12", "PAY-0"]), [])
    }

    func testParsesIssue() {
        let o: [String: Any] = [
            "key": "PAY-142",
            "fields": [
                "summary": "Retry webhooks",
                "status": ["name": "In Progress", "statusCategory": ["key": "indeterminate"]],
                "issuetype": ["name": "Bug"],
                "assignee": ["displayName": "Sam Lee"],
                "updated": "2026-10-20T09:15:00.000+0200",
            ],
            "renderedFields": ["description": "<p>Webhooks fail &amp; never retry.</p><ul><li>Add backoff</li></ul>"],
        ]
        let issue = JiraClient.parseIssue(o, base: URL(string: "https://acme.atlassian.net")!)
        XCTAssertEqual(issue.status, "In Progress")
        XCTAssertEqual(issue.statusCategory, "indeterminate")
        XCTAssertEqual(issue.url, "https://acme.atlassian.net/browse/PAY-142")
        XCTAssertEqual(issue.description, "Webhooks fail & never retry.\n\n• Add backoff")
        XCTAssertNotNil(issue.updated)
    }

    func testParsesAttachmentsAndKinds() {
        let o: [String: Any] = [
            "key": "KRIS-716",
            "fields": [
                "summary": "Dialog stays",
                "attachment": [
                    ["id": "10001", "filename": "ScreenRecording_1.MP4", "mimeType": "video/mp4", "size": 4_200_000,
                     "content": "https://acme.atlassian.net/rest/api/2/attachment/content/10001",
                     "author": ["displayName": "Alexan"], "created": "2026-11-17T15:59:46.000+0400"],
                    ["id": 10002, "filename": "shot.PNG", "mimeType": "application/octet-stream", "size": 1200,
                     "content": "https://acme.atlassian.net/rest/api/2/attachment/content/10002",
                     "thumbnail": "https://acme.atlassian.net/rest/api/2/attachment/thumbnail/10002"],
                    ["id": "10003", "filename": "log.txt", "mimeType": "text/plain", "size": 10,
                     "content": "https://acme.atlassian.net/rest/api/2/attachment/content/10003"],
                    ["id": "10004", "filename": "broken.png"],
                ],
            ],
        ]
        let issue = JiraClient.parseIssue(o, base: URL(string: "https://acme.atlassian.net")!)
        XCTAssertEqual(issue.attachments.map(\.id), ["10001", "10002", "10003"])
        XCTAssertEqual(issue.attachments.map(\.kind), [.video, .image, .other])
        XCTAssertEqual(issue.attachments[0].author, "Alexan")
        XCTAssertNotNil(issue.attachments[0].created)
        XCTAssertNotNil(issue.attachments[1].thumbnail)
        XCTAssertFalse(issue.attachments[2].isMedia)
    }

    func testAuthorizationHeader() {
        XCTAssertEqual(JiraConnections.authorization(email: "", token: "abc"), "Bearer abc")
        XCTAssertEqual(JiraConnections.authorization(email: "a@b.c", token: "t"), "Basic " + Data("a@b.c:t".utf8).base64EncodedString())
    }

    func testRoutesByOverrideThenProjectKeyThenLearned() {
        let a = JiraConnection(id: "a", name: "Work A", site: "a.atlassian.net", email: "", projectKeys: ["COM", "PAY"])
        let b = JiraConnection(id: "b", name: "Work B", site: "b.atlassian.net", email: "", projectKeys: ["OPS", "PAY"])
        let both = [a, b]
        let repo = RepoRef(owner: "Mabrook", name: "App")
        func route(_ key: String, repo: RepoRef? = nil, org: [String: String] = [:], repos: [String: String] = [:], learned: [String: String] = [:], in list: [JiraConnection] = both) -> String? {
            JiraConnections.route(issueKey: key, repo: repo, connections: list, orgOverrides: org, repoOverrides: repos, learned: learned)?.id
        }
        XCTAssertEqual(route("COM-1"), "a")
        XCTAssertEqual(route("OPS-12"), "b")
        XCTAssertNil(route("PAY-3"))
        XCTAssertEqual(route("PAY-3", learned: ["PAY": "b"]), "b")
        XCTAssertNil(route("NEW-1"))
        XCTAssertEqual(route("NEW-1", learned: ["NEW": "a"]), "a")
        XCTAssertEqual(route("OPS-1", repo: repo, org: ["mabrook": "a"]), "a")
        XCTAssertEqual(route("OPS-1", repo: repo, org: ["mabrook": "a"], repos: ["mabrook/app": "b"]), "b")
        XCTAssertEqual(route("OPS-1", repo: repo, org: ["mabrook": "gone"]), "b")
        XCTAssertEqual(route("XYZ-9", in: [a]), "a")
        XCTAssertEqual(JiraConnections.projectKey(of: "com-12"), "COM")
    }

    func testSiteNormalization() {
        XCTAssertEqual(JiraConnections.normalizedSite("https://minitok.atlassian.net/jira/software/c/projects/COM/list?jql=project%20%3D%20COM")?.absoluteString, "https://minitok.atlassian.net")
        XCTAssertEqual(JiraConnections.normalizedSite("acme.atlassian.net/browse/PAY-1")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraConnections.normalizedSite("https://jira.corp.example/jira/browse/PAY-1")?.absoluteString, "https://jira.corp.example/jira")
        XCTAssertEqual(JiraConnections.normalizedSite("https://corp.example/tracker/browse/PAY-1")?.absoluteString, "https://corp.example/tracker")
        XCTAssertNil(JiraConnections.normalizedSite("http://insecure.example"))
        XCTAssertNil(JiraConnections.normalizedSite("  "))
    }

    func testTablesAndPanelsBecomeReadableText() {
        let html = "<p>PR 2 of 2 for</p><div class=\"table-wrap\"><table><tbody><tr><td>\n  <a href=\"x\">COM-1563</a>\n</td><td>\n\n DONE \n</td></tr></tbody></table></div><p>&nbsp;</p><p>Next</p>"
        XCTAssertEqual(JiraClient.plainText(html), "PR 2 of 2 for\nCOM-1563 · DONE\n\nNext")
    }

    func testListsEndBeforeTheNextHeading() {
        let html = "<p><b>Precondition:</b></p><ul><li>New account</li><li>No attempt</li></ul><p><strong>Steps to Reproduce:</strong></p><ol><li>Open <code>app</code></li></ol>"
        let text = JiraClient.plainText(html)
        XCTAssertEqual(text, "**Precondition:**\n\n• New account\n• No attempt\n**Steps to Reproduce:**\n\n• Open `app`")
        XCTAssertEqual(JiraDescriptionBlock.parse(text), [
            .heading("Precondition:"), .bullet("New account"), .bullet("No attempt"),
            .gap, .heading("Steps to Reproduce:"), .bullet("Open `app`")
        ])
    }

    func testDescriptionHeadingsNeedToBeShort() {
        XCTAssertTrue(JiraDescriptionBlock.isHeading("Expected Result:"))
        XCTAssertFalse(JiraDescriptionBlock.isHeading("The ID verification section should display the initial status until:"))
        XCTAssertFalse(JiraDescriptionBlock.isHeading("Just a sentence"))
    }
}
