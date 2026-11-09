import AppKit
import IOKit.pwr_mgt
import WallflowKit

/// 유휴 전체화면(감상 모드). 켜져 있고 일정 시간 입력이 없으면 배경 창을 전체화면
/// 위로 올려 감상 모드로 두고, 입력이 들어오면 바로 내린다.
///
/// 종료 감지가 핵심이다. 배경 창은 `ignoresMouseEvents`라 입력을 못 받고, 전역
/// 이벤트 모니터는 권한 프롬프트를 띄운다(이 앱의 권한 절약 원칙에 어긋남). 그래서
/// **떠 있는 동안에만** 빠른 타이머로 `PowerMonitor.idleSeconds()`(권한 불요)를
/// 폴링해, 입력이 들어오는 즉시 내린다. 평소엔 느린 타이머만 돌아 전력을 아낀다.
@MainActor
final class IdleFullscreenController {
    static let enabledKey = "wallflow.idleFullscreenEnabled"
    static let thresholdKey = "wallflow.idleFullscreenSeconds"
    static let defaultThreshold: TimeInterval = 60

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var thresholdSeconds: TimeInterval {
        guard let v = UserDefaults.standard.object(forKey: thresholdKey) as? Double,
              v.isFinite, v > 0 else { return defaultThreshold }
        return v
    }

    private let setRaised: (Bool) -> Void
    private var watchTimer: Timer?
    private var fastTimer: Timer?
    private(set) var isActive = false

    init(setRaised: @escaping (Bool) -> Void) {
        self.setRaised = setRaised
    }

    /// 설정대로 다시 건다. 토글이 바뀔 때마다 부르면 된다(멱등).
    func reload() {
        watchTimer?.invalidate()
        watchTimer = nil
        if isActive { deactivate() }   // 끄면 떠 있던 것도 내린다
        guard Self.isEnabled else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkActivate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    func stop() {
        watchTimer?.invalidate(); watchTimer = nil
        if isActive { deactivate() }
    }

    private func checkActivate() {
        guard !isActive, shouldShow() else { return }
        activate()
    }

    private func checkDeactivate() {
        guard isActive, !shouldShow() else { return }
        deactivate()
    }

    private func shouldShow() -> Bool {
        guard IdleFullscreen.shouldShow(
            enabled: Self.isEnabled,
            idleSeconds: PowerMonitor.idleSeconds(),
            thresholdSeconds: Self.thresholdSeconds) else { return false }
        // 영상을 보는 중이면 입력이 없어도 비켜 준다. 어서션 조회는 유휴 조건이 찬 뒤에만.
        return !Self.otherAppKeepsDisplayAwake()
    }

    /// 다른 앱이 화면을 켜 두라는 전원 어서션을 들고 있나(영상 재생 등).
    private static func otherAppKeepsDisplayAwake() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let raw = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let byPID = Dictionary(uniqueKeysWithValues: raw.map { ($0.key.int32Value, $0.value) })
        return IdleFullscreen.otherAppKeepsDisplayAwake(
            assertionsByPID: byPID, selfPID: ProcessInfo.processInfo.processIdentifier)
    }

    private func activate() {
        isActive = true
        setRaised(true)
        // 마우스를 움직이면 바로 사라져야 한다. 5초 폴링으론 먹통처럼 느껴진다.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDeactivate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func deactivate() {
        fastTimer?.invalidate(); fastTimer = nil
        isActive = false
        setRaised(false)
    }
}
