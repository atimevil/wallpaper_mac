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

/// 파티클을 배경 위에 어떻게 합성하는지. 머티리얼의 `blending` 값이다.
///
/// 실물 씬을 조사한 결과 둘 다 실제로 쓰인다 — 눈·비·먼지·광선은 additive,
/// 벚꽃(leaves5)은 translucent다. 하나로 뭉치면 안 된다. 벚꽃을 additive로 그리면
/// 분홍 꽃잎이 밝은 배경 위에서 하얗게 날아간다.
public enum ParticleBlendMode: Equatable, Sendable {
    /// 색을 더한다. 빛나는 것(눈·광선·먼지)에 쓴다.
    case additive
    /// 알파로 섞는다. 불투명한 것(꽃잎)에 쓴다.
    case translucent
}

/// 레이어가 무엇을 그리는지.
public enum LayerContent: Equatable, Sendable {
    /// .pkg 또는 assets 안의 텍스처 경로.
    case image(texturePath: String)
    /// 텍스처가 MP4인 레이어. 매 프레임 갱신된다.
    case video(texturePath: String)
    /// 셰이더 `flat` 기반의 단색 사각형. 텍스처가 없다.
    case solidColor(Vec3)
    /// 파티클 시스템. 프리셋과 텍스처 경로, 그리고 합성 방식을 담는다.
    case particle(preset: ParticlePreset, texturePath: String, blend: ParticleBlendMode)
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
