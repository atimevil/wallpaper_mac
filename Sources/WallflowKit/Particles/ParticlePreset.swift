import Foundation

/// 이미터가 파티클에 주는 초기 조건.
///
/// 이름과 위치 말고도 둘이 더 있다. 실물에서 이 둘이 없으면 **불꽃놀이가 아예
/// 안 터진다** — 그 프리셋은 `rate: 0`이고 속도 초기화자도 없어서, 터뜨리는
/// 것도 날리는 것도 전부 이미터가 한다.
public struct ParticleEmitterBurst: Equatable, Sendable {
    /// 시스템이 만들어질 때 **한꺼번에** 생기는 개수.
    /// 공식 문서: "The number of particles which are created instantly when the
    /// particle system is created." `rate`가 0이면 이것만 나오고 끝난다.
    public var count: Int
    /// 이미터가 주는 초기 속력의 범위. 방향은 이미터가 뿌린 자리에서 바깥쪽이다.
    /// 공식 문서: "The minimum/maximum particle speed in conjunction with a
    /// movement Operator."
    public var speedMin: Double
    public var speedMax: Double

    public init(count: Int = 0, speedMin: Double = 0, speedMax: Double = 0) {
        self.count = count
        self.speedMin = speedMin
        self.speedMax = speedMax
    }

    public static let none = ParticleEmitterBurst()
    public var isEmpty: Bool { count == 0 && speedMax == 0 && speedMin == 0 }
}

public enum ParticleEmitter: Equatable, Sendable {
    case sphereRandom(rate: Double, origin: Vec3, directions: Vec3,
                      distanceMin: Double, distanceMax: Double,
                      burst: ParticleEmitterBurst = .none)
    case boxRandom(rate: Double, origin: Vec3, directions: Vec3,
                   distanceMin: Vec3, distanceMax: Vec3,
                   burst: ParticleEmitterBurst = .none)

    /// 시작할 때 한꺼번에 만들 개수와 초기 속력.
    public var burst: ParticleEmitterBurst {
        switch self {
        case .sphereRandom(_, _, _, _, _, let burst): return burst
        case .boxRandom(_, _, _, _, _, let burst): return burst
        }
    }

    /// 씬의 조정값을 얹는다. **방출 주기만** 바꾼다.
    ///
    /// 뿌리는 범위는 건드리지 않는다. 공식 문서가 못박고 있다 —
    /// "All factors are multiplied with the initializers and operators of your
    /// particle system"(IParticleSystemInstance). 이미터는 그 목록에 없다.
    ///
    /// 크기 배율을 범위에까지 곱했더니 비가 화면 일부에만 내렸다. 실물에서
    /// 원본 반경 1024가 0.65배로 줄어 가로의 3분의 2에만 비가 왔다.
    func scaled(rate factor: Double) -> ParticleEmitter {
        switch self {
        case .sphereRandom(let r, let o, let d, let lo, let hi, let burst):
            return .sphereRandom(rate: r * factor, origin: o, directions: d,
                                 distanceMin: lo, distanceMax: hi, burst: burst)
        case .boxRandom(let r, let o, let d, let lo, let hi, let burst):
            return .boxRandom(rate: r * factor, origin: o, directions: d,
                              distanceMin: lo, distanceMax: hi, burst: burst)
        }
    }
}

public enum ParticleInitializer: Equatable, Sendable {
    case lifetimeRandom(min: Double, max: Double)
    case sizeRandom(min: Double, max: Double)
    case alphaRandom(min: Double, max: Double)
    case velocityRandom(min: Vec3, max: Vec3)
    case colorRandom(min: Vec3, max: Vec3)
    case rotationRandom(min: Vec3, max: Vec3)
    case angularVelocityRandom(min: Vec3, max: Vec3)
    case turbulentVelocityRandom(offset: Double, scale: Double, speedMin: Double, speedMax: Double)

