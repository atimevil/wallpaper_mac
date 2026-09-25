import Foundation

/// 사용자가 고르는 재생 규칙. 실물 Wallpaper Engine의 "성능" 설정에 해당한다 —
/// 상황마다 재생 규칙을 고르고(가려짐·전체화면·입력 없음·배터리) 프레임 제한을 둔다.
///
/// 기본값: 가려지면 정지, 전체화면이면 정지, 15분 입력 없으면 정지,
/// 전원 연결 60fps, 배터리·저전력 30fps(2026-09-25 사용자 결정).
public struct PowerPreferences: Equatable, Sendable {
    public var pauseWhenOccluded: Bool
    public var pauseInFullscreen: Bool
    /// 0이면 입력이 없어도 정지하지 않는다.
    public var idlePauseSeconds: TimeInterval
    /// 전원에 연결돼 있을 때의 프레임.
    public var targetFPS: Int
    /// 배터리·저전력일 때의 프레임. 0이면 멈춘다(WE 배터리 규칙의 "일시정지").
    /// 전원 연결 시보다 높아지지는 않는다 — 60은 "전원과 같게"다.
    public var batteryFPS: Int

    public init(
        pauseWhenOccluded: Bool = true, pauseInFullscreen: Bool = true,
        idlePauseSeconds: TimeInterval = PowerPolicy.idlePauseSeconds,
        targetFPS: Int = PowerPolicy.normalFPS,
        batteryFPS: Int = PowerPreferences.defaultBatteryFPS
    ) {
        self.pauseWhenOccluded = pauseWhenOccluded
        self.pauseInFullscreen = pauseInFullscreen
        self.idlePauseSeconds = idlePauseSeconds
        self.targetFPS = targetFPS
        self.batteryFPS = batteryFPS
    }

    public static let standard = PowerPreferences()
    /// 고를 수 있는 프레임. 배경화면에 60이 필요한 경우는 드물고 그 위는 낭비다.
    public static let allowedFPS = [15, 30, 60]
    /// 배터리·저전력 규칙. 0은 멈춤, 60은 전원과 같게.
    public static let allowedBatteryFPS = [60, 30, 15, 0]
    public static let defaultBatteryFPS = 30
}

/// 프레임레이트와 정지 여부를 결정하는 단일 지점.
/// 렌더러는 이 결정을 따르기만 한다.
public enum PowerPolicy {
    public static let normalFPS = 60
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

        var fps = PowerPreferences.allowedFPS.contains(preferences.targetFPS)
            ? preferences.targetFPS : normalFPS
        // 배터리·저전력 규칙. 멈출 수도, 프레임만 낮출 수도 있다.
        if signals.isOnBattery || signals.isLowPowerMode {
            let battery = PowerPreferences.allowedBatteryFPS.contains(preferences.batteryFPS)
                ? preferences.batteryFPS : PowerPreferences.defaultBatteryFPS
            if battery == 0 { return .paused }
            fps = Swift.min(fps, battery)
        }
        // 발열은 사용자가 끌 수 없다. 기계를 지키는 쪽이 우선이다.
        if signals.isThermallyPressured { fps = Swift.min(fps, reducedFPS) }
        return .playing(fps: fps)
    }

    /// 씬 콘텐츠만 보고 매 프레임 다시 그려야 하는지 정한다. 붙일 때와
    /// 재생을 다시 시작할 때(`apply(.playing)`) 둘 다 이 기준 하나를 써야
    /// 한다 — 따로 판단하면 이펙트·스크립트·퍼펫만으로 움직이는 씬이 한쪽
    /// 목록에서 빠져, 가려짐으로 멈췄다가 재개돼도 검은 화면으로 남는다.
    /// 스프라이트 시트 이미지(`hasAnimatedImage`)도 시간에 따라 장이 넘어간다 —
    /// 빠지면 "Loading..." 같은 GIF 씬이 첫 장에 멈춘다.
    public static func needsContinuousDrawing(
        hasVideo: Bool, hasParticles: Bool, hasText: Bool,
        hasAnimatedEffect: Bool, hasScriptHost: Bool, hasPuppets: Bool,
        hasAnimatedImage: Bool = false
    ) -> Bool {
        hasVideo || hasParticles || hasText || hasAnimatedEffect || hasScriptHost || hasPuppets
            || hasAnimatedImage
    }
}
