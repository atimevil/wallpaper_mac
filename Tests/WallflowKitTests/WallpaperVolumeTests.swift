import XCTest
@testable import WallflowKit

final class WallpaperVolumeTests: XCTestCase {
    func testExplicitVolumeIsNilWhenUnset() {
        XCTAssertNil(WallpaperVolume.explicitVolume(for: "a", in: [:]))
    }

    func testExplicitVolumeReturnsStored() {
        XCTAssertEqual(WallpaperVolume.explicitVolume(for: "a", in: ["a": 0.3]), 0.3)
    }

    /// 손으로 고치거나 옛 값이 범위를 벗어나도 0~1로 죈다.
    func testExplicitVolumeClamps() {
        XCTAssertEqual(WallpaperVolume.explicitVolume(for: "a", in: ["a": 1.8]), 1)
        XCTAssertEqual(WallpaperVolume.explicitVolume(for: "a", in: ["a": -0.5]), 0)
    }

    func testExplicitVolumeIgnoresNonFinite() {
        XCTAssertNil(WallpaperVolume.explicitVolume(for: "a", in: ["a": .nan]))
    }

    func testSettingWritesOnlyThatID() {
        let out = WallpaperVolume.setting(0.5, for: "b", in: ["a": 0.2])
        XCTAssertEqual(out["a"], 0.2)
        XCTAssertEqual(out["b"], 0.5)
    }

    func testSettingClamps() {
        XCTAssertEqual(WallpaperVolume.setting(2.0, for: "a", in: [:])["a"], 1)
        XCTAssertEqual(WallpaperVolume.setting(-1.0, for: "a", in: [:])["a"], 0)
    }
}