    /// 씬의 조정값을 얹는다. 크기·속도·수명·투명도는 배율이고 색은 갈아끼운다.
    func scaled(size: Double, speed: Double, lifetime: Double, alpha: Double,
                color: Vec3?) -> ParticleInitializer {
        func mul(_ v: Vec3, _ k: Double) -> Vec3 { Vec3(x: v.x * k, y: v.y * k, z: v.z * k) }
        switch self {
        case .lifetimeRandom(let a, let b):
            return .lifetimeRandom(min: a * lifetime, max: b * lifetime)
        case .sizeRandom(let a, let b):
            return .sizeRandom(min: a * size, max: b * size)
        case .alphaRandom(let a, let b):
            return .alphaRandom(min: a * alpha, max: b * alpha)
        case .velocityRandom(let a, let b):
            return .velocityRandom(min: mul(a, speed), max: mul(b, speed))
        case .colorRandom(let a, let b):
            // 씬이 색을 지정하면 프리셋의 범위를 버리고 그 색으로 고정한다.
            guard let color else { return .colorRandom(min: a, max: b) }
            return .colorRandom(min: color, max: color)
        case .turbulentVelocityRandom(let offset, let scale, let lo, let hi):
            return .turbulentVelocityRandom(offset: offset, scale: scale,
                                            speedMin: lo * speed, speedMax: hi * speed)
        case .rotationRandom, .angularVelocityRandom:
            return self
        }
    }
}
public enum ParticleOperator: Equatable, Sendable {
    case movement(gravity: Vec3, drag: Double)
    case angularMovement(force: Vec3, drag: Double)
    /// 수명 중 어느 **지점**에서 나타나고 사라지는지. 초가 아니라 0~1 비율이다.
    ///
    /// 실물이 `fadeintime: 0.1, fadeouttime: 0.9`처럼 짝으로 적고,
    /// `rain_splashes_droplets`는 수명이 0.3~0.5초인데 `fadeouttime: 0.9`다 —
    /// 초로 읽으면 태어나기도 전에 사라져야 한다. 비율이 유일하게 말이 된다.
    case alphaFade(fadeInTime: Double, fadeOutTime: Double)
    /// 수명에 따라 크기에 곱하는 값. 실물에서 세 번째로 많이 쓰는 연산자다(112곳).
    ///
    /// 값은 처음 크기에 **곱한다** — `startvalue: 2`로 적은 프리셋이 있어 절대
    /// 크기일 수 없다. 시각도 0~1 비율이고, 구간 밖에서는 양 끝값으로 붙어 있다.
    /// 불꽃 섬광이 이걸로 0에서 부풀었다 꺼진다. 없으면 1200px짜리 원반이
    /// 수명 내내 그대로 떠서 화면이 하얗게 날아간다.
    case sizeChange(startTime: Double, endTime: Double,
                    startValue: Double, endValue: Double)
    case oscillatePosition(mask: Vec3, scaleMin: Double, scaleMax: Double,
                           frequencyMin: Double, frequencyMax: Double,
                           phaseMin: Double, phaseMax: Double)
    case oscillateAlpha(frequencyMin: Double, frequencyMax: Double,
                        scaleMin: Double, scaleMax: Double)
    /// 수명에 따라 색에 곱하는 값. `sizechange`의 색 판이다(실물 32곳).
    ///
    /// 곱한다고 보는 근거: 편집기가 기본값을 안 적어서 `{"starttime": 0.5}`만
    /// 적힌 것이 있는데, 갈아끼운다고 보면 그런 프리셋이 흰색으로 튄다.
    /// 곱하기로 보면 기본값(1 1 1)이 아무것도 안 바꾼다.
    case colorChange(startTime: Double, endTime: Double,
                     startValue: Vec3, endValue: Vec3)
    /// 크기를 주기적으로 흔든다. 반딧불이 커졌다 작아지는 것이 이것이다.
    case oscillateSize(frequencyMin: Double, frequencyMax: Double,
                       scaleMin: Double, scaleMax: Double)
    /// 소용돌이 잡음으로 속도를 흔든다. 실물 22곳에서 쓴다.
    ///
    /// **WE의 잡음 함수 자체는 공개돼 있지 않다.** 여기 잡음은 우리 것이고,
    /// 같은 자리에서 같은 값이 나오는 매끄러운 3차원 잡음이라는 성질만 같다.
    /// 불티가 흩날리는 모양은 나오지만 픽셀 단위로 같지는 않다.
    case turbulence(mask: Vec3, scale: Double, speedMin: Double, speedMax: Double,
                    timeScale: Double, phaseMin: Double, phaseMax: Double)
    /// 축을 중심으로 돌린다. 안쪽과 바깥쪽 속력을 거리로 섞는다.
    ///
    /// `vortex_v2`의 고리(`ringradius`/`ringwidth`/`ringpulldistance`)는 아직
    /// 모델링하지 않는다. 고리가 적힌 프리셋에서는 그 사실을 보고한다.
    case vortex(axis: Vec3, distanceInner: Double, distanceOuter: Double,
                speedInner: Double, speedOuter: Double)
    /// 잡음이나 사인파를 값 범위로 옮겨 파티클 속성에 넣는다.
    ///
    /// 유리창에 맺힌 비가 이걸로 흘러내린다 — 방울마다 다른 속도를 잡음에서
    /// 받는다. 이 연산자가 없으면 중력만 남아 방울이 느리게 떨어지기만 한다.
    ///
    /// **`input`을 읽는 쪽은 아직 안 만들었다.** 실물에서 쓰는 두 개가 둘 다
    /// input 없이 잡음만 쓰고, 다른 input(`distancetocontrolpoint`)은 제어점
    /// 데이터가 있어야 한다. 우리가 넣을 수 있는 출력만 넣고 나머지는 이름과
    /// 함께 보고한다.
    case remapValue(output: ParticleRemapOutput, transform: ParticleRemapTransform,
                    inputScale: Double, outputMin: Vec3, outputMax: Vec3)
    case controlPointAttract(controlPoint: Int, origin: Vec3, scale: Double, threshold: Double)
}

/// 씬이 프리셋 위에 얹는 조정값.
///
/// 창작마당 씬은 프리셋을 그대로 쓰지 않고 `instanceoverride`로 개수·속도·크기를
/// 배로 조절한다. 무시하면 씬이 의도한 것과 전혀 다른 밀도로 뿌린다 — 실물
/// Hiyuki의 벚꽃은 `count`가 0.05라 프리셋 200장 중 10장만 원한다.
/// `remapvalue`가 무엇에 값을 넣는지.
public enum ParticleRemapOutput: Equatable, Sendable {
    case velocity
    case opacity
    case size
    case color
    /// 우리가 아직 안 넣는 출력. 이름을 들고 있다가 보고한다.
    case unsupported(String)

    public static func parse(_ raw: String?) -> ParticleRemapOutput {
        switch raw?.lowercased() {
        case "velocity": return .velocity
        case "opacity", "alpha": return .opacity
        case "size": return .size
        case "color": return .color
        case let other: return .unsupported(other ?? "(없음)")
        }
    }

    public var name: String {
        switch self {
        case .velocity: return "velocity"
        case .opacity: return "opacity"
        case .size: return "size"
        case .color: return "color"
        case .unsupported(let name): return name
        }
    }
}

/// 입력을 0~1로 바꾸는 함수.
public enum ParticleRemapTransform: Equatable, Sendable {
    case noise
    case sine

    public static func parse(_ raw: String?) -> ParticleRemapTransform {
        switch raw?.lowercased() {
        case "sine": return .sine
        // `simplexnoise`와 `fbmnoise`는 결이 다르지만 둘 다 매끄러운 잡음이다.
        // 우리 잡음 하나로 받고, 다르다는 사실은 주석으로 남긴다.
        default: return .noise
        }
    }
}

public struct ParticleOverride: Equatable, Sendable {
    /// 전부 배율이다. 1이면 프리셋 그대로.
    public var count: Double = 1
    public var rate: Double = 1
    public var size: Double = 1
    public var speed: Double = 1
    public var lifetime: Double = 1
    public var alpha: Double = 1
    /// 색은 배율이 아니라 통째로 갈아끼운다. 0~1이다.
    public var color: Vec3?

