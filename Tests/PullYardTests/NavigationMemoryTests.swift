import XCTest
@testable import PullYard

final class NavigationMemoryTests: XCTestCase {
    func testSectionKeysRoundTrip() {
        let sections: [SidebarSection] = [
            .notifications, .prs(.reviewRequested), .prs(.mine), .prs(.reviewed), .myPRsByRepo, .stacks,
            .issues(.assigned), .issues(.mentioned), .repos, .projects, .claude
        ]
        for section in sections {
            XCTAssertEqual(SidebarSection(storageKey: section.storageKey), section)
        }
        XCTAssertNil(SidebarSection(storageKey: "unknown"))
        XCTAssertEqual(SidebarSection(storageKey: "prs/removedFilter"), .prs(.reviewRequested))
    }

    func testRouteRoundTripIsScopedToAccount() throws {
        let repo = try XCTUnwrap(RepoRef(full: "acme/storefront"))
        let routes: [Route] = [.pr(ItemRef(repo: repo, number: 42)), .issue(ItemRef(repo: repo, number: 7)), .repo(repo)]
        for route in routes {
            let stored = try XCTUnwrap(NavigationMemory.encode(route, account: "github.com/octo"))
            XCTAssertEqual(NavigationMemory.decode(stored, account: "github.com/octo"), route)
            XCTAssertNil(NavigationMemory.decode(stored, account: "github.com/other"))
        }
        XCTAssertNil(NavigationMemory.encode(.commit(repo, "abc123"), account: nil))
        XCTAssertNil(NavigationMemory.decode("garbage", account: nil))
    }

    func testListSortQueries() {
        XCTAssertEqual(ListSort.updated.query, "sort:updated-desc")
        XCTAssertEqual(ListSort(rawValue: "created")?.query, "sort:created-desc")
        XCTAssertEqual(ListSort.allCases.count, 3)
    }
}
