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

    // MARK: - needsContinuousDrawing

    func testNeedsContinuousDrawingWithNothingIsFalse() {
        XCTAssertFalse(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: false))
    }

    /// 핵심 회귀: 이미지 레이어 하나 + `g_Time`을 쓰는 이펙트뿐인 씬(예:
    /// 워크숍 3793500489 "starlight jet")도 비디오·파티클·글자 없이 계속
    /// 그려야 한다. 빠지면 붙을 때 검은 화면으로 멈춘다.
    func testNeedsContinuousDrawingWithOnlyAnimatedEffectIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: false,
            hasAnimatedEffect: true, hasScriptHost: false, hasPuppets: false))
    }

    /// "Loading..."(워크숍 3795096226)처럼 스프라이트 시트 이미지 하나뿐인 씬도
    /// 장을 넘기려면 계속 그려야 한다.
    func testNeedsContinuousDrawingWithOnlyAnimatedImageIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: false,
            hasAnimatedImage: true))
    }

    func testNeedsContinuousDrawingWithOnlyVideoIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: true, hasParticles: false, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: false))
    }

    func testNeedsContinuousDrawingWithOnlyParticlesIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: true, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: false))
    }

    func testNeedsContinuousDrawingWithOnlyTextIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: true,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: false))
    }

    /// 스크립트만으로 움직이는 씬(퍼펫 없이 g_Time류 유니폼만 다루는 스크립트
    /// 등)도 계속 그려야 한다 — 재개 시 이 항목이 빠졌던 게 이번 버그다.
    func testNeedsContinuousDrawingWithOnlyScriptHostIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: true, hasPuppets: false))
    }

    func testNeedsContinuousDrawingWithOnlyPuppetsIsTrue() {
        XCTAssertTrue(PowerPolicy.needsContinuousDrawing(
            hasVideo: false, hasParticles: false, hasText: false,
            hasAnimatedEffect: false, hasScriptHost: false, hasPuppets: true))
    }
}