    public init() {}

    /// 아무것도 바꾸지 않는지. 그러면 프리셋을 그대로 쓴다.
    public var isIdentity: Bool {
        count == 1 && rate == 1 && size == 1 && speed == 1
            && lifetime == 1 && alpha == 1 && color == nil
    }

    /// `instanceoverride` 객체에서 읽는다. 배율은 파일에서 오므로 이상한 값은 버린다.
    public static func parse(_ json: [String: Any]) -> ParticleOverride {
        var result = ParticleOverride()
        func factor(_ key: String) -> Double? {
            let raw = (json[key] as? [String: Any])?["value"] ?? json[key]
            let value: Double?
            if let d = raw as? Double { value = d }
            else if let s = raw as? String { value = Double(s) }
            else { value = nil }
            guard let value, value.isFinite, value >= 0, value <= 100 else { return nil }
            return value
        }
        result.count = factor("count") ?? 1
        result.rate = factor("rate") ?? 1
        result.size = factor("size") ?? 1
        result.speed = factor("speed") ?? 1
        result.lifetime = factor("lifetime") ?? 1
        result.alpha = factor("alpha") ?? 1
        if let text = ((json["colorn"] as? [String: Any])?["value"] ?? json["colorn"]) as? String,
           let parsed = Vec3.parse(text) {
            // colorn은 이미 0~1이다. 파티클 프리셋의 색(0~255)과 다르다.
            result.color = parsed
        }
        return result
    }
}

/// 스프라이트 시트를 어떻게 넘길지.
public enum ParticleAnimationMode: String, Equatable, Sendable {
    /// 수명에 따라 칸을 훑는다. 꽃잎이 도는 것처럼 보이게 하는 용도다.
    case sequence
    /// 파티클마다 한 장을 골라 **고정**한다. 화면에 맺힌 빗방울이 이 방식이다 —
    /// 훑으면 방울이 모양을 바꾸며 깜빡인다.
    case randomFrame

    /// 파일의 값. `null`이거나 없으면 훑는 쪽이 기본이다.
    public static func parse(_ raw: Any?) -> ParticleAnimationMode {
        guard let text = raw as? String else { return .sequence }
        return text == "randomframe" ? .randomFrame : .sequence
    }
}

/// 부모 파티클의 사건에 맞춰 따로 도는 파티클 시스템.
///
/// 실물에서 이것 없이는 **불꽃이 안 터지고**(폭발이 전부 `eventdeath` 자식이다),
/// 반딧불 꼬리와 빗줄기도 없다. 라이브러리 51개 프리셋 중 10개가 쓴다.
public struct ParticleChildReference: Equatable, Sendable {
    /// 자식 프리셋 파일 경로.
    public let name: String
    public let trigger: ParticleChildTrigger
    /// 동시에 존재할 수 있는 자식 시스템 수. 없으면 넉넉한 기본값을 쓴다.
    public let maxCount: Int
    /// 자식 시스템이 놓이는 자리(부모 기준).
    public let origin: Vec3

    public init(name: String, trigger: ParticleChildTrigger, maxCount: Int, origin: Vec3) {
        self.name = name
        self.trigger = trigger
        self.maxCount = maxCount
        self.origin = origin
    }
}

/// 자식이 언제 생기는지. 공식 문서의 네 가지 그대로다.
public enum ParticleChildTrigger: Equatable, Sendable {
    /// "automatically spawned once at the particle system origin."
    /// **파일에 `type`이 없으면 이것이다** — 실물의 절반이 이 경우이고,
    /// 그런 프리셋은 내용 전부가 자식에 들어 있다.
    case once
    /// "spawned at the same time particles of this system spawn."
    case onSpawn
    /// "spawned when a particle of this system reaches the end of its lifetime
    /// at its location." 불꽃 폭발이 이것이다.
    case onDeath
    /// "created multiple times and follow individual particles of this system."
    /// 반딧불 꼬리와 빗줄기가 이것이다.
    case follow

    public static func parse(_ raw: Any?) -> ParticleChildTrigger {
        switch raw as? String {
        case "eventspawn": return .onSpawn
        case "eventdeath": return .onDeath
        case "eventfollow": return .follow
        default: return .once
        }
    }
}

/// 파일을 읽어 붙인 자식. 자식은 자기 텍스처와 합성 방식을 따로 가진다 —
/// 불꽃의 폭발과 잔불이 서로 다른 그림인 것처럼.
public struct ParticleChild: Equatable, Sendable {
    public let reference: ParticleChildReference
    public let preset: ParticlePreset
    public let texturePath: String
    public let blend: ParticleBlendMode
    /// 굴절 자식의 법선 지도. 불꽃이 터질 때의 충격파가 이것이다.
    public let normalPath: String?
    /// 재질이 정한 미는 정도.
    public let refractAmount: Double

    public init(reference: ParticleChildReference, preset: ParticlePreset,
                texturePath: String, blend: ParticleBlendMode,
                normalPath: String? = nil, refractAmount: Double = 0.05) {
        self.refractAmount = refractAmount
        self.reference = reference
        self.preset = preset
        self.texturePath = texturePath
        self.blend = blend
        self.normalPath = normalPath
    }
}

/// 프리셋이 정의하는 제어점 하나.
///
/// 연산자들이 번호로 이걸 가리킨다. `flags`의 1번 비트가 **마우스를 따라가라**는
/// 뜻이다 — 실물 `examplecursoravoid`(이름 그대로 커서를 피하는 예제)의 1번
/// 제어점이 `flags: 1`이고, `fireflies`·`vapor0`처럼 상호작용 프리셋들이 전부
/// 같은 꼴이다. 나머지 값(2·4·16)은 무엇에 묶이는지 근거가 없어 그대로 둔다.
public struct ParticleControlPoint: Equatable, Sendable {
    /// 마우스를 따라간다는 비트.
    public static let followsCursorFlag = 1

