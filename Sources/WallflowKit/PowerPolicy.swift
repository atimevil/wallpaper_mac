import Foundation

/// 프레임레이트와 정지 여부를 결정하는 단일 지점.
/// 렌더러는 이 결정을 따르기만 한다.
public enum PowerPolicy {
    public static let normalFPS = 30
    public static let reducedFPS = 15
    public static let idlePauseSeconds: TimeInterval = 900  // 15분

    public static func directive(for signals: PowerSignals) -> PlaybackDirective {
        // 보이지 않는 것을 그릴 이유가 없다. 정지가 감쇠보다 우선한다.
        if signals.isOccluded
            || signals.isFullscreenAppActive
            || signals.idleSeconds >= idlePauseSeconds {
            return .paused
        }

        let shouldReduce = signals.isOnBattery
            || signals.isLowPowerMode
            || signals.isThermallyPressured
        return .playing(fps: shouldReduce ? reducedFPS : normalFPS)
    }
}
