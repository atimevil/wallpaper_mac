import XCTest
@testable import WallflowKit

final class WorkshopFilterStateTests: XCTestCase {
    func testDefaultIsEveryoneOnly() {
        let s = WorkshopFilterState()
        XCTAssertEqual(s.requestFilter.tags, ["Everyone"])
    }
    func testSingleKindGoesToRequest() {
        var s = WorkshopFilterState(); s.toggle("Scene", in: .kind)
        XCTAssertEqual(Set(s.requestFilter.tags), ["Everyone", "Scene"])
        XCTAssertTrue(s.matches(tags: ["Scene", "Everyone"]))
    }
    func testTwoKindsAreClientSideOr() {
        var s = WorkshopFilterState(); s.toggle("Scene", in: .kind); s.toggle("Video", in: .kind)
        XCTAssertFalse(s.requestFilter.tags.contains("Scene"))
        XCTAssertFalse(s.requestFilter.tags.contains("Video"))
        XCTAssertTrue(s.matches(tags: ["Video", "Everyone"]))
        XCTAssertFalse(s.matches(tags: ["Web", "Everyone"]))
    }
    func testGenresAreAnd() {
        var s = WorkshopFilterState(); s.toggle("Anime", in: .genre); s.toggle("Girls", in: .genre)
        XCTAssertTrue(Set(s.requestFilter.tags).isSuperset(of: ["Anime", "Girls"]))
        XCTAssertTrue(s.matches(tags: ["Anime", "Girls", "Everyone"]))
        XCTAssertFalse(s.matches(tags: ["Anime", "Everyone"]))
    }
    func testMatchingIsCaseInsensitive() {
        var s = WorkshopFilterState(); s.toggle("Audio responsive", in: .flag)
        XCTAssertTrue(s.matches(tags: ["audio responsive", "everyone"]))
    }
    func testToggleTwiceRemovesAndResetRestoresDefault() {
        var s = WorkshopFilterState(); s.toggle("Anime", in: .genre); s.toggle("Anime", in: .genre)
        XCTAssertEqual(s, WorkshopFilterState())
        s.toggle("Mature", in: .rating); s.reset()
        XCTAssertEqual(s, WorkshopFilterState())
    }
    func testKeyIsOrderIndependent() {
        var a = WorkshopFilterState(); a.toggle("Anime", in: .genre); a.toggle("Girls", in: .genre)
        var b = WorkshopFilterState(); b.toggle("Girls", in: .genre); b.toggle("Anime", in: .genre)
        XCTAssertEqual(a.key, b.key)
    }
}