    public let id: Int
    public let offset: Vec3
    public let flags: Int

    public init(id: Int, offset: Vec3, flags: Int) {
        self.id = id
        self.offset = offset
        self.flags = flags
    }

    public var followsCursor: Bool { flags & Self.followsCursorFlag != 0 }
    /// 우리가 모르는 묶임이 있는지. 있으면 그 제어점을 쓰는 연산자를 보고한다.
    public var hasUnknownBinding: Bool { flags & ~Self.followsCursorFlag != 0 }
}

public struct ParticlePreset: Equatable, Sendable {
    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    /// 실물 프리셋의 최대가 300이므로 8192는 충분히 관대하다.
    public static let maxAllowedCount = 8192

    /// 자식 시스템 하나가 동시에 몇 벌까지 살 수 있는지.
    /// 부모 파티클마다 한 벌씩 생기는 `follow`가 있어서 상한이 없으면 끝없이 는다.
    public static let maxAllowedChildSystems = 64

    /// 씬 하나가 시뮬레이션할 수 있는 파티클 총량.
    ///
    /// `maxAllowedCount`는 프리셋 하나만 막는다. 레이어가 여섯이면 그 여섯 배가
    /// 되므로 상시 구동 앱의 예산은 지켜지지 않는다. 실측: 창작마당 씬 하나가
    /// 파티클 48,192개로 프레임당 23.3ms를 썼다 — 60fps 예산 16.7ms를 넘긴다.
    /// 파티클 하나가 약 0.5µs이므로 12,000개는 약 6ms다. 이건 배경화면이라
    /// 항상 켜져 있고, 사용자의 진짜 작업이 CPU를 먼저 써야 한다.
    public static let maxAllowedSceneCount = 12_000

    /// 이미터의 rate 필드가 없을 때 쓰는 기본 방출률.
    /// WE 자체 예제 particles/example.json에서 20을 쓴다.
    /// 0으로 두면 레이어가 영영 안 보인다.
    public static let defaultEmitRate = 20.0

    /// name을 읽지 못한 엔트리를 진단에 남길 때 쓰는 라벨.
    /// 실제 타입 이름은 전부 소문자 ASCII 식별자라 괄호가 든 이 문자열과 겹치지 않는다.
    private static let unnamedEntryLabel = "(이름 없는 엔트리)"

    public let maxCount: Int
    public let startTime: Double
    public let materialPath: String
    public let emitters: [ParticleEmitter]
    public let initializers: [ParticleInitializer]
    public let operators: [ParticleOperator]
    /// 인식하지 못한 이름들. 무엇이 빠졌는지 사용자에게 말할 수 있게 남긴다.
    public let unsupportedNames: [String]
    /// 프리셋이 정의하는 제어점들. 연산자가 번호로 가리킨다.
    public let controlPoints: [ParticleControlPoint]
    /// 이름은 아는데 필드가 깨져서 버린 엔트리가 있는 이름들.
    /// 이름 단위라서 개수는 담지 못한다 — 같은 이름이 여러 번 나오고 그중 일부만
    /// 깨졌으면, 나머지가 정상 동작하는 중에도 그 이름이 여기 들어간다.
    /// "이 타입이 통째로 망가졌다"가 아니라 "이 이름의 엔트리 중 하나 이상을 버렸다"로 읽어야 한다.
    public let malformedNames: [String]
    /// 스프라이트 시트를 훑을지, 한 장을 골라 고정할지.
    public let animationMode: ParticleAnimationMode
    /// 이 프리셋이 거느리는 자식 시스템들. 경로만 들고 있다 —
    /// 실제 프리셋은 참조 해석기가 있는 곳(`SceneDocument`)에서 읽어 붙인다.
    public let childReferences: [ParticleChildReference]
    /// 실제로 읽어 붙인 자식들. 참조 해석기가 있는 곳에서 채운다.
    public let children: [ParticleChild]

    /// public struct의 memberwise 이니셜라이저는 internal이라 테스트 타깃에서
    /// 쓸 수 없다. Task 3의 시뮬레이션 테스트가 프리셋을 직접 만들어야 하므로
    /// 명시적으로 public을 단다.
    public init(
        maxCount: Int, startTime: Double, materialPath: String,
        emitters: [ParticleEmitter], initializers: [ParticleInitializer],
        operators: [ParticleOperator], unsupportedNames: [String],
        malformedNames: [String] = [], animationMode: ParticleAnimationMode = .sequence,
        childReferences: [ParticleChildReference] = [],
        children: [ParticleChild] = [],
        controlPoints: [ParticleControlPoint] = []
    ) {
        self.controlPoints = controlPoints
        self.maxCount = maxCount
        self.startTime = startTime
        self.materialPath = materialPath
        self.emitters = emitters
        self.initializers = initializers
        self.operators = operators
        self.unsupportedNames = unsupportedNames
        self.malformedNames = malformedNames
        self.animationMode = animationMode
        self.childReferences = childReferences
        self.children = children
    }

    /// 씬의 조정값을 얹은 프리셋을 만든다.
    ///
    /// 개수는 최소 1로 남긴다 — 배율이 0.05여도 아예 안 나오면 씬이 의도한
    /// "드물게 흩날림"이 아니라 "없음"이 된다.
    public func applying(_ override: ParticleOverride) -> ParticlePreset {
        guard !override.isIdentity else { return self }
        let scaledCount = override.count == 1 ? maxCount
            : Swift.max(1, Swift.min(Int((Double(maxCount) * override.count).rounded()),
                                     Self.maxAllowedCount))
        return ParticlePreset(
            maxCount: scaledCount,
            startTime: startTime,
            materialPath: materialPath,
            emitters: emitters.map { $0.scaled(rate: override.rate) },
            initializers: initializers.map {
                $0.scaled(size: override.size, speed: override.speed,
                          lifetime: override.lifetime, alpha: override.alpha,
                          color: override.color)
            },
            operators: operators,
            unsupportedNames: unsupportedNames,
            malformedNames: malformedNames,
            animationMode: animationMode,
            childReferences: childReferences,
            children: children, controlPoints: controlPoints)
    }

