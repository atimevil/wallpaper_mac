import Foundation
import WallflowKit

/// 재생 규칙을 UserDefaults에 둔다. 키를 한곳에 모아 설정 창과 전력 감시가
/// 같은 값을 본다.
enum PowerPreferencesStore {
    static let occludedKey = "wallflow.power.pauseWhenOccluded"
    static let fullscreenKey = "wallflow.power.pauseInFullscreen"
    static let idleKey = "wallflow.power.idlePauseSeconds"
    static let batteryFPSKey = "wallflow.power.batteryFPS"
    /// 예전 켬/끔 스위치. 끈 사람은 "전원과 같게"로 옮긴다.
    static let legacyBatteryKey = "wallflow.power.reduceOnBattery"
    static let fpsKey = "wallflow.power.targetFPS"

    /// 배터리 규칙의 이름. 설정 창과 메뉴바가 같이 쓴다.
    static let batteryChoices: [(String, Int)] = [
        ("전원과 같게", 60), ("30", 30), ("15", 15), ("멈춤", 0),
    ]

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
        if let fps = defaults.object(forKey: batteryFPSKey) as? Int,
           PowerPreferences.allowedBatteryFPS.contains(fps) {
            prefs.batteryFPS = fps
        } else if defaults.object(forKey: legacyBatteryKey) != nil,
                  !defaults.bool(forKey: legacyBatteryKey) {
            prefs.batteryFPS = 60
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
        defaults.set(prefs.batteryFPS, forKey: batteryFPSKey)
        defaults.removeObject(forKey: legacyBatteryKey)
        defaults.set(prefs.targetFPS, forKey: fpsKey)
    }
}
