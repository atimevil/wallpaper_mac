import XCTest
@testable import WallflowKit

final class DisplaySelectionTests: XCTestCase {
    func testUniqueUUIDsAreKeysAsIs() {
        XCTAssertEqual(DisplaySelection.keys(forUUIDs: ["A", "B"]), ["A", "B"])
    }

    /// 같은 모델 모니터 두 대는 UUID가 겹칠 수 있다 — 두 번째부터 순번을 붙여 구별한다.
    func testDuplicateUUIDsGetOrdinal() {
        XCTAssertEqual(DisplaySelection.keys(forUUIDs: ["A", "B", "B", "B"]), ["A", "B", "B#2", "B#3"])
    }

    func testItemFallsBackToDefault() {
        XCTAssertEqual(DisplaySelection.itemID(forDisplay: "A", in: [:], default: "x"), "x")
        XCTAssertNil(DisplaySelection.itemID(forDisplay: "A", in: [:], default: nil))
    }

    func testPerDisplayOverridesDefault() {
        XCTAssertEqual(DisplaySelection.itemID(forDisplay: "B", in: ["B": "y"], default: "x"), "y")
        XCTAssertEqual(DisplaySelection.itemID(forDisplay: "A", in: ["B": "y"], default: "x"), "x")
    }

    func testSettingOneDisplayKeepsOthers() {
        let out = DisplaySelection.setting("z", forDisplay: "B", in: ["A": "y"])
        XCTAssertEqual(out, ["A": "y", "B": "z"])
    }

    /// "모든 화면"은 지금 연결된 화면의 지정만 지운다 — 꺼져 있는 회사 모니터 설정은 남는다.
    func testClearingConnectedKeepsDisconnected() {
        let out = DisplaySelection.clearing(displays: ["A", "B"], in: ["A": "1", "B": "2", "OFFICE": "3"])
        XCTAssertEqual(out, ["OFFICE": "3"])
    }

    func testRemovingItemDropsEveryDisplayPointingAtIt() {
        let out = DisplaySelection.removing(itemID: "gone", in: ["A": "gone", "B": "keep", "C": "gone"])
        XCTAssertEqual(out, ["B": "keep"])
    }
}