    /// 읽어 온 자식들을 붙인 사본.
    public func withChildren(_ children: [ParticleChild]) -> ParticlePreset {
        ParticlePreset(
            maxCount: maxCount, startTime: startTime, materialPath: materialPath,
            emitters: emitters, initializers: initializers, operators: operators,
            unsupportedNames: unsupportedNames, malformedNames: malformedNames,
            animationMode: animationMode, childReferences: childReferences,
            children: children, controlPoints: controlPoints)
    }

    /// 총량 예산에 맞추기 위한 축소 배율. 줄일 필요가 없으면 1이다.
    public static func budgetScale(forTotalCount total: Int) -> Double {
        guard total > maxAllowedSceneCount else { return 1 }
        return Double(maxAllowedSceneCount) / Double(total)
    }

    /// 예산에 맞춰 개수와 방출률을 같은 배율로 줄인다.
    ///
    /// 개수만 줄이면 방출이 빈 슬롯을 기다리며 몰려, 밀도 대신 수명이 짧아 보인다.
    /// 둘을 같이 줄여야 "덜 많다"로 보이고 씬이 의도한 모양이 남는다.
    public func scaledToBudget(_ factor: Double) -> ParticlePreset {
        guard factor < 1, factor > 0 else { return self }
        var budget = ParticleOverride()
        budget.count = factor
        budget.rate = factor
        return applying(budget)
    }

    public static func parse(_ json: [String: Any]) -> ParticlePreset? {
        // Material is required
        guard let materialPath = json["material"] as? String else {
            return nil
        }

        // Known names by category
        let knownEmitterNames = Set<String>(["sphererandom", "boxrandom"])
        let knownInitializerNames = Set<String>([
            "lifetimerandom", "sizerandom", "alpharandom", "velocityrandom",
            "colorrandom", "rotationrandom", "angularvelocityrandom", "turbulentvelocityrandom"
        ])
        let knownOperatorNames = Set<String>([
            "movement", "angularmovement", "alphafade", "sizechange", "colorchange",
            "oscillateposition", "oscillatealpha", "oscillatesize", "turbulence",
            "vortex", "vortex_v2", "remapvalue", "controlpointattract"
        ])

        // Parse maxCount with clamping
        let rawMaxCount: Int
        if let intVal = json["maxcount"] as? Int {
            rawMaxCount = intVal
        } else if let doubleVal = json["maxcount"] as? Double {
            if let saturated = saturatingInt(doubleVal) {
                rawMaxCount = saturated
            } else {
                rawMaxCount = 0
            }
        } else {
            rawMaxCount = 0
        }
        let maxCount = max(0, min(rawMaxCount, maxAllowedCount))

        // Parse startTime (default to 0 if missing)
        let startTime: Double
        if let doubleVal = json["starttime"] as? Double {
            startTime = doubleVal
        } else if let intVal = json["starttime"] as? Int {
            startTime = Double(intVal)
        } else {
            startTime = 0
        }

        // Parse emitters
        var emitters: [ParticleEmitter] = []
        var unsupportedNames = Set<String>()
        var malformedNames = Set<String>()
        if let emitterArray = json["emitter"] as? [[String: Any]] {
            for emitterDict in emitterArray {
                if let emitter = parseEmitter(emitterDict) {
                    emitters.append(emitter)
                } else if let name = emitterDict["name"] as? String {
                    if knownEmitterNames.contains(name) {
                        malformedNames.insert(name)
                    } else {
                        unsupportedNames.insert(name)
                    }
                } else {
                    // name 키가 없거나 String이 아니다. 이름을 모르니 어느 타입인지 말할 수 없지만,
                    // 엔트리를 버렸다는 사실 자체는 남겨야 한다. 그냥 사라지면 사용자가
                    // 파티클이 안 나오는 이유를 알 수 없다.
                    malformedNames.insert(unnamedEntryLabel)
                }
            }
        }

        // Parse initializers
        var initializers: [ParticleInitializer] = []
        if let initArray = json["initializer"] as? [[String: Any]] {
            for initDict in initArray {
                if let initializer = parseInitializer(initDict) {
                    initializers.append(initializer)
                } else if let name = initDict["name"] as? String {
                    if knownInitializerNames.contains(name) {
                        malformedNames.insert(name)
                    } else {
                        unsupportedNames.insert(name)
                    }
                } else {
                    // name 키가 없거나 String이 아니다. 이름을 모르니 어느 타입인지 말할 수 없지만,
                    // 엔트리를 버렸다는 사실 자체는 남겨야 한다. 그냥 사라지면 사용자가
                    // 파티클이 안 나오는 이유를 알 수 없다.
                    malformedNames.insert(unnamedEntryLabel)
                }
            }
        }

        // Parse operators
        var operators: [ParticleOperator] = []
        if let opArray = json["operator"] as? [[String: Any]] {
            for opDict in opArray {
                if let op = parseOperator(opDict) {
                    operators.append(op)
                    // 다 하지 못한 것은 이름을 남긴다. 소용돌이의 고리는 아직
                    // 모델링하지 않았고, 조용히 넘어가면 왜 다르게 보이는지
                    // 알 수 없다.
                    if case .vortex = op,
                       opDict["ringradius"] != nil || opDict["ringpulldistance"] != nil {
                        unsupportedNames.insert("vortex_v2(고리)")
                    }
                } else if let name = opDict["name"] as? String {
                    if knownOperatorNames.contains(name) {
                        malformedNames.insert(name)
                    } else {
                        unsupportedNames.insert(name)
                    }
                } else {
                    // name 키가 없거나 String이 아니다. 이름을 모르니 어느 타입인지 말할 수 없지만,
                    // 엔트리를 버렸다는 사실 자체는 남겨야 한다. 그냥 사라지면 사용자가
                    // 파티클이 안 나오는 이유를 알 수 없다.
                    malformedNames.insert(unnamedEntryLabel)
                }
            }
        }

        return ParticlePreset(
            maxCount: maxCount,
            startTime: startTime,
            materialPath: materialPath,
            emitters: emitters,
            initializers: initializers,
            operators: operators,
            unsupportedNames: Array(unsupportedNames).sorted(),
            malformedNames: Array(malformedNames).sorted(),
            animationMode: ParticleAnimationMode.parse(json["animationmode"]),
            childReferences: parseChildren(json["children"]),
            controlPoints: parseControlPoints(json["controlpoint"])
        )
    }

