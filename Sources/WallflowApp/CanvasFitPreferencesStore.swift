import Foundation
import WallflowKit

/// 배경화면마다 고른 화면 맞춤 방식을 UserDefaults에 둔다. `PowerPreferencesStore`와
/// 같은 자리(사전 하나)에 담는다 — 씬을 열 때(`SceneRenderer.start`)와 메뉴가
/// 값을 바꿀 때(`AppCoordinator`) 같은 곳을 본다.
enum CanvasFitPreferencesStore {
    static let key = "wallflow.canvasFitByWallpaper"

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func mode(for wallpaperID: String) -> CanvasFit.Mode {
        CanvasFit.mode(for: wallpaperID, in: load())
    }

    static func setMode(_ mode: CanvasFit.Mode, for wallpaperID: String) {
        UserDefaults.standard.set(
            CanvasFit.settingMode(mode, for: wallpaperID, in: load()), forKey: key)
    }
}
