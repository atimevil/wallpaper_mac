import XCTest
@testable import WallflowKit

final class WorkshopDetailsPageTests: XCTestCase {
    // 실물 상세 페이지(3803492669)에서 잘라 온 조각.
    let real = """
    <div class="ratingSection">
        <div class="fileRatingDetails"><img src="https://community.fastly.steamstatic.com/public/images/sharedfiles/4-star_large.png?v=2" /></div>
        <div class="numRatings">26 ratings</div>				</div>
    <div class="friendBlockContent">
        s1lent<br>
        <span class="friendSmallText">
    Offline
        </span>
    </div>
    """
    func testParsesRatingCountAndAuthor() {
        let page = WorkshopDetailsPage.parse(html: real)
        XCTAssertEqual(page.rating, 4)
        XCTAssertEqual(page.ratingCount, 26)
        XCTAssertEqual(page.author, "s1lent")
    }
    func testHalfStarAndThousands() {
        let html = #"<div class="fileRatingDetails"><img src="x/3-star_large.png" /></div><div class="numRatings">1,204 ratings</div>"#
        XCTAssertEqual(WorkshopDetailsPage.parse(html: html).ratingCount, 1204)
        XCTAssertEqual(WorkshopDetailsPage.parse(html: html).rating, 3)
    }
    func testNotEnoughRatings() {
        let html = #"<div class="fileRatingDetails"><img src="x/not-yet_large.png" /></div><div class="numRatings">Not enough ratings</div>"#
        let page = WorkshopDetailsPage.parse(html: html)
        XCTAssertNil(page.rating)
        XCTAssertNil(page.ratingCount)
    }
    func testGarbageYieldsEmptyNotCrash() {
        XCTAssertEqual(WorkshopDetailsPage.parse(html: "<html></html>"),
                       WorkshopDetailsPage(rating: nil, ratingCount: nil, author: nil))
    }
    func testBBCodeToPlain() {
        XCTAssertEqual(WorkshopText.plain(fromBBCode: "[h1]Hi[/h1]\n[b]bold[/b] [url=https://x]link[/url][list][*]a[*]b[/list][img]p.png[/img]"),
                       "Hi\nbold link\n• a\n• b")
    }
    func testMergeDropsDuplicatesKeepsOrder() {
        func item(_ id: String) -> WorkshopItem { WorkshopItem(id: id, title: id, sizeBytes: 0, previewURL: nil, tags: []) }
        XCTAssertEqual(WorkshopPaging.merge([item("1"), item("2")], [item("2"), item("3")]).map(\.id), ["1", "2", "3"])
    }
}
