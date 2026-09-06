import Foundation

/// 사용자가 고르는 재생 규칙. 실물 Wallpaper Engine의 "성능" 설정에 해당한다.
///
/// 기본값이 지금까지의 고정 동작이다 — 가려지면 정지, 전체화면이면 정지,
/// 15분 입력 없으면 정지, 배터리면 낮춤. 하나도 안 바꾸면 전과 같다.
public struct PowerPreferences: Equatable, Sendable {
    public var pauseWhenOccluded: Bool
    public var pauseInFullscreen: Bool
    /// 0이면 입력이 없어도 정지하지 않는다.
    public var idlePauseSeconds: TimeInterval
    public var reduceOnBattery: Bool
    public var targetFPS: Int

    public init(
        pauseWhenOccluded: Bool = true, pauseInFullscreen: Bool = true,
        idlePauseSeconds: TimeInterval = PowerPolicy.idlePauseSeconds,
        reduceOnBattery: Bool = true, targetFPS: Int = PowerPolicy.normalFPS
    ) {
        self.pauseWhenOccluded = pauseWhenOccluded
        self.pauseInFullscreen = pauseInFullscreen
        self.idlePauseSeconds = idlePauseSeconds
        self.reduceOnBattery = reduceOnBattery
        self.targetFPS = targetFPS
    }

    public static let standard = PowerPreferences()
    /// 고를 수 있는 프레임. 배경화면에 60이 필요한 경우는 드물고 그 위는 낭비다.
    public static let allowedFPS = [15, 30, 60]
}

/// 프레임레이트와 정지 여부를 결정하는 단일 지점.
/// 렌더러는 이 결정을 따르기만 한다.
public enum PowerPolicy {
    public static let normalFPS = 30
    public static let reducedFPS = 15
    public static let idlePauseSeconds: TimeInterval = 900  // 15분

    public static func directive(
        for signals: PowerSignals, preferences: PowerPreferences = .standard
    ) -> PlaybackDirective {
        // 보이지 않는 것을 그릴 이유가 없다. 정지가 감쇠보다 우선한다.
        if (preferences.pauseWhenOccluded && signals.isOccluded)
            || (preferences.pauseInFullscreen && signals.isFullscreenAppActive)
            || (preferences.idlePauseSeconds > 0
                && signals.idleSeconds >= preferences.idlePauseSeconds) {
            return .paused
        }

        // 발열은 사용자가 끌 수 없다. 기계를 지키는 쪽이 우선이다.
        let shouldReduce = (preferences.reduceOnBattery
                            && (signals.isOnBattery || signals.isLowPowerMode))
            || signals.isThermallyPressured
        let target = PowerPreferences.allowedFPS.contains(preferences.targetFPS)
            ? preferences.targetFPS : normalFPS
        return .playing(fps: shouldReduce ? Swift.min(reducedFPS, target) : target)
    }
}
