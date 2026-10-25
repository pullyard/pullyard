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

    func testAuthorizationHeader() {
        XCTAssertEqual(JiraAccount.authorization(email: "", token: "abc"), "Bearer abc")
        XCTAssertEqual(JiraAccount.authorization(email: "a@b.c", token: "t"), "Basic " + Data("a@b.c:t".utf8).base64EncodedString())
    }

    func testSiteNormalization() {
        XCTAssertEqual(JiraAccount.normalizedSite("https://minitok.atlassian.net/jira/software/c/projects/COM/list?jql=project%20%3D%20COM")?.absoluteString, "https://minitok.atlassian.net")
        XCTAssertEqual(JiraAccount.normalizedSite("acme.atlassian.net/browse/PAY-1")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraAccount.normalizedSite("https://jira.corp.example/jira/browse/PAY-1")?.absoluteString, "https://jira.corp.example/jira")
        XCTAssertEqual(JiraAccount.normalizedSite("https://corp.example/tracker/browse/PAY-1")?.absoluteString, "https://corp.example/tracker")
        XCTAssertNil(JiraAccount.normalizedSite("http://insecure.example"))
        XCTAssertNil(JiraAccount.normalizedSite("  "))
    }

    func testTablesAndPanelsBecomeReadableText() {
        let html = "<p>PR 2 of 2 for</p><div class=\"table-wrap\"><table><tbody><tr><td>\n  <a href=\"x\">COM-1563</a>\n</td><td>\n\n DONE \n</td></tr></tbody></table></div><p>&nbsp;</p><p>Next</p>"
        XCTAssertEqual(JiraClient.plainText(html), "PR 2 of 2 for\nCOM-1563 · DONE\n\nNext")
    }
}
