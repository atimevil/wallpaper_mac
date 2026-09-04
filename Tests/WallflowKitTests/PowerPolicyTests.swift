import XCTest
@testable import WallflowKit

final class PowerPolicyTests: XCTestCase {
    func testFullPowerIsThirtyFPS() {
        XCTAssertEqual(PowerPolicy.directive(for: .active), .playing(fps: 30))
    }

    func testOccludedDesktopPauses() {
        var s = PowerSignals.active
        s.isOccluded = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testFullscreenAppPauses() {
        var s = PowerSignals.active
        s.isFullscreenAppActive = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testIdleForFifteenMinutesPauses() {
        var s = PowerSignals.active
        s.idleSeconds = 900
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testJustUnderIdleThresholdKeepsPlaying() {
        var s = PowerSignals.active
        s.idleSeconds = 899
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 30))
    }

    func testBatteryHalvesFrameRate() {
        var s = PowerSignals.active
        s.isOnBattery = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    func testLowPowerModeHalvesFrameRate() {
        var s = PowerSignals.active
        s.isLowPowerMode = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    func testThermalPressureHalvesFrameRate() {
        var s = PowerSignals.active
        s.isThermallyPressured = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }

    /// 정지 조건은 프레임레이트 감쇠보다 우선한다.
    func testPauseWinsOverReducedFrameRate() {
        var s = PowerSignals.active
        s.isOnBattery = true
        s.isOccluded = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .paused)
    }

    func testMultipleReductionsStillFifteen() {
        var s = PowerSignals.active
        s.isOnBattery = true
        s.isLowPowerMode = true
        s.isThermallyPressured = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 15))
    }
}
