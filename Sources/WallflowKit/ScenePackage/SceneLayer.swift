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
    /// 상자 안에서의 가로 정렬.
    public let horizontalAlign: TextAlignment
    /// 상자 안에서의 세로 정렬.
    public let verticalAlign: TextVerticalAlignment
    /// 넘칠 때의 줄바꿈·말줄임 규칙.
    public let wrapping: TextWrapping
    /// 그림자. 씬이 끄면 nil.
    public let shadow: TextShadow?

    /// 폰트가 파일이 아니라 시스템 폰트 이름인지.
    public var usesSystemFont: Bool { fontPath.hasPrefix("systemfont") }

    public init(
        value: String, fontPath: String, color: Vec3,
        script: String?, scriptProperties: [String: ScriptPropertyValue],
        horizontalAlign: TextAlignment = .center,
        verticalAlign: TextVerticalAlignment = .center,
        wrapping: TextWrapping = .none,
        shadow: TextShadow? = nil
    ) {
        self.shadow = shadow
        self.horizontalAlign = horizontalAlign
        self.verticalAlign = verticalAlign
        self.wrapping = wrapping
        self.value = value
        self.fontPath = fontPath
        self.color = color
        self.script = script
        self.scriptProperties = scriptProperties
    }
}

/// 글자를 상자 안 어디에 붙이는지. 실물에 left·center·right가 모두 나온다.
/// 무시하고 전부 가운데 두면 좌·우 정렬된 시계와 곡 제목이 제자리에서 벗어난다.
public enum TextAlignment: String, Sendable, Equatable {
    case left, center, right
}

/// 상자 안에서의 세로 정렬. 실물에 center와 top이 나온다.
public enum TextVerticalAlignment: String, Sendable, Equatable {
    case top, center, bottom
}

/// 글자 뒤에 까는 그림자. 씬이 켤 때만 그린다.
public struct TextShadow: Equatable, Sendable {
    public let color: Vec3
    /// 씬 단위 오프셋. y는 아래로 양수다(실물 값이 4,4이고 오른쪽 아래로 진다).
    public let offset: Vec2
    public let blur: Double
    public let opacity: Double

    public init(color: Vec3, offset: Vec2, blur: Double, opacity: Double) {
        self.color = color
        self.offset = offset
        self.blur = blur
        self.opacity = opacity
    }
}

/// 글자가 상자를 넘칠 때의 처리. 씬이 정한다.
public struct TextWrapping: Equatable, Sendable {
    /// 줄바꿈할 폭(씬 단위). 0이면 줄바꿈하지 않는다.
    public let maxWidth: Double
    /// 최대 줄 수. 0이면 제한 없음.
    public let maxRows: Int
    /// 잘릴 때 말줄임표를 붙이는지.
    public let usesEllipsis: Bool
    /// 씬이 정한 글자 크기. 줄바꿈 폭을 픽셀로 옮길 때 비율로만 쓴다.
    public let pointSize: Double

    public init(maxWidth: Double, maxRows: Int, usesEllipsis: Bool, pointSize: Double) {
        self.maxWidth = maxWidth
        self.maxRows = maxRows
        self.usesEllipsis = usesEllipsis
        self.pointSize = pointSize
    }

    public static let none = TextWrapping(
        maxWidth: 0, maxRows: 0, usesEllipsis: false, pointSize: 0)
}

/// 소리만 내는 레이어. 그림은 없다.
public struct SoundLayer: Equatable, Sendable {
    /// `.pkg`나 assets 안의 소리 파일 경로들. 여러 개면 첫 번째로 재생 가능한 것을 쓴다.
    public let paths: [String]
    /// 0~1.
    public let volume: Double
    /// 끝나면 처음부터 다시 트는지.
    public let loops: Bool
    /// 씬을 켤 때 소리 없이 시작하는지.
    public let startsSilent: Bool

    public init(paths: [String], volume: Double, loops: Bool, startsSilent: Bool) {
        self.paths = paths
        self.volume = volume
        self.loops = loops
        self.startsSilent = startsSilent
    }
}

