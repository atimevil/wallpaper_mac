import Foundation

public enum ParticleEmitter: Equatable, Sendable {
    case sphereRandom(rate: Double, origin: Vec3, directions: Vec3,
                      distanceMin: Double, distanceMax: Double)
    case boxRandom(rate: Double, origin: Vec3, directions: Vec3,
                   distanceMin: Vec3, distanceMax: Vec3)

    /// 씬의 조정값을 얹는다. 방출 주기는 rate로, 뿌리는 범위는 크기 배율로 조절한다.
    func scaled(rate factor: Double, distance: Double) -> ParticleEmitter {
        switch self {
        case .sphereRandom(let r, let o, let d, let lo, let hi):
            return .sphereRandom(rate: r * factor, origin: o, directions: d,
                                 distanceMin: lo * distance, distanceMax: hi * distance)
        case .boxRandom(let r, let o, let d, let lo, let hi):
            return .boxRandom(
                rate: r * factor, origin: o, directions: d,
                distanceMin: Vec3(x: lo.x * distance, y: lo.y * distance, z: lo.z * distance),
                distanceMax: Vec3(x: hi.x * distance, y: hi.y * distance, z: hi.z * distance))
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
    case alphaFade(fadeInTime: Double, fadeOutTime: Double)
    case oscillatePosition(mask: Vec3, scaleMin: Double, scaleMax: Double,
                           frequencyMin: Double, frequencyMax: Double,
                           phaseMin: Double, phaseMax: Double)
    case oscillateAlpha(frequencyMin: Double, frequencyMax: Double,
                        scaleMin: Double, scaleMax: Double)
    case controlPointAttract(controlPoint: Int, origin: Vec3, scale: Double, threshold: Double)
}

/// 씬이 프리셋 위에 얹는 조정값.
///
/// 창작마당 씬은 프리셋을 그대로 쓰지 않고 `instanceoverride`로 개수·속도·크기를
/// 배로 조절한다. 무시하면 씬이 의도한 것과 전혀 다른 밀도로 뿌린다 — 실물
/// Hiyuki의 벚꽃은 `count`가 0.05라 프리셋 200장 중 10장만 원한다.
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

public struct ParticlePreset: Equatable, Sendable {
    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    /// 실물 프리셋의 최대가 300이므로 8192는 충분히 관대하다.
    public static let maxAllowedCount = 8192

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
    /// 이름은 아는데 필드가 깨져서 버린 엔트리가 있는 이름들.
    /// 이름 단위라서 개수는 담지 못한다 — 같은 이름이 여러 번 나오고 그중 일부만
    /// 깨졌으면, 나머지가 정상 동작하는 중에도 그 이름이 여기 들어간다.
    /// "이 타입이 통째로 망가졌다"가 아니라 "이 이름의 엔트리 중 하나 이상을 버렸다"로 읽어야 한다.
    public let malformedNames: [String]
    /// 스프라이트 시트를 훑을지, 한 장을 골라 고정할지.
    public let animationMode: ParticleAnimationMode

    /// public struct의 memberwise 이니셜라이저는 internal이라 테스트 타깃에서
    /// 쓸 수 없다. Task 3의 시뮬레이션 테스트가 프리셋을 직접 만들어야 하므로
    /// 명시적으로 public을 단다.
    public init(
        maxCount: Int, startTime: Double, materialPath: String,
        emitters: [ParticleEmitter], initializers: [ParticleInitializer],
        operators: [ParticleOperator], unsupportedNames: [String],
        malformedNames: [String] = [], animationMode: ParticleAnimationMode = .sequence
    ) {
        self.maxCount = maxCount
        self.startTime = startTime
        self.materialPath = materialPath
        self.emitters = emitters
        self.initializers = initializers
        self.operators = operators
        self.unsupportedNames = unsupportedNames
        self.malformedNames = malformedNames
        self.animationMode = animationMode
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
            emitters: emitters.map { $0.scaled(rate: override.rate, distance: override.size) },
            initializers: initializers.map {
                $0.scaled(size: override.size, speed: override.speed,
                          lifetime: override.lifetime, alpha: override.alpha,
                          color: override.color)
            },
            operators: operators,
            unsupportedNames: unsupportedNames,
            malformedNames: malformedNames,
            animationMode: animationMode)
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
            "movement", "angularmovement", "alphafade", "oscillateposition",
            "oscillatealpha", "controlpointattract"
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
            animationMode: ParticleAnimationMode.parse(json["animationmode"])
        )
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

        switch name {
        case "sphererandom":
            guard let lo = num(dict, "distancemin", 0), let hi = num(dict, "distancemax", 0)
            else { return nil }
            return .sphereRandom(rate: rate, origin: origin, directions: directions,
                                 distanceMin: lo, distanceMax: hi)

        case "boxrandom":
            // 상자는 distancemin~distancemax 사이를 채운다. distancemin이 없으면 0이다 —
            // 복사하면 상자 표면에만 생겨 먼지가 한 겹으로 몰린다.
            guard let lo = vec(dict, "distancemin", zero),
                  let hi = vec(dict, "distancemax", zero)
            else { return nil }
            return .boxRandom(rate: rate, origin: origin, directions: directions,
                              distanceMin: lo, distanceMax: hi)

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
            let fadeInTime = getDouble(dict["fadeintime"]) ?? 0
            let fadeOutTime = getDouble(dict["fadeouttime"]) ?? 0
            return .alphaFade(fadeInTime: fadeInTime, fadeOutTime: fadeOutTime)

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

        case "oscillatealpha":
            // frequencymin/frequencymax와 scalemin/scalemax 필수. phasemin/phasemax는 없음.
            guard let frequencyMin = getDouble(dict["frequencymin"]) else { return nil }
            guard let frequencyMax = getDouble(dict["frequencymax"]) else { return nil }
            guard let scaleMin = getDouble(dict["scalemin"]) else { return nil }
            guard let scaleMax = getDouble(dict["scalemax"]) else { return nil }
            return .oscillateAlpha(frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                  scaleMin: scaleMin, scaleMax: scaleMax)

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
