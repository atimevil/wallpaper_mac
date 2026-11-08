import XCTest
@testable import WallflowKit

final class IdleFullscreenTests: XCTestCase {
    func testOffWhenDisabled() {
        XCTAssertFalse(IdleFullscreen.shouldShow(
            enabled: false, idleSeconds: 999, thresholdSeconds: 60))
    }

    func testOffBelowThreshold() {
        XCTAssertFalse(IdleFullscreen.shouldShow(
            enabled: true, idleSeconds: 59, thresholdSeconds: 60))
    }

    func testOnAtOrAboveThreshold() {
        XCTAssertTrue(IdleFullscreen.shouldShow(
            enabled: true, idleSeconds: 60, thresholdSeconds: 60))
        XCTAssertTrue(IdleFullscreen.shouldShow(
            enabled: true, idleSeconds: 120, thresholdSeconds: 60))
    }

    /// 임계가 0이면 꺼진 것으로 본다 — 자리 비우자마자 화면을 덮지 않게.
    func testOffWhenThresholdZero() {
        XCTAssertFalse(IdleFullscreen.shouldShow(
            enabled: true, idleSeconds: 100, thresholdSeconds: 0))
    }
}
