import XCTest
@testable import WallflowKit

final class PowerPolicyTests: XCTestCase {
    func testFullPowerIsSixtyFPS() {
        XCTAssertEqual(PowerPolicy.directive(for: .active), .playing(fps: 60))
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
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 60))
    }

    func testBatteryDefaultsToThirty() {
        var s = PowerSignals.active
        s.isOnBattery = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 30))
    }

    func testLowPowerModeDefaultsToThirty() {
        var s = PowerSignals.active
        s.isLowPowerMode = true
        XCTAssertEqual(PowerPolicy.directive(for: s), .playing(fps: 30))
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

    /// WE의 배터리 재생 규칙처럼 멈출 수도 있다.
    func testBatteryCanPause() {
        var prefs = PowerPreferences()
        prefs.batteryFPS = 0
        var s = PowerSignals.active
        s.isOnBattery = true
        XCTAssertEqual(PowerPolicy.directive(for: s, preferences: prefs), .paused)
    }

    /// 배터리 규칙이 전원 연결 시보다 높아지지는 않는다 — 60은 "전원과 같게"다.
    func testBatteryNeverExceedsPluggedIn() {
        var prefs = PowerPreferences()
        prefs.targetFPS = 30
        prefs.batteryFPS = 60
        var s = PowerSignals.active
        s.isOnBattery = true
        XCTAssertEqual(PowerPolicy.directive(for: s, preferences: prefs), .playing(fps: 30))
    }

    /// 허용되지 않은 배터리 값은 기본값으로 돌아간다.
    func testUnknownBatteryFPSFallsBackToDefault() {
        var prefs = PowerPreferences()
        prefs.batteryFPS = 7
        var s = PowerSignals.active
        s.isLowPowerMode = true
        XCTAssertEqual(PowerPolicy.directive(for: s, preferences: prefs), .playing(fps: 30))
    }
}