/// 레이어가 무엇을 그리는지.
public enum LayerContent: Equatable, Sendable {
    /// .pkg 또는 assets 안의 텍스처 경로.
    case image(texturePath: String)
    /// 3D 메시. 원근 씬의 본체다. `skin`은 메시가 든 재질 목록의 번호다.
    case model(path: String, skin: Int)
    /// 재질이 **자기 셰이더**를 가진 이미지. 그림을 텍스처로 붙이는 게 아니라
    /// 셰이더가 그림을 만든다(실물 원근 씬의 배경 구름 `ps2menu`, 9개 레이어).
    /// 보통 이미지처럼 텍스처만 붙이면 셰이더의 입력 잡음이 그대로 보인다.
    case shadedImage(materialPath: String, texturePath: String)
    /// 텍스처가 MP4인 레이어. 매 프레임 갱신된다.
    case video(texturePath: String)
    /// 셰이더 `flat` 기반의 단색 사각형. 텍스처가 없다.
    case solidColor(Vec3)
    /// 파티클 시스템. 프리셋과 텍스처 경로, 그리고 합성 방식을 담는다.
    /// 파티클 시스템. 프리셋과 텍스처 경로, 합성 방식, 그리고 굴절이면
    /// 법선 지도의 경로.
    ///
    /// 굴절 파티클은 **뒤에 이미 그려진 화면**을 법선 지도로 밀어 읽어 곱한다.
    /// 유리구슬과 충격파가 그렇게 배경을 휘게 한다.
    case particle(preset: ParticlePreset, texturePath: String, blend: ParticleBlendMode,
                  normalPath: String? = nil, refractAmount: Double = 0.05)
    /// 글자. 스크립트가 값을 만들 수 있다.
    case text(TextLayer)
    /// 소리. 그리지 않는다.
    case sound(SoundLayer)
    /// 그리지 못하는 레이어. 이유를 남겨 나중에 무엇을 만들지 알 수 있게 한다.
    /// 화면 전체에 거는 후처리 레이어. 자기 그림이 없고, **그 아래까지 합성된
    /// 화면**을 받아 이펙트를 건다. 실물 씬 하나가 마지막 레이어로 filmgrain·vhs·
    /// waterripple·chromaticaberration을 이렇게 건다.
    case postProcess
    /// 합성 레이어. 자기 그림 대신 **그 아래까지 합성된 화면**을 받아 이펙트를 걸고,
    /// 그 결과를 자기 자리에 그린다. 오디오 막대가 이 형태다.
    /// 후처리와 달리 씬 중간에 놓일 수 있어서, 그 지점까지의 화면이 입력이다.
    case composition
    case unsupported(reason: String)
}

/// 레이어 속성에 붙은 스크립트. 어느 속성인지 알아야 결과를 어떻게 읽을지 정해진다 —
/// `visible`은 불리언, `alpha`는 0~1 실수다.
public struct DisplayScript: Equatable, Sendable {
    public enum Property: String, Equatable, Sendable {
        case visible
        case alpha
    }
    public let property: Property
    public let source: String

    public init(property: Property, source: String) {
        self.property = property
        self.source = source
    }
}

/// 레이어에 걸린 이펙트 하나와, 그 파일이 있던 폴더.
/// 폴더를 같이 들고 다녀야 재질과 셰이더의 상대 경로가 풀린다.
public struct LayerEffect: Equatable, Sendable {
    public let definition: EffectDefinition
    public let base: String

    public init(definition: EffectDefinition, base: String) {
        self.definition = definition
        self.base = base
    }
}

/// 레이어 속성 하나에 붙은 스크립트. `SceneScriptHost`가 씬 단위로 돌린다.
///
/// `property`는 씬 JSON의 키 그대로다(`origin`, `angles`, `scale`, `alpha`,
/// `color`, `visible`, `size`, `text`). 스크립트의 `update(value)`는 그 속성의
/// 현재 값을 받고 새 값을 돌려준다.
public struct LayerScript: Equatable, Sendable {
    public let property: String
    public let source: String
    /// 그 속성에 딸린 `scriptproperties`. 스크립트 안의 빌더 기본값을 덮어쓴다.
    public let scriptProperties: [String: ScriptPropertyValue]

    public init(property: String, source: String,
                scriptProperties: [String: ScriptPropertyValue] = [:]) {
        self.property = property
        self.source = source
        self.scriptProperties = scriptProperties
    }
}

/// 이미지 레이어에 심은 퍼펫 워프. 모델 JSON의 `puppet`이 메시를, 오브젝트의
/// `animationlayers`가 어떤 애니메이션을 어떻게 틀지 말한다.
public struct PuppetSpec: Equatable, Sendable {
    public struct AnimationLayer: Equatable, Sendable {
        public let id: Int
        public let rate: Double
        public let blend: Double
        public let visible: Bool

        public init(id: Int, rate: Double = 1, blend: Double = 1, visible: Bool = true) {
            self.id = id
            self.rate = rate
            self.blend = blend
            self.visible = visible
        }
    }

    /// `*_puppet.mdl` 경로.
    public let path: String
    public let animations: [AnimationLayer]

    public init(path: String, animations: [AnimationLayer]) {
        self.path = path
        self.animations = animations
    }

