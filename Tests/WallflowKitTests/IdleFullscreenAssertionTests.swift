import XCTest
@testable import WallflowKit

/// 감상 모드는 다른 앱이 "화면을 끄지 마라"를 걸고 있으면(영상 재생 등) 안 뜬다.
/// 실측 근거: Firefox 재생 중 `NoDisplaySleepAssertion "video-playing"`,
/// QuickTime 재생 중 `PreventUserIdleDisplaySleep`.
final class IdleFullscreenAssertionTests: XCTestCase {
    private let me: Int32 = 500

    private func assertion(_ type: String, level: Int = 255, trueType: String? = nil,
                           onBehalfOf: Int32? = nil) -> [String: Any] {
        var a: [String: Any] = ["AssertType": type, "AssertLevel": NSNumber(value: level)]
        if let trueType { a["AssertionTrueType"] = trueType }
        if let onBehalfOf { a["AssertionOnBehalfOfPID"] = NSNumber(value: onBehalfOf) }
        return a
    }

    private func check(_ byPID: [Int32: [[String: Any]]]) -> Bool {
        IdleFullscreen.otherAppKeepsDisplayAwake(assertionsByPID: byPID, selfPID: me)
    }

    func testNoAssertions() {
        XCTAssertFalse(check([:]))
    }

    func testQuickTimePlayingBlocks() {
        XCTAssertTrue(check([30433: [assertion("PreventUserIdleDisplaySleep")]]))
    }

    func testFirefoxLegacyVideoAssertionBlocks() {
        XCTAssertTrue(check([1235: [assertion("NoDisplaySleepAssertion")]]))
    }

    /// 시스템 잠자기만 막는 것(소리 재생, caffeinate, Firefox 평소 상태)은 화면과 무관하다.
    func testSystemSleepOnlyDoesNotBlock() {
        XCTAssertFalse(check([
            1235: [assertion("NoIdleSleepAssertion")],
            426: [assertion("PreventUserIdleSystemSleep", onBehalfOf: 1235)],
        ]))
    }

    /// powerd의 내부 어서션은 화면이 켜져 있는 동안 늘 있다 — 세면 영영 안 뜬다.
    func testPowerdInternalDisplayAssertionDoesNotBlock() {
        XCTAssertFalse(check([351: [assertion("InternalPreventDisplaySleep")]]))
    }

    func testOwnAssertionIgnored() {
        XCTAssertFalse(check([me: [assertion("PreventUserIdleDisplaySleep")]]))
    }

    /// 데몬이 우리 대신 만든 어서션도 우리 것이다.
    func testAssertionOnOurBehalfIgnored() {
        XCTAssertFalse(check([426: [assertion("PreventUserIdleDisplaySleep", onBehalfOf: me)]]))
    }

    func testReleasedAssertionIgnored() {
        XCTAssertFalse(check([30433: [assertion("PreventUserIdleDisplaySleep", level: 0)]]))
    }

    /// 겉 종류가 달라도 실제 종류가 화면이면 센다.
    func testTrueTypeCounts() {
        XCTAssertTrue(check([77: [assertion("SomethingElse", trueType: "PreventUserIdleDisplaySleep")]]))
    }
}