    /// `controlpoint` 항목을 읽는다. 번호가 없으면 가리킬 수 없으므로 버린다.
    static func parseControlPoints(_ raw: Any?) -> [ParticleControlPoint] {
        var out: [ParticleControlPoint] = []
        for case let point as [String: Any] in (raw as? [Any] ?? []) {
            guard let id = (point["id"] as? NSNumber)?.intValue, id >= 0 else { continue }
            out.append(ParticleControlPoint(
                id: id,
                offset: (point["offset"] as? String).flatMap(Vec3.parse)
                    ?? Vec3(x: 0, y: 0, z: 0),
                flags: (point["flags"] as? NSNumber)?.intValue ?? 0))
        }
        return out
    }

    /// `children` 항목을 읽는다. 이름이 없는 것은 버린다 — 가리킬 파일이 없다.
    static func parseChildren(_ raw: Any?) -> [ParticleChildReference] {
        var out: [ParticleChildReference] = []
        for case let child as [String: Any] in (raw as? [Any] ?? []) {
            guard let name = child["name"] as? String, !name.isEmpty else { continue }
            // 자식 시스템 수의 상한. 파일 값이 없으면 하나로 본다 —
            // 상시 구동 앱이라 모르는 채로 넉넉히 잡을 이유가 없다.
            let declared = saturatingInt(getDouble(child["maxcount"]) ?? 1) ?? 1
            out.append(ParticleChildReference(
                name: name,
                trigger: ParticleChildTrigger.parse(child["type"]),
                maxCount: Swift.min(Swift.max(1, declared), maxAllowedChildSystems),
                origin: (child["origin"] as? String).flatMap(Vec3.parse)
                    ?? Vec3(x: 0, y: 0, z: 0)))
        }
        return out
    }

    /// 파일에서 온 Double을 트랩 없이 Int로 좁힌다.
    /// Swift의 Int(Double)은 범위 밖이거나 NaN이면 트랩해서 프로세스를 죽인다.
    /// 창작마당 .pkg의 JSON은 임의의 제3자 입력이라 절대 트랩시킬 수 없다.
    /// 범위를 벗어난 값은 양 끝으로 포화시켜 기존 클램프가 처리하게 하고,
    /// NaN만 "값 없음"으로 돌린다.
    private static func saturatingInt(_ d: Double) -> Int? {
        if d.isNaN { return nil }
        if d >= Double(Int.max) { return Int.max }
        if d <= Double(Int.min) { return Int.min }
        return Int(d)
    }

    private static func getDouble(_ value: Any?) -> Double? {
        if let doubleVal = value as? Double {
            return doubleVal
        } else if let intVal = value as? Int {
            return Double(intVal)
        }
        return nil
    }

    private static func getInt(_ value: Any?) -> Int? {
        if let intVal = value as? Int {
            return intVal
        } else if let doubleVal = value as? Double {
            // Int(Double)은 범위 밖/NaN에서 트랩한다. Int(exactly:)는 nil을 돌린다.
            // .towardZero 반올림으로 기존 Int(Double)의 절삭 의미를 유지한다.
            guard doubleVal.isFinite else { return nil }
            return Int(exactly: doubleVal.rounded(.towardZero))
        }
        return nil
    }

    private static func parseEmitter(_ dict: [String: Any]) -> ParticleEmitter? {
        guard let name = dict["name"] as? String else { return nil }

        let zero = Vec3(x: 0, y: 0, z: 0)
        // 이름 말고는 전부 선택이다. WE 자체 예제도 `{"name":"boxrandom","rate":200}`처럼
        // 대부분을 생략한다.
        guard let rate = num(dict, "rate", defaultEmitRate),
              let origin = vec(dict, "origin", zero),
              // 2D 배경화면의 기본 방향. WE 예제 example.json이 쓰는 값이다.
              let directions = vec(dict, "directions", Vec3(x: 1, y: 1, z: 0))
        else { return nil }

        // 시작할 때의 한꺼번에 방출과 초기 속력. 둘 다 파일에서 오는 값이라
        // 말이 안 되면 없는 것으로 본다.
        let burst = ParticleEmitterBurst(
            // 파일이 1e9을 줄 수도 있다. 버퍼 상한으로 죈다 — 그 이상은 어차피
            // 빈 자리가 없어 무시되지만, 큰 수로 도는 반복문을 만들 이유가 없다.
            count: Swift.min(
                Swift.max(0, saturatingInt(num(dict, "instantaneous", 0) ?? 0) ?? 0),
                maxAllowedCount),
            speedMin: (num(dict, "speedmin", 0) ?? 0).isFinite
                ? Swift.max(0, num(dict, "speedmin", 0) ?? 0) : 0,
            speedMax: (num(dict, "speedmax", 0) ?? 0).isFinite
                ? Swift.max(0, num(dict, "speedmax", 0) ?? 0) : 0)

        switch name {
        case "sphererandom":
            guard let lo = num(dict, "distancemin", 0), let hi = num(dict, "distancemax", 0)
            else { return nil }
            return .sphereRandom(rate: rate, origin: origin, directions: directions,
                                 distanceMin: lo, distanceMax: hi, burst: burst)

        case "boxrandom":
            // 상자는 distancemin~distancemax 사이를 채운다. distancemin이 없으면 0이다 —
            // 복사하면 상자 표면에만 생겨 먼지가 한 겹으로 몰린다.
            guard let lo = vec(dict, "distancemin", zero),
                  let hi = vec(dict, "distancemax", zero)
            else { return nil }
            return .boxRandom(rate: rate, origin: origin, directions: directions,
                              distanceMin: lo, distanceMax: hi, burst: burst)

        default:
            return nil
        }
    }

