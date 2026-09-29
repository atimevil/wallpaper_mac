import XCTest
@testable import WallflowKit

final class WorkshopScrollPagingTests: XCTestCase {
    func testLoadsNextPageWhenNearEnd() {
        // 행 높이 100, 두 줄 앞(200pt)까지 왔으면 요청한다.
        XCTAssertTrue(WorkshopScrollPaging.shouldLoadNextPage(
            visibleBottom: 800, contentHeight: 1000, rowHeight: 100, rowsBeforeEnd: 2))
    }

    func testDoesNotLoadWhenFarFromEnd() {
        XCTAssertFalse(WorkshopScrollPaging.shouldLoadNextPage(
            visibleBottom: 500, contentHeight: 1000, rowHeight: 100, rowsBeforeEnd: 2))
    }

    func testZeroRowHeightNeverTriggers() {
        XCTAssertFalse(WorkshopScrollPaging.shouldLoadNextPage(
            visibleBottom: 1000, contentHeight: 1000, rowHeight: 0))
    }

    func testRetriesUpToMax() {
        XCTAssertTrue(WorkshopScrollPaging.shouldRetryAfterEmptyPage(consecutiveEmptyPages: 0))
        XCTAssertTrue(WorkshopScrollPaging.shouldRetryAfterEmptyPage(consecutiveEmptyPages: 2))
        XCTAssertFalse(WorkshopScrollPaging.shouldRetryAfterEmptyPage(consecutiveEmptyPages: 3))
        XCTAssertFalse(WorkshopScrollPaging.shouldRetryAfterEmptyPage(consecutiveEmptyPages: 4))
    }
}
