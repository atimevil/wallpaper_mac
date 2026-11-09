import XCTest
@testable import WallflowKit

final class WallpaperRotationTests: XCTestCase {
    private func next(_ current: String?, _ list: [String], shuffle: Bool = false,
                      pick: Int = 0) -> String? {
        WallpaperRotation.next(after: current, in: list, shuffle: shuffle, random: { _ in pick })
    }

    func testInOrderAdvancesAndWraps() {
        XCTAssertEqual(next("a", ["a", "b", "c"]), "b")
        XCTAssertEqual(next("c", ["a", "b", "c"]), "a")
    }

    /// 지금 것이 후보에 없으면(빼기·지움) 처음 것으로.
    func testCurrentNotInCandidatesStartsAtFirst() {
        XCTAssertEqual(next("x", ["a", "b"]), "a")
        XCTAssertEqual(next(nil, ["a", "b"]), "a")
    }

    func testNothingToChangeTo() {
        XCTAssertNil(next("a", []))
        XCTAssertNil(next("a", ["a"]))
        XCTAssertNil(next("a", ["a"], shuffle: true))
    }

    /// 무작위여도 지금 것은 다시 고르지 않는다.
    func testShuffleNeverRepeatsCurrent() {
        for pick in 0..<2 {
            let out = next("b", ["a", "b", "c"], shuffle: true, pick: pick)
            XCTAssertNotNil(out)
            XCTAssertNotEqual(out, "b")
        }
        XCTAssertEqual(next("b", ["a", "b", "c"], shuffle: true, pick: 1), "c")
    }

    func testDueAfterInterval() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(WallpaperRotation.isDue(lastChange: t0, now: t0.addingTimeInterval(59), interval: 60))
        XCTAssertTrue(WallpaperRotation.isDue(lastChange: t0, now: t0.addingTimeInterval(60), interval: 60))
    }

    /// 꺼짐(0)이거나 기준 시각이 없으면 바꾸지 않는다(켤 때 기준을 지금으로 잡는다).
    func testNotDueWhenOffOrUnseeded() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(WallpaperRotation.isDue(lastChange: t0, now: t0.addingTimeInterval(9999), interval: 0))
        XCTAssertFalse(WallpaperRotation.isDue(lastChange: nil, now: t0, interval: 60))
    }

    /// 잠자기·재시작으로 시계가 뒤로 가도(기준이 미래) 바로 바꾸지 않는다.
    func testClockWentBackwardsIsNotDue() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(WallpaperRotation.isDue(lastChange: t0, now: t0.addingTimeInterval(-30), interval: 60))
    }
}
