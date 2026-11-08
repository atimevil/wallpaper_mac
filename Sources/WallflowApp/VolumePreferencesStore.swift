import Foundation
import WallflowKit

/// 배경화면마다 고른 소리 크기를 UserDefaults에 둔다. `CanvasFitPreferencesStore`와
/// 같은 구성 — 순수 로직은 `WallpaperVolume`(Kit)에 있고 여기선 저장소만 감싼다.
///
/// 명시값이 없으면 nil이다. 적용하는 쪽이 종류별 기본을 고른다:
/// 씬은 기존 전역 크기(`SceneRenderer.soundVolume`)로, 비디오는 음소거로.
enum VolumePreferencesStore {
    static let key = "wallflow.volumeByWallpaper"

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    /// 이 배경화면에 사용자가 명시적으로 정한 크기(없으면 nil).
    static func explicitVolume(for wallpaperID: String) -> Double? {
        WallpaperVolume.explicitVolume(for: wallpaperID, in: load())
    }

    static func setVolume(_ volume: Double, for wallpaperID: String) {
        UserDefaults.standard.set(
            WallpaperVolume.setting(volume, for: wallpaperID, in: load()), forKey: key)
    }

    /// 슬라이더·메뉴에 보여줄 크기. 명시값이 있으면 그걸, 없으면 종류별 기본:
    /// 비디오는 음소거(0), 그 밖(씬·웹)은 기존 전역 크기.
    /// 전역 크기(`SceneRenderer.soundVolume`)가 MainActor라 이 함수도 그렇다.
    @MainActor
    static func displayVolume(for item: WallpaperItem?) -> Double {
        guard let item else { return SceneRenderer.soundVolume }
        return explicitVolume(for: item.id)
            ?? (item.type == .video ? 0 : SceneRenderer.soundVolume)
    }
}
