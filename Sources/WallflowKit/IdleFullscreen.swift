import Foundation

/// 유휴 전체화면(감상 모드)이 떠 있어야 하는지 판정하는 순수 로직.
///
/// 켜짐 + 임계(초) 이상 입력이 없을 때만 뜬다. 같은 함수로 뜨고 내리는 양쪽을
/// 판정한다(뜰 조건이 거짓이 되면 내린다) — 켜고 내리는 임계가 어긋나지 않게.
/// 창을 올리고 내리는 실제 동작과 빠른 폴링은 App의 `IdleFullscreenController`가 한다.
public enum IdleFullscreen {
    public static func shouldShow(
        enabled: Bool, idleSeconds: TimeInterval, thresholdSeconds: TimeInterval
    ) -> Bool {
        enabled && thresholdSeconds > 0 && idleSeconds >= thresholdSeconds
    }

    /// 화면을 켜 두라는 전원 어서션 종류. 영상을 볼 때는 입력이 없어 유휴가 쌓이므로,
    /// 이걸 안 보면 보던 영상을 덮는다. macOS 화면보호기도 같은 신호로 비켜 준다.
    /// 실측: QuickTime 재생 = `PreventUserIdleDisplaySleep`, Firefox 재생 =
    /// `NoDisplaySleepAssertion "video-playing"`. 시스템 잠자기만 막는 것
    /// (`PreventUserIdleSystemSleep`, `NoIdleSleepAssertion`)과 powerd 내부용
    /// `InternalPreventDisplaySleep`(화면이 켜져 있으면 늘 있음)은 세지 않는다.
    public static let displayAwakeAssertionTypes: Set<String> = [
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
    ]

    /// `IOPMCopyAssertionsByProcess` 결과에서, 우리 말고 다른 앱이 화면을 켜 두라고
    /// 하는지 본다. 데몬이 우리 대신 만든 것(`AssertionOnBehalfOfPID`)도 우리 것이다.
    public static func otherAppKeepsDisplayAwake(
        assertionsByPID: [Int32: [[String: Any]]], selfPID: Int32
    ) -> Bool {
        for (pid, list) in assertionsByPID where pid != selfPID {
            for a in list {
                if (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value == selfPID { continue }
                guard ((a["AssertLevel"] as? NSNumber)?.intValue ?? 0) > 0 else { continue }
                let types = [a["AssertType"], a["AssertionTrueType"]].compactMap { $0 as? String }
                if types.contains(where: displayAwakeAssertionTypes.contains) { return true }
            }
        }
        return false
    }
}