    /// 벡터 필드 하나를 읽는다.
    /// - 없으면 `fallback`. 실물 프리셋은 기본값인 필드를 아예 적지 않는다.
    /// - 있는데 해석이 안 되면 nil. 호출자가 엔트리를 버리고 malformed로 남긴다.
    private static func vec(
        _ dict: [String: Any], _ key: String, _ fallback: Vec3
    ) -> Vec3? {
        guard let raw = dict[key] else { return fallback }
        guard let text = raw as? String, let parsed = Vec3.parse(text) else { return nil }
        return parsed
    }

    /// 수 필드 하나. 규칙은 `vec`과 같다.
    private static func num(
        _ dict: [String: Any], _ key: String, _ fallback: Double
    ) -> Double? {
        guard let raw = dict[key] else { return fallback }
        guard let parsed = getDouble(raw) else { return nil }
        return parsed
    }

    /// 색 필드. 실물 프리셋의 색은 0~255다 — WE 자체 예제도 흰색을
    /// `"255 255 255"`로 적는다. 셰이더는 텍스처에 색을 곱하므로 그대로 넘기면
    /// 255배가 되어 전부 흰색으로 포화된다. 눈은 원래 흰색이라 티가 안 나지만
    /// 벚꽃은 분홍이 날아간다. 여기서 0~1로 바꿔 모델은 항상 0~1을 담는다.
    private static func color(
        _ dict: [String: Any], _ key: String
    ) -> Vec3? {
        guard let raw = dict[key] else { return Vec3(x: 1, y: 1, z: 1) }
        guard let text = raw as? String, let parsed = Vec3.parse(text) else { return nil }
        return Vec3(x: parsed.x / 255, y: parsed.y / 255, z: parsed.z / 255)
    }

    private static func parseInitializer(_ dict: [String: Any]) -> ParticleInitializer? {
        guard let name = dict["name"] as? String else { return nil }

        // 한쪽 경계가 없으면 그 속성의 기본값을 쓴다. "있는 쪽을 양쪽에 복사"가
        // **아니다.** 실물 leaves5.json의 rotationrandom이 `{"max": "6.283 6.283 6.283"}`만
        // 담고 있는데, 6.283은 2π라 꽃잎마다 0~2π 무작위 각도를 뜻한다. 복사하면
        // 200장이 전부 같은 각도로 굳어 회전이 사라진다.
        // 기본값은 속성마다 다르다 — 크기와 알파는 1이어야 하고(0이면 안 보인다),
        // 색은 흰색이어야 하며(검은색은 눈에 띄는 부작용이다), 회전과 속도는 0이다.
        let zero = Vec3(x: 0, y: 0, z: 0)

        switch name {
        case "lifetimerandom":
            guard let lo = num(dict, "min", 1), let hi = num(dict, "max", 1) else { return nil }
            return .lifetimeRandom(min: lo, max: hi)

        case "sizerandom":
            guard let lo = num(dict, "min", 1), let hi = num(dict, "max", 1) else { return nil }
            return .sizeRandom(min: lo, max: hi)

        case "alpharandom":
            guard let lo = num(dict, "min", 1), let hi = num(dict, "max", 1) else { return nil }
            return .alphaRandom(min: lo, max: hi)

        case "velocityrandom":
            guard let lo = vec(dict, "min", zero), let hi = vec(dict, "max", zero) else { return nil }
            return .velocityRandom(min: lo, max: hi)

        case "colorrandom":
            guard let lo = color(dict, "min"), let hi = color(dict, "max") else { return nil }
            return .colorRandom(min: lo, max: hi)

        case "rotationrandom":
            guard let lo = vec(dict, "min", zero), let hi = vec(dict, "max", zero) else { return nil }
            return .rotationRandom(min: lo, max: hi)

        case "angularvelocityrandom":
            guard let lo = vec(dict, "min", zero), let hi = vec(dict, "max", zero) else { return nil }
            return .angularVelocityRandom(min: lo, max: hi)

        case "turbulentvelocityrandom":
            guard let offset = num(dict, "offset", 0), let scale = num(dict, "scale", 0),
                  let speedMin = num(dict, "speedmin", 0), let speedMax = num(dict, "speedmax", 0)
            else { return nil }
            return .turbulentVelocityRandom(
                offset: offset, scale: scale, speedMin: speedMin, speedMax: speedMax)

        default:
            return nil
        }
    }

