import Foundation

/// 배경화면마다 따로 저장하는 소리 크기(0~1)의 순수 로직.
///
/// 저장소(UserDefaults)는 App의 `VolumePreferencesStore`가 감싼다. 여기는
/// 사전 하나를 읽고 쓰는 순수 함수만 둬서 테스트할 수 있게 한다
/// (`CanvasFit`과 같은 구성).
///
/// **명시값이 없으면 nil을 돌려준다** — 호출하는 쪽이 종류에 맞는 기본값을 고른다:
/// 씬은 기존 전역 크기로 폴백(하위호환), 비디오는 음소거(0)로 둬서 로컬 영상을
/// 추가하자마자 바탕화면에서 소리가 터지지 않게 한다.
public enum WallpaperVolume {
    /// 이 배경화면에 사용자가 **명시적으로** 정한 크기. 없으면 nil. 0~1로 죈다.
    public static func explicitVolume(for id: String, in dict: [String: Double]) -> Double? {
        guard let v = dict[id], v.isFinite else { return nil }
        return Swift.min(Swift.max(v, 0), 1)
    }

    /// 크기를 정한 새 사전을 돌려준다(0~1로 죈다). 원본은 바꾸지 않는다.
    public static func setting(_ volume: Double, for id: String,
                               in dict: [String: Double]) -> [String: Double] {
        var out = dict
        out[id] = Swift.min(Swift.max(volume, 0), 1)
        return out
    }
}
