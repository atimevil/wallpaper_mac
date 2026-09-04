import Foundation

/// 전력 정책의 입력. 시스템에서 수집하지만 테스트에서는 직접 만든다.
public struct PowerSignals: Equatable, Sendable {
    public var isOccluded: Bool
    public var isFullscreenAppActive: Bool
    public var idleSeconds: TimeInterval
    public var isOnBattery: Bool
    public var isLowPowerMode: Bool
    public var isThermallyPressured: Bool

    public init(
        isOccluded: Bool = false,
        isFullscreenAppActive: Bool = false,
        idleSeconds: TimeInterval = 0,
        isOnBattery: Bool = false,
        isLowPowerMode: Bool = false,
        isThermallyPressured: Bool = false
    ) {
        self.isOccluded = isOccluded
        self.isFullscreenAppActive = isFullscreenAppActive
        self.idleSeconds = idleSeconds
        self.isOnBattery = isOnBattery
        self.isLowPowerMode = isLowPowerMode
        self.isThermallyPressured = isThermallyPressured
    }

    /// 전원 연결, 화면 보임, 사용자 활동 중.
    public static let active = PowerSignals()
}
