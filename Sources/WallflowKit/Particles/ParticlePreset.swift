import Foundation

public enum ParticleEmitter: Equatable, Sendable {
    case sphereRandom(rate: Double, origin: Vec3, directions: Vec3,
                      distanceMin: Double, distanceMax: Double)
    case boxRandom(rate: Double, origin: Vec3, directions: Vec3,
                   distanceMin: Vec3, distanceMax: Vec3)
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

public struct ParticlePreset: Equatable, Sendable {
    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    /// 실물 프리셋의 최대가 300이므로 8192는 충분히 관대하다.
    public static let maxAllowedCount = 8192

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

    /// public struct의 memberwise 이니셜라이저는 internal이라 테스트 타깃에서
    /// 쓸 수 없다. Task 3의 시뮬레이션 테스트가 프리셋을 직접 만들어야 하므로
    /// 명시적으로 public을 단다.
    public init(
        maxCount: Int, startTime: Double, materialPath: String,
        emitters: [ParticleEmitter], initializers: [ParticleInitializer],
        operators: [ParticleOperator], unsupportedNames: [String], malformedNames: [String] = []
    ) {
        self.maxCount = maxCount
        self.startTime = startTime
        self.materialPath = materialPath
        self.emitters = emitters
        self.initializers = initializers
        self.operators = operators
        self.unsupportedNames = unsupportedNames
        self.malformedNames = malformedNames
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
            malformedNames: Array(malformedNames).sorted()
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
