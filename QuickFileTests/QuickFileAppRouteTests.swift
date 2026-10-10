import Foundation
import XCTest
@testable import QuickFileCore

final class QuickFileAppRouteTests: XCTestCase {
    func testOnlyCanonicalNavigationURLsRoundTrip() {
        XCTAssertEqual(QuickFileAppRoute.externalEventIdentifiers,
                       ["quickfile://open/create", "quickfile://open/templates", "quickfile://open/diagnostics"])
        for route in QuickFileAppRoute.allCases {
            XCTAssertEqual(QuickFileAppRoute(url: route.url), route)
            XCTAssertLessThanOrEqual(route.url.absoluteString.utf8.count, QuickFileAppRoute.maximumURLBytes)
            XCTAssertEqual(route.url.scheme, "quickfile")
            XCTAssertEqual(route.url.host, "open")
            XCTAssertNil(URLComponents(url: route.url, resolvingAgainstBaseURL: false)?.queryItems)
        }
    }

    func testRejectsUnknownOrDataBearingRoutes() throws {
        let invalid = [
            "https://open/templates", "QUICKFILE://open/templates", "quickfile://OPEN/templates",
            "quickfile://create/templates", "quickfile://open/unknown", "quickfile://open",
            "quickfile:///templates", "quickfile://open//templates", "quickfile://open/templates/",
            "quickfile://open/./templates", "quickfile://open/%74emplates", "quickfile://open/TEMPLATES",
            "quickfile://open/templates?", "quickfile://open/templates?file=/tmp/a",
            "quickfile://open/create?template=123", "quickfile://open/create?grant=true",
            "quickfile://open/create?content=private", "quickfile://open/create?execute=true",
            "quickfile://open/templates#", "quickfile://open/templates#private",
            "quickfile://user@open/templates", "quickfile://user:password@open/templates",
            "quickfile://open:123/templates", "quickfile://open/create/file.txt",
            "file:///tmp/templates", "quickfile://open/" + String(repeating: "a", count: 10_000)
        ]
        for text in invalid {
            let url = try XCTUnwrap(URL(string: text), text)
            XCTAssertNil(QuickFileAppRoute(url: url), text)
        }
        let relative = try XCTUnwrap(URL(string: "templates", relativeTo: URL(string: "quickfile://open/")))
        XCTAssertNil(QuickFileAppRoute(url: relative))
    }

}
