import Foundation

public enum ParticleEmitter: Equatable, Sendable {
    case sphereRandom(rate: Double, origin: Vec3, directions: Vec3,
                      distanceMin: Double, distanceMax: Double)
    case boxRandom(rate: Double, origin: Vec3, directions: Vec3, min: Vec3, max: Vec3)
}

public enum ParticleInitializer: Equatable, Sendable {
    case lifetimeRandom(min: Double, max: Double)
    case sizeRandom(min: Double, max: Double)
    case alphaRandom(min: Double, max: Double)
    case velocityRandom(min: Vec3, max: Vec3)
    case colorRandom(min: Vec3, max: Vec3)
    case rotationRandom(min: Vec3, max: Vec3)
    case angularVelocityRandom(min: Vec3, max: Vec3)
    case turbulentVelocityRandom(min: Vec3, max: Vec3)
}

public enum ParticleOperator: Equatable, Sendable {
    case movement(gravity: Vec3, drag: Double)
    case angularMovement(gravity: Vec3, drag: Double)
    case alphaFade(fadeInTime: Double, fadeOutTime: Double)
    case oscillatePosition(mask: Vec3, scaleMin: Double, scaleMax: Double,
                           frequencyMin: Double, frequencyMax: Double,
                           phaseMin: Double, phaseMax: Double)
    case oscillateAlpha(frequencyMin: Double, frequencyMax: Double,
                        phaseMin: Double, phaseMax: Double)
    case controlPointAttract(controlPoint: Int, scale: Double, radius: Double)
}

public struct ParticlePreset: Equatable, Sendable {
    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    /// 실물 프리셋의 최대가 300이므로 8192는 충분히 관대하다.
    public static let maxAllowedCount = 8192

    public let maxCount: Int
    public let startTime: Double
    public let materialPath: String
    public let emitters: [ParticleEmitter]
    public let initializers: [ParticleInitializer]
    public let operators: [ParticleOperator]
    /// 인식하지 못한 이름들. 무엇이 빠졌는지 사용자에게 말할 수 있게 남긴다.
    public let unsupportedNames: [String]
    /// 이름은 아는데 필드가 깨져서 버린 엔트리들. 지원하지 않는 것과 구분한다.
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

        guard let rate = getDouble(dict["rate"]) else { return nil }
        guard let origin = dict["origin"] as? String, let originVec = Vec3.parse(origin) else { return nil }
        guard let directions = dict["directions"] as? String, let directionsVec = Vec3.parse(directions) else { return nil }

