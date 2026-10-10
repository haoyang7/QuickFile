import XCTest
@testable import QuickFile

final class TemplatePresentationLifetimeTests: XCTestCase {
    func testHiddenAndReopenedPageRejectsWorkFromPreviousAppearance() throws {
        var lifetime = TemplatePresentationLifetime()
        XCTAssertNil(lifetime.token)
        lifetime.activate()
        let old = try XCTUnwrap(lifetime.token)
        XCTAssertTrue(lifetime.accepts(old))
        lifetime.deactivate()
        XCTAssertFalse(lifetime.accepts(old))
        lifetime.activate()
        let current = try XCTUnwrap(lifetime.token)
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(lifetime.accepts(old))
        XCTAssertTrue(lifetime.accepts(current))
    }

    func testRepeatedAppearanceCallbackDoesNotInvalidateCurrentWork() throws {
        var lifetime = TemplatePresentationLifetime()
        lifetime.activate()
        let token = try XCTUnwrap(lifetime.token)
        lifetime.activate()
        XCTAssertTrue(lifetime.accepts(token))
        lifetime.deactivate()
        lifetime.deactivate()
        XCTAssertFalse(lifetime.accepts(token))
    }
}
