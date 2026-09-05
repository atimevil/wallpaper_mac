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

        // rate는 선택. 기본값은 defaultEmitRate.
        let rate = getDouble(dict["rate"]) ?? defaultEmitRate

        // origin은 선택. 기본값은 (0, 0, 0).
        let origin: Vec3
        if let originStr = dict["origin"] as? String, let originVec = Vec3.parse(originStr) {
            origin = originVec
        } else {
            origin = Vec3(x: 0, y: 0, z: 0)
        }

        // directions는 선택. 기본값은 (1, 1, 0) (2D 배경화면).
        let directions: Vec3
        if let dirStr = dict["directions"] as? String, let dirVec = Vec3.parse(dirStr) {
            directions = dirVec
        } else {
            directions = Vec3(x: 1, y: 1, z: 0)
        }

        switch name {
        case "sphererandom":
            // distancemin과 distancemax는 Double이고 선택. 한쪽만 있으면 양쪽에 쓴다.
            let distanceMin: Double
            let distanceMax: Double
            if let minVal = getDouble(dict["distancemin"]) {
                distanceMin = minVal
            } else if let maxVal = getDouble(dict["distancemax"]) {
                distanceMin = maxVal
            } else {
                distanceMin = 0
            }
            if let maxVal = getDouble(dict["distancemax"]) {
                distanceMax = maxVal
            } else if let minVal = getDouble(dict["distancemin"]) {
                distanceMax = minVal
            } else {
                distanceMax = 0
            }
            return .sphereRandom(rate: rate, origin: origin, directions: directions,
                                distanceMin: distanceMin, distanceMax: distanceMax)

        case "boxrandom":
            // distancemin과 distancemax는 Vec3이고 선택. 한쪽만 있으면 양쪽에 쓴다.
            let distanceMin: Vec3
            let distanceMax: Vec3
            if let minStr = dict["distancemin"] as? String, let minVec = Vec3.parse(minStr) {
                distanceMin = minVec
            } else if let maxStr = dict["distancemax"] as? String, let maxVec = Vec3.parse(maxStr) {
                distanceMin = maxVec
            } else {
                distanceMin = Vec3(x: 0, y: 0, z: 0)
            }
            if let maxStr = dict["distancemax"] as? String, let maxVec = Vec3.parse(maxStr) {
                distanceMax = maxVec
            } else if let minStr = dict["distancemin"] as? String, let minVec = Vec3.parse(minStr) {
                distanceMax = minVec
            } else {
                distanceMax = Vec3(x: 0, y: 0, z: 0)
            }
            return .boxRandom(rate: rate, origin: origin, directions: directions,
                             distanceMin: distanceMin, distanceMax: distanceMax)

        default:
            return nil
        }
    }

    private static func parseInitializer(_ dict: [String: Any]) -> ParticleInitializer? {
        guard let name = dict["name"] as? String else { return nil }

        switch name {
        case "lifetimerandom":
            let min: Double
            let max: Double
            // min 필드가 JSON에 있는가?
            if let minVal = getDouble(dict["min"]) {
                min = minVal
            } else if dict["min"] != nil {
                // min이 있지만 파싱 불가
                return nil
            } else {
                // min이 없음. max가 있는가?
                if let maxVal = getDouble(dict["max"]) {
                    min = maxVal
                } else {
                    return nil
                }
            }
            // max 필드가 JSON에 있는가?
            if let maxVal = getDouble(dict["max"]) {
                max = maxVal
            } else if dict["max"] != nil {
                // max가 있지만 파싱 불가
                return nil
            } else {
                // max가 없음. min이 있는가? (이미 위에서 확인했으므로)
                if let minVal = getDouble(dict["min"]) {
                    max = minVal
                } else {
                    return nil
                }
            }
            return .lifetimeRandom(min: min, max: max)

        case "sizerandom":
            let min: Double
            let max: Double
            if let minVal = getDouble(dict["min"]) {
                min = minVal
            } else if dict["min"] != nil {
                return nil
            } else if let maxVal = getDouble(dict["max"]) {
                min = maxVal
            } else {
                return nil
            }
            if let maxVal = getDouble(dict["max"]) {
                max = maxVal
            } else if dict["max"] != nil {
                return nil
            } else if let minVal = getDouble(dict["min"]) {
                max = minVal
            } else {
                return nil
            }
            return .sizeRandom(min: min, max: max)

        case "alpharandom":
            let min: Double
            let max: Double
            if let minVal = getDouble(dict["min"]) {
                min = minVal
            } else if dict["min"] != nil {
                return nil
            } else if let maxVal = getDouble(dict["max"]) {
                min = maxVal
            } else {
                return nil
            }
            if let maxVal = getDouble(dict["max"]) {
                max = maxVal
            } else if dict["max"] != nil {
                return nil
            } else if let minVal = getDouble(dict["min"]) {
                max = minVal
            } else {
                return nil
            }
            return .alphaRandom(min: min, max: max)

        case "velocityrandom":
            let minVec: Vec3
            let maxVec: Vec3
            if let minStr = dict["min"] as? String {
                guard let mv = Vec3.parse(minStr) else { return nil }
                minVec = mv
            } else if dict["min"] != nil {
                return nil
            } else if let maxStr = dict["max"] as? String, let mv = Vec3.parse(maxStr) {
                minVec = mv
            } else {
                return nil
            }
            if let maxStr = dict["max"] as? String {
                guard let mv = Vec3.parse(maxStr) else { return nil }
                maxVec = mv
            } else if dict["max"] != nil {
                return nil
            } else if let minStr = dict["min"] as? String, let mv = Vec3.parse(minStr) {
                maxVec = mv
            } else {
                return nil
            }
            return .velocityRandom(min: minVec, max: maxVec)

        case "colorrandom":
            let minVec: Vec3
            let maxVec: Vec3
            if let minStr = dict["min"] as? String {
                guard let mv = Vec3.parse(minStr) else { return nil }
                minVec = mv
            } else if dict["min"] != nil {
                return nil
            } else if let maxStr = dict["max"] as? String, let mv = Vec3.parse(maxStr) {
                minVec = mv
            } else {
                return nil
            }
            if let maxStr = dict["max"] as? String {
                guard let mv = Vec3.parse(maxStr) else { return nil }
                maxVec = mv
            } else if dict["max"] != nil {
                return nil
            } else if let minStr = dict["min"] as? String, let mv = Vec3.parse(minStr) {
                maxVec = mv
            } else {
                return nil
            }
            return .colorRandom(min: minVec, max: maxVec)

        case "rotationrandom":
            let minVec: Vec3
            let maxVec: Vec3
            if let minStr = dict["min"] as? String {
                guard let mv = Vec3.parse(minStr) else { return nil }
                minVec = mv
            } else if dict["min"] != nil {
                return nil
            } else if let maxStr = dict["max"] as? String, let mv = Vec3.parse(maxStr) {
                minVec = mv
            } else {
                return nil
            }
            if let maxStr = dict["max"] as? String {
                guard let mv = Vec3.parse(maxStr) else { return nil }
                maxVec = mv
            } else if dict["max"] != nil {
                return nil
            } else if let minStr = dict["min"] as? String, let mv = Vec3.parse(minStr) {
                maxVec = mv
            } else {
                return nil
            }
            return .rotationRandom(min: minVec, max: maxVec)

        case "angularvelocityrandom":
            let minVec: Vec3
            let maxVec: Vec3
            if let minStr = dict["min"] as? String {
                guard let mv = Vec3.parse(minStr) else { return nil }
                minVec = mv
            } else if dict["min"] != nil {
                return nil
            } else if let maxStr = dict["max"] as? String, let mv = Vec3.parse(maxStr) {
                minVec = mv
            } else {
                return nil
            }
            if let maxStr = dict["max"] as? String {
                guard let mv = Vec3.parse(maxStr) else { return nil }
                maxVec = mv
            } else if dict["max"] != nil {
                return nil
            } else if let minStr = dict["min"] as? String, let mv = Vec3.parse(minStr) {
                maxVec = mv
            } else {
                return nil
            }
            return .angularVelocityRandom(min: minVec, max: maxVec)

        case "turbulentvelocityrandom":
            // 필드: offset, scale, speedmin, speedmax (모두 Double)
            let offset = getDouble(dict["offset"]) ?? 0
            let scale = getDouble(dict["scale"]) ?? 0
            let speedMin = getDouble(dict["speedmin"]) ?? 0
            let speedMax = getDouble(dict["speedmax"]) ?? 0
            return .turbulentVelocityRandom(offset: offset, scale: scale, speedMin: speedMin, speedMax: speedMax)

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