    /// 씬 오브젝트의 `animationlayers` 배열을 읽는다. 없거나 비었으면 nil.
    public static func parse(path: String, animationLayers raw: Any?) -> PuppetSpec? {
        var animations: [AnimationLayer] = []
        for case let entry as [String: Any] in (raw as? [Any] ?? []) {
            guard let id = (entry["animation"] as? NSNumber)?.intValue else { continue }
            func number(_ key: String, _ fallback: Double) -> Double {
                guard let n = entry[key] as? NSNumber, n.doubleValue.isFinite else { return fallback }
                return n.doubleValue
            }
            animations.append(AnimationLayer(
                id: id, rate: number("rate", 1), blend: min(max(number("blend", 1), 0), 1),
                visible: (entry["visible"] as? Bool) ?? true))
        }
        return PuppetSpec(path: path, animations: animations)
    }
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
    /// 부모 사슬이 합쳐진 크기 배율.
    ///
    /// 이미지 레이어는 `size`에 이미 곱해져 있지만, 파티클은 크기가 프리셋에서
    /// 오므로 렌더러가 따로 곱해야 한다. 무시하면 씬이 의도한 것보다 크거나
    /// 작게 날린다 — 실물 배율이 0.44부터 9.0까지 있다.
    public let scale: Vec3
    /// 마우스 시차에서 이 레이어가 얼마나 밀리는지. 실물 값이 -0.67~0.5다.
    /// 음수면 반대로 밀려 앞뒤 느낌을 만든다.
    public let parallaxDepth: Double
    /// 이 레이어를 **아래 화면과** 섞는 방식. 0이면 보통(알파 합성)이다.
    ///
    /// 값과 식은 WE 자신의 `shaders/common_blending.h`에 있다 — 1이 어둡게,
    /// 7이 스크린, 11이 오버레이 하는 식으로 32가지다. 무시하면 오버레이로
    /// 얹으라던 시계가 불투명한 흰 글자로 찍힌다.
    public let colorBlendMode: Int
    /// 색에 곱하는 밝기. 기본 1.
    ///
    /// **섞는 방식과 짝이다.** 실물에서 밝기 5.56짜리 시계는 오버레이로 섞이는
    /// 것을 전제로 그 값이다 — 하나만 넣으면 둘 다 없는 것보다 나쁘다.
    public let brightness: Double
    public let content: LayerContent
    /// 이 레이어에 걸린 이펙트들. 순서대로 이어서 건다.
    public let effects: [LayerEffect]
    /// `visible`/`alpha`에 붙은 스크립트 본문들. 미디어 위젯이 여기서 스스로 숨는다.
    public let displayScripts: [DisplayScript]
    /// 스크립트가 붙어 있지만 우리가 아직 돌리지 못하는 속성 이름들.
    ///
    /// 조용히 무시하면 사용자는 레이어가 왜 안 움직이는지 알 수 없다. 실물에서
    /// `cursor` 레이어의 origin은 `input.cursorWorldPosition`을, `Audio bar`는
    /// 오디오를 요구한다 — 둘 다 M6다. 그동안은 편집기에 저장된 좌표로 그린다.
    public let unrunScripts: [String]
    /// 이 레이어의 속성 스크립트 전부. 숨은 레이어의 것도 돈다 — 실물 원근 씬은
    /// 카메라·프리즘 로직을 **보이지 않는** 레이어의 `visible` 스크립트에 둔다.
    public let scripts: [LayerScript]
    /// 오브젝트 자체의 회전(도, XYZ). 부모를 합치지 않은 값이다 —
    /// 스크립트의 `thisLayer.angles`가 이것이고, 3D 메시의 세 축 회전이 여기서 온다.
    public let angles: Vec3
    /// 오브젝트 자체의 origin·scale. 부모를 합치지 않은 값이라 스크립트가 읽고 쓴다.
    public let localOrigin: Vec3
    public let localScale: Vec3
    /// 이미지 레이어의 퍼펫 워프. 없으면 nil.
    public let puppet: PuppetSpec?
    /// 부모 오브젝트의 id. 스크립트의 `getChildren()`이 이걸로 자식을 찾는다.
    public let parentID: Int?

    public init(
        id: Int, name: String, visible: Bool, origin: Vec3, size: Vec2,
        content: LayerContent, unrunScripts: [String] = [],
        effects: [LayerEffect] = [],
        alpha: Double = 1, tint: Vec3 = Vec3(x: 1, y: 1, z: 1),
        rotation: Double = 0, displayScripts: [DisplayScript] = [],
        scale: Vec3 = Vec3(x: 1, y: 1, z: 1),
        parallaxDepth: Double = 0,
        colorBlendMode: Int = 0,
        brightness: Double = 1,
        scripts: [LayerScript] = [],
        angles: Vec3 = Vec3(x: 0, y: 0, z: 0),
        localOrigin: Vec3? = nil,
        localScale: Vec3? = nil,
        puppet: PuppetSpec? = nil,
        parentID: Int? = nil
    ) {
        self.puppet = puppet
        self.parentID = parentID
        self.scripts = scripts
        self.angles = angles
        self.localOrigin = localOrigin ?? origin
        self.localScale = localScale ?? scale
        self.colorBlendMode = colorBlendMode
        self.brightness = brightness
        self.displayScripts = displayScripts
        self.scale = scale
        self.parallaxDepth = parallaxDepth
        self.alpha = alpha
        self.tint = tint
        self.rotation = rotation
        self.id = id
        self.name = name
        self.visible = visible
        self.origin = origin
        self.size = size
        self.content = content
        self.effects = effects
        self.unrunScripts = unrunScripts
    }

