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
}
