import AppKit
import IOKit.ps
import WallflowKit

/// 시스템에서 전력 신호를 모아 PowerPolicy에 넣고, 결과가 바뀔 때만 알린다.
///
/// 가림 상태만 밖에서 받아온다. 배경 윈도우를 소유한 쪽은 DisplayManager이고,
/// 밀어넣는 방식으로는 실제로 가려지는 순간을 놓치기 때문에 poll 시점에 물어본다.
/// 전부 메인 스레드에서 동작한다. 타이머는 메인 런루프에 걸리고, 결정은
/// 그대로 렌더러(AppKit 뷰)로 흘러가므로 다른 격리에서 쓸 이유가 없다.
@MainActor
final class PowerMonitor {
    private let occlusionProvider: () -> Bool
    private let onChange: (PlaybackDirective) -> Void
    private var timer: Timer?
    private var last: PlaybackDirective?

    init(
        occlusionProvider: @escaping () -> Bool,
        onChange: @escaping (PlaybackDirective) -> Void
    ) {
        self.occlusionProvider = occlusionProvider
        self.onChange = onChange
    }

    func start() {
        // 전력 상태는 급하게 변하지 않는다. 5초면 충분하고 그 자체로 저렴하다.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            // 메인 런루프에 등록하므로 항상 메인에서 불린다.
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let signals = PowerSignals(
            isOccluded: occlusionProvider(),
            isFullscreenAppActive: Self.isFullscreenAppActive(),
            idleSeconds: Self.idleSeconds(),
            isOnBattery: Self.isOnBattery(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isThermallyPressured: Self.isThermallyPressured()
        )
        let directive = PowerPolicy.directive(for: signals)
        guard directive != last else { return }
        last = directive
        onChange(directive)
    }

    /// 마지막 사용자 입력 이후 경과 시간.
    /// kCGAnyInputEventType은 Swift에서 CGEventType으로 안전하게 만들 수 없으므로
    /// 관심 있는 이벤트들 중 가장 최근 것을 고른다.
    private static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .keyDown, .flagsChanged, .scrollWheel,
        ]
        let elapsed = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return elapsed.min() ?? 0
    }

    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey as String] as? String
            else { continue }
            if state == (kIOPSBatteryPowerValue as String) { return true }
        }
        return false
    }

    private static func isThermallyPressured() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// 전체화면 앱이 데스크톱을 덮고 있는지 화면 목록으로 판단한다.
    private static func isFullscreenAppActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        guard let mainFrame = NSScreen.main?.frame else { return false }

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // 메인 화면을 전부 덮는 일반 레이어 윈도우 = 전체화면으로 본다.
            if rect.width >= mainFrame.width && rect.height >= mainFrame.height {
                return true
            }
        }
        return false
    }
}