    private static func parseOperator(_ dict: [String: Any]) -> ParticleOperator? {
        guard let name = dict["name"] as? String else { return nil }

        switch name {
        case "movement":
            // gravity와 drag는 모두 선택
            let gravity: Vec3
            if let gravityStr = dict["gravity"] as? String, let gravityVec = Vec3.parse(gravityStr) {
                gravity = gravityVec
            } else {
                gravity = Vec3(x: 0, y: 0, z: 0)
            }
            let drag = getDouble(dict["drag"]) ?? 0
            return .movement(gravity: gravity, drag: drag)

        case "angularmovement":
            // force (formerly gravity)와 drag는 모두 선택
            let force: Vec3
            if let forceStr = dict["force"] as? String, let forceVec = Vec3.parse(forceStr) {
                force = forceVec
            } else {
                force = Vec3(x: 0, y: 0, z: 0)
            }
            let drag = getDouble(dict["drag"]) ?? 0
            return .angularMovement(force: force, drag: drag)

        case "alphafade":
            // 안 적으면 그 쪽으로는 흐려지지 않는다. 편집기가 기본값을 안 적는
            // 형식이라 맨 `alphafade`(실물 29곳)의 기본값은 확실하지 않다 —
            // 확실하지 않은 쪽으로 지어내느니 그대로 두는 편이 덜 틀린다.
            let fadeInTime = getDouble(dict["fadeintime"]) ?? 0
            let fadeOutTime = getDouble(dict["fadeouttime"]) ?? 1
            return .alphaFade(fadeInTime: fadeInTime, fadeOutTime: fadeOutTime)

        case "sizechange":
            return .sizeChange(
                startTime: getDouble(dict["starttime"]) ?? 0,
                endTime: getDouble(dict["endtime"]) ?? 1,
                startValue: getDouble(dict["startvalue"]) ?? 1,
                endValue: getDouble(dict["endvalue"]) ?? 0)

        case "oscillateposition":
            // 모든 필드 선택
            let mask: Vec3
            if let maskStr = dict["mask"] as? String, let maskVec = Vec3.parse(maskStr) {
                mask = maskVec
            } else {
                mask = Vec3(x: 1, y: 1, z: 1)
            }
            let scaleMin = getDouble(dict["scalemin"]) ?? 0
            let scaleMax = getDouble(dict["scalemax"]) ?? 0
            let frequencyMin = getDouble(dict["frequencymin"]) ?? 0
            let frequencyMax = getDouble(dict["frequencymax"]) ?? 0
            let phaseMin = getDouble(dict["phasemin"]) ?? 0
            let phaseMax = getDouble(dict["phasemax"]) ?? 0
            return .oscillatePosition(mask: mask, scaleMin: scaleMin, scaleMax: scaleMax,
                                     frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                     phaseMin: phaseMin, phaseMax: phaseMax)

        case "oscillatealpha", "oscillatesize":
            // 편집기가 기본값을 안 적는다. 전부 필수로 두면 실물이 떨어진다 —
            // `fireworks2hit`은 `scalemin`만 적고, `magic_color_sparkle`은
            // 진동수만 적는다. `scalemin`만 적힌 것이 뜻을 가지려면
            // `scalemax`의 기본이 1이어야 한다.
            let frequencyMin = getDouble(dict["frequencymin"]) ?? 1
            let frequencyMax = getDouble(dict["frequencymax"]) ?? frequencyMin
            let scaleMin = getDouble(dict["scalemin"]) ?? 0
            let scaleMax = getDouble(dict["scalemax"]) ?? 1
            if name == "oscillatesize" {
                return .oscillateSize(frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                      scaleMin: scaleMin, scaleMax: scaleMax)
            }
            return .oscillateAlpha(frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                  scaleMin: scaleMin, scaleMax: scaleMax)

        case "colorchange":
            // 값은 0~1이다(`colorrandom`의 0~255와 다르다).
            let one = Vec3(x: 1, y: 1, z: 1)
            return .colorChange(
                startTime: getDouble(dict["starttime"]) ?? 0,
                endTime: getDouble(dict["endtime"]) ?? 1,
                startValue: (dict["startvalue"] as? String).flatMap(Vec3.parse) ?? one,
                endValue: (dict["endvalue"] as? String).flatMap(Vec3.parse) ?? one)

        case "turbulence":
            return .turbulence(
                mask: (dict["mask"] as? String).flatMap(Vec3.parse) ?? Vec3(x: 1, y: 1, z: 1),
                scale: getDouble(dict["scale"]) ?? 0.01,
                speedMin: getDouble(dict["speedmin"]) ?? 0,
                speedMax: getDouble(dict["speedmax"]) ?? (getDouble(dict["speedmin"]) ?? 0),
                timeScale: getDouble(dict["timescale"]) ?? 0,
                phaseMin: getDouble(dict["phasemin"]) ?? 0,
                phaseMax: getDouble(dict["phasemax"]) ?? (getDouble(dict["phasemin"]) ?? 0))

        case "remapvalue":
            // 범위는 수 하나이거나 `"200 -1000 0"` 같은 벡터다. 수 하나면
            // 세 성분에 같은 값을 넣는다 — 스칼라 출력은 x만 본다.
            func range(_ key: String, _ fallback: Double) -> Vec3 {
                if let text = dict[key] as? String, let vector = Vec3.parse(text) { return vector }
                if let value = getDouble(dict[key]) { return Vec3(x: value, y: value, z: value) }
                return Vec3(x: fallback, y: fallback, z: fallback)
            }
            return .remapValue(
                output: ParticleRemapOutput.parse(dict["output"] as? String),
                transform: ParticleRemapTransform.parse(dict["transformfunction"] as? String),
                inputScale: getDouble(dict["transforminputscale"]) ?? 1,
                outputMin: range("outputrangemin", 0),
                outputMax: range("outputrangemax", 1))

        case "vortex", "vortex_v2":
            // 고리(`ringradius`/`ringwidth`/`ringpulldistance`)는 아직 모델링하지
            // 않는다. 적혀 있으면 나머지만 하고, 부르는 쪽이 그 사실을 남긴다.
            return .vortex(
                axis: (dict["axis"] as? String).flatMap(Vec3.parse) ?? Vec3(x: 0, y: 0, z: 1),
                distanceInner: getDouble(dict["distanceinner"]) ?? 0,
                distanceOuter: getDouble(dict["distanceouter"]) ?? 0,
                speedInner: getDouble(dict["speedinner"]) ?? 0,
                speedOuter: getDouble(dict["speedouter"]) ?? 0)

        case "controlpointattract":
            guard let controlPoint = getInt(dict["controlpoint"]) else { return nil }
            // origin, scale, threshold는 선택 (기본값 설정)
            let origin: Vec3
            if let originStr = dict["origin"] as? String, let originVec = Vec3.parse(originStr) {
                origin = originVec
            } else {
                origin = Vec3(x: 0, y: 0, z: 0)
            }
            let scale = getDouble(dict["scale"]) ?? 0
            let threshold = getDouble(dict["threshold"]) ?? 0
            return .controlPointAttract(controlPoint: controlPoint, origin: origin, scale: scale, threshold: threshold)

        default:
            return nil
        }
    }
}
