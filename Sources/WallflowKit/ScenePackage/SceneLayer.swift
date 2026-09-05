import Foundation

public struct Vec3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    /// Wallpaper Engine은 벡터를 "1.00000 2.00000 3.00000" 문자열로 쓴다.
    /// Double(_:)은 "inf"와 "nan"도 받아들인다. 그런 좌표가 통과하면
    /// 렌더러가 NaN 지오메트리를 받아 아무것도 그리지 않는다. 유한값만 허용한다.
    public static func parse(_ string: String) -> Vec3? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy(\.isFinite) else { return nil }
        return Vec3(x: parts[0], y: parts[1], z: parts[2])
    }
}

public struct Vec2: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }

    /// Double(_:)은 "inf"와 "nan"도 받아들인다. 그런 좌표가 통과하면
    /// 렌더러가 NaN 지오메트리를 받아 아무것도 그리지 않는다. 유한값만 허용한다.
    public static func parse(_ string: String) -> Vec2? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy(\.isFinite) else { return nil }
        return Vec2(x: parts[0], y: parts[1])
    }
}

/// 레이어가 무엇을 그리는지.
public enum LayerContent: Equatable, Sendable {
    /// .pkg 또는 assets 안의 텍스처 경로.
    case image(texturePath: String)
    /// 텍스처가 MP4인 레이어. 매 프레임 갱신된다.
    case video(texturePath: String)
    /// 셰이더 `flat` 기반의 단색 사각형. 텍스처가 없다.
    case solidColor(Vec3)
    /// 파티클 시스템. 프리셋과 텍스처 경로를 담는다.
    case particle(preset: ParticlePreset, texturePath: String)
    /// 그리지 못하는 레이어. 이유를 남겨 나중에 무엇을 만들지 알 수 있게 한다.
    case unsupported(reason: String)
}

/// 씬의 레이어 하나. origin은 오브젝트의 중심이고 직교 공간 좌표다.
public struct SceneLayer: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let visible: Bool
    public let origin: Vec3
    public let size: Vec2
    public let content: LayerContent
}