    /// 내용만 바꾼 사본. 배치와 스크립트는 그대로 둔다.
    public func replacingContent(_ content: LayerContent) -> SceneLayer {
        SceneLayer(
            id: id, name: name, visible: visible, origin: origin, size: size,
            content: content, unrunScripts: unrunScripts, effects: effects,
            alpha: alpha, tint: tint, rotation: rotation, displayScripts: displayScripts,
            scale: scale, parallaxDepth: parallaxDepth,
            colorBlendMode: colorBlendMode, brightness: brightness,
            scripts: scripts, angles: angles, localOrigin: localOrigin, localScale: localScale,
            puppet: puppet, parentID: parentID)
    }

    /// 스크립트와 오브젝트 자체 변환을 붙인 사본. 나머지는 그대로다.
    public func attachingScripts(_ scripts: [LayerScript], angles: Vec3,
                                 localOrigin: Vec3, localScale: Vec3,
                                 parentID: Int? = nil) -> SceneLayer {
        SceneLayer(
            id: id, name: name, visible: visible, origin: origin, size: size,
            content: content, unrunScripts: unrunScripts, effects: effects,
            alpha: alpha, tint: tint, rotation: rotation, displayScripts: displayScripts,
            scale: scale, parallaxDepth: parallaxDepth,
            colorBlendMode: colorBlendMode, brightness: brightness,
            scripts: scripts, angles: angles, localOrigin: localOrigin, localScale: localScale,
            puppet: puppet, parentID: parentID)
    }
}


/// 원근 씬의 카메라. 직교 씬에는 없다.
///
/// `general`의 `fov`·`nearz`·`farz`와 `camera {eye, center, up}`에서 온다.
/// **기본값은 문서에 없다.** 실물 원근 씬은 스크립트가 `setCameraTransforms`로
/// 눈 위치를 정하므로 기본값이 화면에 보이는 경우가 드물다. 편집기 예제 씬
/// (`scenes/modeleditor`)의 fov 50·nearz 0.1·farz 10000을 기본으로 두고,
/// 눈은 원점을 보는 (0, 0, 100)으로 둔다 — 근거가 약한 값이라 스크립트가
/// 덮어쓰기 전까지만 쓰인다.
public struct SceneCamera: Equatable, Sendable {
    public var fov: Double
    public var nearZ: Double
    public var farZ: Double
    public var eye: Vec3
    public var center: Vec3
    public var up: Vec3

    public init(fov: Double = 50, nearZ: Double = 0.1, farZ: Double = 10000,
                eye: Vec3 = Vec3(x: 0, y: 0, z: 100),
                center: Vec3 = Vec3(x: 0, y: 0, z: 0),
                up: Vec3 = Vec3(x: 0, y: 1, z: 0)) {
        self.fov = fov
        self.nearZ = nearZ
        self.farZ = farZ
        self.eye = eye
        self.center = center
        self.up = up
    }

    /// `general`에서 읽는다. 값은 수이거나 `{"user": …, "value": …}` 객체다.
    static func parse(_ general: [String: Any]) -> SceneCamera {
        func number(_ raw: Any?, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
            let value = (raw as? [String: Any])?["value"] ?? raw
            guard let d = (value as? NSNumber)?.doubleValue, d.isFinite else { return fallback }
            return Swift.min(Swift.max(d, lo), hi)
        }
        var camera = SceneCamera()
        camera.fov = number(general["fov"], 50, min: 1, max: 179)
        camera.nearZ = number(general["nearz"], 0.1, min: 0.0001, max: 1e6)
        camera.farZ = number(general["farz"], 10000, min: camera.nearZ * 1.001, max: 1e9)
        if let block = general["camera"] as? [String: Any] {
            if let eye = (block["eye"] as? String).flatMap(Vec3.parse) { camera.eye = eye }
            if let center = (block["center"] as? String).flatMap(Vec3.parse) { camera.center = center }
            if let up = (block["up"] as? String).flatMap(Vec3.parse) { camera.up = up }
        }
        return camera
    }
}
