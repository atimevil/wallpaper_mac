import Foundation
import WallflowKit

/// 재생 규칙을 UserDefaults에 둔다. 키를 한곳에 모아 설정 창과 전력 감시가
/// 같은 값을 본다.
enum PowerPreferencesStore {
    static let occludedKey = "wallflow.power.pauseWhenOccluded"
    static let fullscreenKey = "wallflow.power.pauseInFullscreen"
    static let idleKey = "wallflow.power.idlePauseSeconds"
    static let batteryKey = "wallflow.power.reduceOnBattery"
    static let fpsKey = "wallflow.power.targetFPS"

    static func load() -> PowerPreferences {
        let defaults = UserDefaults.standard
        var prefs = PowerPreferences.standard
        // 키가 없으면 기본값이다. `bool(forKey:)`는 없을 때 false를 줘서 켜짐이
        // 기본인 항목이 조용히 꺼진다 — 있는지부터 본다.
        if defaults.object(forKey: occludedKey) != nil {
            prefs.pauseWhenOccluded = defaults.bool(forKey: occludedKey)
        }
        if defaults.object(forKey: fullscreenKey) != nil {
            prefs.pauseInFullscreen = defaults.bool(forKey: fullscreenKey)
        }
        if let idle = defaults.object(forKey: idleKey) as? Double, idle.isFinite, idle >= 0 {
            prefs.idlePauseSeconds = idle
        }
        if defaults.object(forKey: batteryKey) != nil {
            prefs.reduceOnBattery = defaults.bool(forKey: batteryKey)
        }
        if let fps = defaults.object(forKey: fpsKey) as? Int,
           PowerPreferences.allowedFPS.contains(fps) {
            prefs.targetFPS = fps
        }
        return prefs
    }

    static func save(_ prefs: PowerPreferences) {
        let defaults = UserDefaults.standard
        defaults.set(prefs.pauseWhenOccluded, forKey: occludedKey)
        defaults.set(prefs.pauseInFullscreen, forKey: fullscreenKey)
        defaults.set(prefs.idlePauseSeconds, forKey: idleKey)
        defaults.set(prefs.reduceOnBattery, forKey: batteryKey)
        defaults.set(prefs.targetFPS, forKey: fpsKey)
    }
}