        switch name {
        case "sphererandom":
            guard let distanceMin = getDouble(dict["distancemin"]) else { return nil }
            guard let distanceMax = getDouble(dict["distancemax"]) else { return nil }
            return .sphereRandom(rate: rate, origin: originVec, directions: directionsVec,
                                distanceMin: distanceMin, distanceMax: distanceMax)

        case "boxrandom":
            guard let min = dict["min"] as? String, let minVec = Vec3.parse(min) else { return nil }
            guard let max = dict["max"] as? String, let maxVec = Vec3.parse(max) else { return nil }
            return .boxRandom(rate: rate, origin: originVec, directions: directionsVec, min: minVec, max: maxVec)

        default:
            return nil
        }
    }

    private static func parseInitializer(_ dict: [String: Any]) -> ParticleInitializer? {
        guard let name = dict["name"] as? String else { return nil }

        switch name {
        case "lifetimerandom":
            guard let min = getDouble(dict["min"]) else { return nil }
            guard let max = getDouble(dict["max"]) else { return nil }
            return .lifetimeRandom(min: min, max: max)

        case "sizerandom":
            guard let min = getDouble(dict["min"]) else { return nil }
            guard let max = getDouble(dict["max"]) else { return nil }
            return .sizeRandom(min: min, max: max)

        case "alpharandom":
            guard let min = getDouble(dict["min"]) else { return nil }
            guard let max = getDouble(dict["max"]) else { return nil }
            return .alphaRandom(min: min, max: max)

        case "velocityrandom":
            guard let minStr = dict["min"] as? String, let minVec = Vec3.parse(minStr) else { return nil }
            guard let maxStr = dict["max"] as? String, let maxVec = Vec3.parse(maxStr) else { return nil }
            return .velocityRandom(min: minVec, max: maxVec)

        case "colorrandom":
            guard let minStr = dict["min"] as? String, let minVec = Vec3.parse(minStr) else { return nil }
            guard let maxStr = dict["max"] as? String, let maxVec = Vec3.parse(maxStr) else { return nil }
            return .colorRandom(min: minVec, max: maxVec)

        case "rotationrandom":
            guard let minStr = dict["min"] as? String, let minVec = Vec3.parse(minStr) else { return nil }
            guard let maxStr = dict["max"] as? String, let maxVec = Vec3.parse(maxStr) else { return nil }
            return .rotationRandom(min: minVec, max: maxVec)

        case "angularvelocityrandom":
            guard let minStr = dict["min"] as? String, let minVec = Vec3.parse(minStr) else { return nil }
            guard let maxStr = dict["max"] as? String, let maxVec = Vec3.parse(maxStr) else { return nil }
            return .angularVelocityRandom(min: minVec, max: maxVec)

        case "turbulentvelocityrandom":
            guard let minStr = dict["min"] as? String, let minVec = Vec3.parse(minStr) else { return nil }
            guard let maxStr = dict["max"] as? String, let maxVec = Vec3.parse(maxStr) else { return nil }
            return .turbulentVelocityRandom(min: minVec, max: maxVec)

        default:
            return nil
        }
    }

    private static func parseOperator(_ dict: [String: Any]) -> ParticleOperator? {
        guard let name = dict["name"] as? String else { return nil }

        switch name {
        case "movement":
            guard let gravityStr = dict["gravity"] as? String, let gravityVec = Vec3.parse(gravityStr) else { return nil }
            let drag = getDouble(dict["drag"]) ?? 0
            return .movement(gravity: gravityVec, drag: drag)

        case "angularmovement":
            guard let gravityStr = dict["gravity"] as? String, let gravityVec = Vec3.parse(gravityStr) else { return nil }
            let drag = getDouble(dict["drag"]) ?? 0
            return .angularMovement(gravity: gravityVec, drag: drag)

        case "alphafade":
            let fadeInTime = getDouble(dict["fadeintime"]) ?? 0
            let fadeOutTime = getDouble(dict["fadeouttime"]) ?? 0
            return .alphaFade(fadeInTime: fadeInTime, fadeOutTime: fadeOutTime)

        case "oscillateposition":
            guard let maskStr = dict["mask"] as? String, let maskVec = Vec3.parse(maskStr) else { return nil }
            guard let scaleMin = getDouble(dict["scalemin"]) else { return nil }
            guard let scaleMax = getDouble(dict["scalemax"]) else { return nil }
            guard let frequencyMin = getDouble(dict["frequencymin"]) else { return nil }
            guard let frequencyMax = getDouble(dict["frequencymax"]) else { return nil }
            guard let phaseMin = getDouble(dict["phasemin"]) else { return nil }
            guard let phaseMax = getDouble(dict["phasemax"]) else { return nil }
            return .oscillatePosition(mask: maskVec, scaleMin: scaleMin, scaleMax: scaleMax,
                                     frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                     phaseMin: phaseMin, phaseMax: phaseMax)

        case "oscillatealpha":
            guard let frequencyMin = getDouble(dict["frequencymin"]) else { return nil }
            guard let frequencyMax = getDouble(dict["frequencymax"]) else { return nil }
            guard let phaseMin = getDouble(dict["phasemin"]) else { return nil }
            guard let phaseMax = getDouble(dict["phasemax"]) else { return nil }
            return .oscillateAlpha(frequencyMin: frequencyMin, frequencyMax: frequencyMax,
                                  phaseMin: phaseMin, phaseMax: phaseMax)

        case "controlpointattract":
            guard let controlPoint = getInt(dict["controlpoint"]) else { return nil }
            guard let scale = getDouble(dict["scale"]) else { return nil }
            guard let radius = getDouble(dict["radius"]) else { return nil }
            return .controlPointAttract(controlPoint: controlPoint, scale: scale, radius: radius)

        default:
            return nil
        }
    }
}
