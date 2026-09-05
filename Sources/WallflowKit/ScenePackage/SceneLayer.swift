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

/// 스크립트에 넘기는 사용자 설정값 하나.
///
/// 실물 시계의 `scriptproperties`가 `{delimiter: ":", showSeconds: 0, use24hFormat: 1}`이다.
/// **수만 담으면 안 된다** — `delimiter`를 버리면 스크립트가
/// `"00" + undefined + "22"`를 만들어 시계가 `00undefined22`로 나온다.
/// Bool을 따로 두지 않는다. `JSONSerialization`은 JSON의 `true`와 정수 `1`을 모두
/// `NSNumber`로 주고 둘 다 `as? Bool`을 통과해서, 구분하려 들면 정수 0/1이 조용히
/// 참·거짓으로 바뀐다. 자바스크립트는 0과 false, 1과 true를 같게 다루므로 구분할
/// 실익도 없다. 수와 문자열 둘이면 충분하다.
public enum ScriptPropertyValue: Equatable, Sendable {
    case number(Double)
    case text(String)

    /// JavaScriptCore에 넘길 값.
    public var jsValue: Any {
        switch self {
        case .number(let d): return d
        case .text(let s): return s
        }
    }
}

/// 글자를 그리는 레이어.
///
/// 보유한 실물 씬의 텍스트 13개 중 12개가 `value` 대신 스크립트로 글자를 만든다.
/// 시계·날짜·요일이 그렇다. 그래서 스크립트가 이 레이어의 본체다.
public struct TextLayer: Equatable, Sendable {
    /// 스크립트가 없을 때 그대로 그리는 글자. 스크립트가 있으면 첫 입력값이 된다.
    public let value: String
    /// `.pkg`나 assets 안의 폰트 경로. `systemfont_*`는 파일이 아니라 시스템 폰트 이름이다.
    public let fontPath: String
    /// 0~1 실수 셋. 파티클의 색과 달리 여기는 이미 0~1이다(실물 확인).
    public let color: Vec3
    /// 레이어 스크립트 본문. 없으면 nil.
    public let script: String?
    /// 스크립트에 넘길 사용자 설정값. 스크립트 안의 빌더를 이긴다.
    public let scriptProperties: [String: ScriptPropertyValue]

    /// 폰트가 파일이 아니라 시스템 폰트 이름인지.
    public var usesSystemFont: Bool { fontPath.hasPrefix("systemfont") }

    public init(
        value: String, fontPath: String, color: Vec3,
        script: String?, scriptProperties: [String: ScriptPropertyValue]
    ) {
        self.value = value
        self.fontPath = fontPath
        self.color = color
        self.script = script
        self.scriptProperties = scriptProperties
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
    /// 파티클 시스템. 프리셋과 텍스처 경로, 그리고 합성 방식을 담는다.
    case particle(preset: ParticlePreset, texturePath: String, blend: ParticleBlendMode)
    /// 글자. 스크립트가 값을 만들 수 있다.
    case text(TextLayer)
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
    /// 0~1. 씬이 정한 레이어 투명도.
    /// 무시하면 반투명하게 설계된 UI가 불투명한 검은 상자로 그려진다.
    public let alpha: Double
    /// 텍스처에 곱하는 색. 기본은 흰색(원본 그대로).
    public let tint: Vec3
    /// 화면 평면 회전(라디안). 부모 사슬의 회전이 이미 합쳐져 있다.
    public let rotation: Double
    public let content: LayerContent
    /// 스크립트가 붙어 있지만 우리가 아직 돌리지 못하는 속성 이름들.
    ///
    /// 조용히 무시하면 사용자는 레이어가 왜 안 움직이는지 알 수 없다. 실물에서
    /// `cursor` 레이어의 origin은 `input.cursorWorldPosition`을, `Audio bar`는
    /// 오디오를 요구한다 — 둘 다 M6다. 그동안은 편집기에 저장된 좌표로 그린다.
    public let unrunScripts: [String]

    public init(
        id: Int, name: String, visible: Bool, origin: Vec3, size: Vec2,
        content: LayerContent, unrunScripts: [String] = [],
        alpha: Double = 1, tint: Vec3 = Vec3(x: 1, y: 1, z: 1),
        rotation: Double = 0
    ) {
        self.alpha = alpha
        self.tint = tint
        self.rotation = rotation
        self.id = id
        self.name = name
        self.visible = visible
        self.origin = origin
        self.size = size
        self.content = content
        self.unrunScripts = unrunScripts
    }
}
