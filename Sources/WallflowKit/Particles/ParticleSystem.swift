import Foundation

/// A single particle with all its state.
public struct Particle: Equatable, Sendable {
    public var position: Vec3
    public var velocity: Vec3
    public var rotation: Vec3
    public var angularVelocity: Vec3
    public var color: Vec3
    public var size: Double
    public var alpha: Double
    public var age: Double
    public var lifetime: Double
    /// 스프라이트 시트에서 어느 칸을 쓸지 정하는 0~1 난수. 태어날 때 한 번 정한다.
    ///
    /// `animationmode: randomframe`인 프리셋은 파티클마다 **한 장을 골라 고정**한다.
    /// 수명에 따라 훑으면 빗방울이 16장을 오가며 깜빡인다(실물에서 확인).
    public var frameSeed: Double = 0
    /// 태어날 때 정해진 크기와 투명도. 수명에 따라 변하는 연산자들이 **여기서부터**
    /// 다시 계산한다. 직전 프레임 값에 곱하면 프레임마다 복리로 줄어들어,
    /// 화면 주사율이 다르면 같은 배경화면이 다르게 보인다.
    public var baseSize: Double = 1
    public var baseAlpha: Double = 1
    public var baseColor: Vec3 = Vec3(x: 1, y: 1, z: 1)

    public var isAlive: Bool {
        age < lifetime
    }
}

/// CPU-based particle system simulation.
public final class ParticleSystem {
    /// Maximum time step for a single update call.
    /// When waking from sleep, deltaTime can be thousands of seconds.
    /// If applied directly, particles teleport off-screen.
    /// If subdivided into small steps, the system hangs.
    /// So we discard overflow.
    public static let maxTimeStep = 0.1

    private let preset: ParticlePreset
    private let random: RandomSource
    /// 씬 배율(`instanceoverride`). 스크립트가 `layer.instance`로 바꾼다 —
    /// 스폰 결과는 **새로 나는** 파티클부터, 힘은 바로 먹는다.
    public var instance: ParticleOverride

    /// Fixed-size particle buffer. Dead slots are reused.
    private var particleBuffer: [Particle]
    /// Number of alive particles.
    private var numAlive: Int = 0
    /// Indices of dead slots available for reuse.
    private var deadSlots: [Int] = []
    /// 시작할 때의 한꺼번에 방출을 이미 했는지. 한 번만 한다.
    private var didBurst = false

    /// 이 시스템이 놓인 자리. 자식 시스템이 부모 파티클을 따라다닐 때 여기가 바뀐다.
    /// 방출할 때 파티클 위치에 더해진다.
    public var originOffset = Vec3(x: 0, y: 0, z: 0)

    /// 이 프리셋이 거느리는 자식들(정의).
    private let children: [ParticleChild]
    /// 정의마다 지금 살아 있는 자식 시스템들.
    private var childInstances: [[ChildInstance]]

    /// 자식 시스템 한 벌.
    private final class ChildInstance {
        let system: ParticleSystem
        /// `follow`일 때 따라다니는 부모 슬롯. 부모가 죽으면 nil이 되고,
        /// 남은 파티클이 사라질 때까지만 더 산다.
        var followSlot: Int?
        /// 부모 사건이 끝나 더는 새로 뿌리지 않는 상태.
        var isRetiring = false

        init(system: ParticleSystem, followSlot: Int?) {
            self.system = system
            self.followSlot = followSlot
        }
    }
    /// 이미터별 방출 크레딧. 못 내보낸 몫이 쌓이지 않는지는 aliveCount로 관찰할 수 없어서
    /// (슬롯 수가 구조적 상한이라 항상 통과한다) 테스트가 이 값을 직접 본다.
    var emissionCredits: [Double] = []

    /// 프리셋에 있지만 이 시뮬레이션이 아직 처리하지 않는 연산자 이름들.
    /// 조용히 무시하면 사용자가 레이어가 안 움직이는 이유를 알 수 없고,
    /// 나중에 렌더러 버그로 오인된다.
    public private(set) var unimplementedOperators: [String] = []
    /// 매 프레임 기준값으로 되돌릴지. 연산자 목록을 프레임마다 훑지 않으려고 미리 센다.
    private let hasSizeCurve: Bool
    private let hasAlphaCurve: Bool
    private let hasColorCurve: Bool
    /// 시스템이 살아 있은 시간. 잡음과 소용돌이가 시간에 따라 흐른다.
    private var elapsed: Double = 0
    /// 마우스 커서의 자리(이 시스템의 좌표계). 매 프레임 렌더러가 넣어 준다.
    /// 없으면 커서를 따라가는 제어점이 시스템 자리에 머문다.
    public var cursorPosition: Vec3?
    /// `mapsequencearoundcontrolpoint` 초기화자별로 다음에 쓸 자리 번호.
    /// 초기화자가 배열에 여럿 있어도 서로 안 섞이게 `initializers` 안 위치로 키를 잡는다.
    private var sequenceCounters: [Int: Int] = [:]

    public init(preset: ParticlePreset, random: RandomSource) {
        self.preset = preset
        self.random = random
        self.instance = preset.instance
        self.children = preset.children
        self.childInstances = Array(repeating: [], count: preset.children.count)

        let maxCount = max(0, preset.maxCount)
        self.particleBuffer = Array(repeating: Particle(
            position: Vec3(x: 0, y: 0, z: 0),
            velocity: Vec3(x: 0, y: 0, z: 0),
            rotation: Vec3(x: 0, y: 0, z: 0),
            angularVelocity: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 1, y: 1, z: 1),
            size: 1,
            alpha: 1,
            age: Double.infinity,
            lifetime: 1
        ), count: maxCount)

        // Initialize dead slots (all slots are dead at start)
        self.deadSlots = Array(0..<maxCount).reversed()
        // Initialize emission credits
        self.emissionCredits = Array(repeating: 0.0, count: preset.emitters.count)

        // 무엇을 아직 못 하는지 남긴다. 조용히 무시하면 사용자는 레이어가 왜
        // 안 움직이는지 알 수 없다.
        var unimplemented = Set<String>()
        for op in preset.operators {
            // 제어점은 프리셋이 정의한다. 우리가 못 푸는 묶임(마우스가 아닌
            // 다른 무엇)이면 그 사실을 번호와 함께 남긴다.
            if case .controlPointAttract(let point, _, _, _) = op,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("controlpointattract(제어점 \(point))")
            }
            // 우리가 안 넣는 출력은 이름과 함께 남긴다.
            if case .remapValue(let output, _, _, _, _) = op,
               case .unsupported(let name) = output {
                unimplemented.insert("remapvalue(\(name))")
            }
        }
        for initializer in preset.initializers {
            if case .mapSequenceAroundControlPoint(let point, _, _, _, _, _, _) = initializer,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("mapsequencearoundcontrolpoint(제어점 \(point))")
            }
        }
        self.unimplementedOperators = Array(unimplemented).sorted()
        self.hasSizeCurve = preset.operators.contains {
            switch $0 {
            case .sizeChange, .oscillateSize: return true
            case .remapValue(let output, _, _, _, _): return output == .size
            default: return false
            }
        }
        self.hasAlphaCurve = preset.operators.contains {
            switch $0 {
            case .alphaFade, .oscillateAlpha: return true
            case .remapValue(let output, _, _, _, _): return output == .opacity
            default: return false
            }
        }
        self.hasColorCurve = preset.operators.contains {
            if case .colorChange = $0 { return true } else { return false }
        }
    }

    /// Returns only alive particles.
    public var particles: [Particle] {
        var result: [Particle] = []
        for i in 0..<particleBuffer.count {
            if particleBuffer[i].isAlive {
                result.append(particleBuffer[i])
            }
        }
        return result
    }

    /// 그릴 것들을 프리셋별로 모아 준다. 자식까지 재귀로 훑는다.
    ///
    /// 열쇠는 자식 정의를 따라간 경로다(`"0"`, `"0.1"`). 렌더러를 그 열쇠로
    /// 붙들어 두면 프레임마다 다시 만들지 않아도 된다.
    public func renderableGroups(
        prefix: String = "", depth: Int = 0
    ) -> [(key: String, preset: ParticlePreset, particles: [Particle])] {
        var out: [(key: String, preset: ParticlePreset, particles: [Particle])] = [
            (prefix.isEmpty ? "0" : prefix, preset, particles)
        ]
        // 자식의 자식까지는 보되 그 아래로는 내려가지 않는다. 실물에서 두 단계면
        // 충분하고, 순환 참조가 있어도 여기서 멈춘다.
        guard depth < 2 else { return out }
        for (index, instances) in childInstances.enumerated() {
            guard !instances.isEmpty else { continue }
            let key = (prefix.isEmpty ? "0" : prefix) + ".\(index)"
            // 같은 정의에서 나온 여러 벌은 한 렌더러로 함께 그린다.
            var merged: [Particle] = []
            var nested: [String: (ParticlePreset, [Particle])] = [:]
            for instance in instances {
                for group in instance.system.renderableGroups(prefix: key, depth: depth + 1) {
                    if group.key == key {
                        merged.append(contentsOf: group.particles)
                    } else {
                        nested[group.key, default: (group.preset, [])].1
                            .append(contentsOf: group.particles)
                    }
                }
            }
            out.append((key, children[index].preset, merged))
            for (key, value) in nested.sorted(by: { $0.key < $1.key }) {
                out.append((key, value.0, value.1))
            }
        }
        return out
    }

    /// Number of currently alive particles.
    public var aliveCount: Int {
        return numAlive
    }

    /// Update the simulation by deltaTime seconds.
    /// 스크립트의 `thisLayer.play()/stop()`. 멈추면 살아 있는 파티클과 자식을 전부
    /// 거두고 더 뿌리지 않는다 — 실물 "졸음" 씬이 마우스가 움직이면 zzz를 `stop()`으로
    /// 지운다. 다시 틀면 처음처럼 한꺼번에 뿌리는 몫부터 시작한다.
    public private(set) var isPlaying = true

    public func stop() {
        isPlaying = false
        for i in 0..<particleBuffer.count where particleBuffer[i].age < Double.infinity {
            particleBuffer[i].age = Double.infinity
            deadSlots.append(i)
        }
        numAlive = 0
        for index in childInstances.indices { childInstances[index].removeAll() }
    }

    public func play() {
        guard !isPlaying else { return }
        isPlaying = true
        didBurst = false
        emissionCredits = Array(repeating: 0.0, count: preset.emitters.count)
    }

    public func update(deltaTime: Double) {
        // Check for invalid deltaTime
        guard deltaTime.isFinite, deltaTime > 0, isPlaying else { return }

        // Clamp to maxTimeStep
        let dt = Swift.min(deltaTime, Self.maxTimeStep)

        // Remove dead particles from alive tracking
        removeDeadParticles()

        // 시작할 때 한꺼번에 뿌리는 몫. 첫 update에서 한 번만 한다.
        if !didBurst {
            didBurst = true
            emitBurst()
            // `type`이 없는 자식은 "한 번만, 시스템 원점에"다. 실물의 절반이
            // 이 경우이고, 그런 프리셋은 내용 전부가 자식에 들어 있다.
            spawnChildren(on: .once, at: originOffset, slot: nil)
        }

        // Emit new particles
        emitParticles(dt: dt)

        elapsed += dt

        // Apply operators to alive particles
        applyOperators(dt: dt)

        // 자식 시스템도 같은 시간만큼 굴린다.
        updateChildren(dt: dt)

        // Age particles
        ageParticles(dt: dt)
    }

    private func removeDeadParticles() {
        for i in 0..<particleBuffer.count {
            if !particleBuffer[i].isAlive && particleBuffer[i].age < Double.infinity {
                // 죽는 순간이 자식을 낳는 사건이다. 불꽃 폭발이 여기서 일어난다.
                spawnChildren(on: .onDeath, at: particleBuffer[i].position, slot: i)
                deadSlots.append(i)
                particleBuffer[i].age = Double.infinity
                numAlive -= 1
            }
        }
    }

    /// 부모 사건에 맞춰 자식 시스템을 한 벌 만든다.
    ///
    /// 상한을 넘으면 만들지 않는다 — `follow`는 부모 파티클마다 한 벌씩이라
    /// 상한이 없으면 끝없이 는다.
    private func spawnChildren(_ trigger: ParticleChildTrigger, at position: Vec3, slot: Int?) {
        for (index, child) in children.enumerated() where child.reference.trigger == trigger {
            guard childInstances[index].count < child.reference.maxCount else { continue }
            let system = ParticleSystem(preset: child.preset, random: random)
            system.originOffset = Vec3(
                x: position.x + child.reference.origin.x,
                y: position.y + child.reference.origin.y,
                z: position.z + child.reference.origin.z)
            childInstances[index].append(
                ChildInstance(system: system, followSlot: trigger == .follow ? slot : nil))
        }
    }

    /// `spawnChildren`의 이름 있는 짝. 사건 이름을 앞에 두어 읽기 쉽게 한다.
    private func spawnChildren(
        on trigger: ParticleChildTrigger, at position: Vec3, slot: Int?
    ) {
        spawnChildren(trigger, at: position, slot: slot)
    }

    /// 자식 시스템들을 한 프레임 굴린다.
    ///
    /// `follow`는 부모 파티클을 따라간다. 부모가 죽으면 더 따라갈 것이 없으므로
    /// 새로 뿌리는 것만 멈추고, 이미 뿌린 파티클이 사라질 때까지 두었다가 치운다 —
    /// 바로 지우면 꼬리가 뚝 끊긴다.
    private func updateChildren(dt: Double) {
        for index in childInstances.indices {
            for instance in childInstances[index] {
                if let slot = instance.followSlot {
                    if particleBuffer.indices.contains(slot), particleBuffer[slot].isAlive {
                        instance.system.originOffset = particleBuffer[slot].position
                    } else {
                        instance.followSlot = nil
                        instance.isRetiring = true
                    }
                }
                // 자식도 같은 커서를 본다. 안 넘기면 꼬리가 손끝을 무시한다.
                instance.system.cursorPosition = cursorPosition
                instance.system.update(deltaTime: dt)
            }
            childInstances[index].removeAll {
                $0.isRetiring && $0.system.aliveCount == 0
            }
        }
    }

    /// 이미터의 `instantaneous` 몫을 한꺼번에 뿌린다.
    ///
    /// **이걸 안 하면 `rate: 0`인 이미터가 아무것도 안 뿌린다.** 실물 불꽃놀이가
    /// 그렇다 — 터뜨리는 것도(150개 한꺼번에), 날리는 것도(이미터 속력) 전부
    /// 이미터가 하고 `rate`는 0이다. 그래서 불꽃이 통째로 안 보였다.
    private func emitBurst() {
        for emitter in preset.emitters {
            let count = emitter.burst.count
            guard count > 0 else { continue }
            for _ in 0..<count {
                guard let slot = deadSlots.popLast() else { break }
                var particle = emitParticle(from: emitter)
                guard isValidParticle(particle) else {
                    deadSlots.append(slot)
                    continue
                }
                particle.age = 0
                particleBuffer[slot] = particle
                numAlive += 1
                spawnChildren(on: .onSpawn, at: particle.position, slot: slot)
                spawnChildren(on: .follow, at: particle.position, slot: slot)
            }
        }
    }

    private func emitParticles(dt: Double) {
        for (emitterIndex, emitter) in preset.emitters.enumerated() {
            // Accumulate emission credit
            let rate: Double
            switch emitter {
            case .sphereRandom(let r, _, _, _, _, _):
                rate = r
            case .boxRandom(let r, _, _, _, _, _):
                rate = r
            }

            emissionCredits[emitterIndex] += rate * dt

            // Clamp credit to prevent infinite loops
            guard emissionCredits[emitterIndex].isFinite else {
                emissionCredits[emitterIndex] = 0
                continue
            }

            // Emit integer number of particles
            // Int(Double)은 범위 밖에서 트랩한다. 파일에서 온 rate가 거대할 수 있으므로
            // Double 단계에서 먼저 슬롯 수 이하로 죈다. 그 뒤엔 변환이 안전하다.
            let available = Double(deadSlots.count)
            let toEmit = Swift.min(emissionCredits[emitterIndex].rounded(.down), available)
            let emitCount = toEmit > 0 ? Int(toEmit) : 0

            for _ in 0..<emitCount {
                if let slotIndex = deadSlots.popLast() {
                    var particle = emitParticle(from: emitter)
                    if isValidParticle(particle) {
                        particle.age = 0
                        particleBuffer[slotIndex] = particle
                        numAlive += 1
                        spawnChildren(on: .onSpawn, at: particle.position, slot: slotIndex)
                        spawnChildren(on: .follow, at: particle.position, slot: slotIndex)
                    } else {
                        // Particle is invalid, put slot back
                        deadSlots.append(slotIndex)
                    }
                }
            }

            // 슬롯이 없어 못 내보낸 몫은 버린다. 남겨두면 프레임마다 쌓였다가
            // 슬롯이 비는 순간 한꺼번에 터진다.
            emissionCredits[emitterIndex] = Swift.min(
                emissionCredits[emitterIndex] - Double(emitCount), 1.0)
        }
    }

    private func emitParticle(from emitter: ParticleEmitter) -> Particle {
        var particle = Particle(
            position: Vec3(x: 0, y: 0, z: 0),
            velocity: Vec3(x: 0, y: 0, z: 0),
            rotation: Vec3(x: 0, y: 0, z: 0),
            angularVelocity: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 1, y: 1, z: 1),
            size: 1,
            alpha: 1,
            age: 0,
            lifetime: 1,
            frameSeed: random.next()
        )

        // Apply emitter position and velocity
        switch emitter {
        case .sphereRandom(_, let origin, let directions, let distanceMin, let distanceMax, _):
            particle.position = origin
            // Random direction within cone
            let theta = random.next() * 2 * .pi
            let phi = acos(2 * random.next() - 1)
            let distance = distanceMin + random.next() * (distanceMax - distanceMin)
            // 방향은 거리와 따로 둔다. 뿌리는 반경이 0이어도(불꽃이 그렇다)
            // 날아가는 방향은 있어야 하기 때문이다.
            let unit = Vec3(
                x: sin(phi) * cos(theta) * directions.x,
                y: sin(phi) * sin(theta) * directions.y,
                z: cos(phi) * directions.z
            )
            particle.position = Vec3(
                x: originOffset.x + origin.x + unit.x * distance,
                y: originOffset.y + origin.y + unit.y * distance,
                z: originOffset.z + origin.z + unit.z * distance
            )
            applyEmitterSpeed(emitter.burst, direction: unit, to: &particle)

        case .boxRandom(_, let origin, let directions, let distanceMin, let distanceMax, _):
            let offset = Vec3(
                x: (distanceMin.x + random.next() * (distanceMax.x - distanceMin.x)) * directions.x,
                y: (distanceMin.y + random.next() * (distanceMax.y - distanceMin.y)) * directions.y,
                z: (distanceMin.z + random.next() * (distanceMax.z - distanceMin.z)) * directions.z
            )
            particle.position = Vec3(
                x: originOffset.x + origin.x + offset.x,
                y: originOffset.y + origin.y + offset.y,
                z: originOffset.z + origin.z + offset.z
            )
            applyEmitterSpeed(emitter.burst, direction: offset, to: &particle)
        }

        // Apply initializers
        for (index, initializer) in preset.initializers.enumerated() {
            applyInitializer(initializer, index: index, to: &particle)
        }

        // 씬 배율은 초기화자가 끝난 **결과**에 곱한다. 초기화자에 곱하면 그 초기화자가
        // 없는 프리셋(기본 크기·수명·흰색)에는 안 먹는다 — 실물 PS2 시계 파티클은
        // colorrandom이 없어 colorn이 통째로 버려졌다. 속도는 이미터 속력(불꽃)까지
        // 포함한 최종 속도다. 색은 틴트(곱)에 밝기를 얹는다.
        let o = instance
        particle.size *= o.size
        particle.alpha *= o.alpha
        particle.lifetime *= o.lifetime
        particle.velocity = Vec3(x: particle.velocity.x * o.speed,
                                 y: particle.velocity.y * o.speed,
                                 z: particle.velocity.z * o.speed)
        let tint = o.color ?? Vec3(x: 1, y: 1, z: 1)
        particle.color = Vec3(x: particle.color.x * tint.x * o.brightness,
                              y: particle.color.y * tint.y * o.brightness,
                              z: particle.color.z * tint.z * o.brightness)

        // 초기화자가 끝난 값이 기준값이다.
        particle.baseSize = particle.size
        particle.baseAlpha = particle.alpha
        particle.baseColor = particle.color

        return particle
    }

    /// 이미터가 주는 초기 속력을 얹는다. 방향은 뿌린 자리에서 바깥쪽이다.
    ///
    /// **초기화자보다 먼저** 얹는다. `velocityrandom`이 있으면 그것이 이기고,
    /// 없으면(불꽃이 그렇다) 이 속력이 유일한 운동원이다.
    private func applyEmitterSpeed(
        _ burst: ParticleEmitterBurst, direction: Vec3, to particle: inout Particle
    ) {
        guard burst.speedMax > 0 || burst.speedMin > 0 else { return }
        let length = (direction.x * direction.x + direction.y * direction.y
            + direction.z * direction.z).squareRoot()
        // 방향이 없으면 속력을 줄 곳도 없다.
        guard length > 1e-9, length.isFinite else { return }
        let speed = burst.speedMin + random.next() * (burst.speedMax - burst.speedMin)
        guard speed.isFinite else { return }
        particle.velocity = Vec3(
            x: direction.x / length * speed,
            y: direction.y / length * speed,
            z: direction.z / length * speed
        )
    }

    private func applyInitializer(
        _ initializer: ParticleInitializer, index: Int, to particle: inout Particle
    ) {
        switch initializer {
        case .lifetimeRandom(let min, let max):
            particle.lifetime = min + random.next() * (max - min)

        case .sizeRandom(let min, let max):
            particle.size = min + random.next() * (max - min)

        case .alphaRandom(let min, let max):
            particle.alpha = min + random.next() * (max - min)

        case .velocityRandom(let min, let max):
            particle.velocity = Vec3(
                x: min.x + random.next() * (max.x - min.x),
                y: min.y + random.next() * (max.y - min.y),
                z: min.z + random.next() * (max.z - min.z)
            )

        case .colorRandom(let min, let max):
            particle.color = Vec3(
                x: min.x + random.next() * (max.x - min.x),
                y: min.y + random.next() * (max.y - min.y),
                z: min.z + random.next() * (max.z - min.z)
            )

        case .rotationRandom(let min, let max):
            particle.rotation = Vec3(
                x: min.x + random.next() * (max.x - min.x),
                y: min.y + random.next() * (max.y - min.y),
                z: min.z + random.next() * (max.z - min.z)
            )

        case .angularVelocityRandom(let min, let max):
            particle.angularVelocity = Vec3(
                x: min.x + random.next() * (max.x - min.x),
                y: min.y + random.next() * (max.y - min.y),
                z: min.z + random.next() * (max.z - min.z)
            )

        case .turbulentVelocityRandom(let offset, let scale, let speedMin, let speedMax):
            // offset, scale, speedMin, speedMax를 조합해 난수 속도 생성
            let speed = speedMin + random.next() * (speedMax - speedMin)
            let theta = random.next() * 2 * .pi
            let phi = acos(2 * random.next() - 1)
            let turbulence = Vec3(
                x: (offset + speed * sin(phi) * cos(theta)) * scale,
                y: (offset + speed * sin(phi) * sin(theta)) * scale,
                z: (offset + speed * cos(phi)) * scale
            )
            particle.velocity = Vec3(
                x: particle.velocity.x + turbulence.x,
                y: particle.velocity.y + turbulence.y,
                z: particle.velocity.z + turbulence.z
            )

        case .mapSequenceAroundControlPoint(let controlPoint, let count, let boundsStart,
                                            let boundsEnd, let mirror, let speedMin, let speedMax):
            // 못 푸는 제어점이면(0번이 아닌데 씬이 자리를 안 줬거나 알 수 없는
            // 묶임) 생성자가 이미 `unimplementedOperators`로 보고했다. 여기서는
            // 이미터가 준 자리를 그대로 두고 속도만 준다 — 아무것도 안 하면
            // 파티클이 원점(0,0,0)으로 순간이동해 더 눈에 띈다.
            let center = controlPointPosition(controlPoint) ?? originOffset

            // 순번을 count로 나눠 원 위의 0~1 자리를 고른다. mirror면 왕복
            // (0→1→0→…), 아니면 반복(0→1, 0→1, …)한다 — 문서의 "Orientation"
            // (Repeat/Mirror) 그대로다.
            let slot = Self.nextSequenceSlot(&sequenceCounters[index, default: 0], count: count,
                                             mirror: mirror)
            let fraction = count > 0 ? slot / count : 0
            let angle = (boundsStart + (boundsEnd - boundsStart) * fraction) * 2 * .pi

            // 반지름은 이미터가 이미 뿌린 자리에서 온다(문서: 같은 제어점에
            // 이미터를 묶지 않으면 원 크기가 거리에 따라 달라진다 — 즉 반지름은
            // 이 초기화자가 정하지 않고 넘겨받는다). z는 손대지 않는다(2D 배경화면
            // 기준, 문서의 "Axis"는 3D에서만 의미가 있다고 적혀 있다).
            let toParticle = Vec3(x: particle.position.x - center.x,
                                  y: particle.position.y - center.y,
                                  z: 0)
            let radius = (toParticle.x * toParticle.x + toParticle.y * toParticle.y).squareRoot()

            particle.position = Vec3(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius,
                z: particle.position.z)

            // speedmin/speedmax가 실물에서 벡터라 축별 독립 난수로 읽는다
            // (근거는 타입 선언부 주석 참고).
            particle.velocity = Vec3(
                x: speedMin.x + random.next() * (speedMax.x - speedMin.x),
                y: speedMin.y + random.next() * (speedMax.y - speedMin.y),
                z: speedMin.z + random.next() * (speedMax.z - speedMin.z))
        }
    }

    /// `mapsequencearoundcontrolpoint`가 다음에 쓸 자리 번호를 뽑고 카운터를 넘긴다.
    /// `mirror`면 0→count-1→0으로 왕복하고, 아니면 0→count-1을 반복한다.
    static func nextSequenceSlot(_ counter: inout Int, count: Double, mirror: Bool) -> Double {
        // count가 정수가 아닐 수 있다(실물 `magic_trinity`가 3.02다). 주기는
        // 정수 자리 개수로 잡되, 자리 자체는 count를 그대로 나눠 쓴다 —
        // 정수부만 쓰면 실물 값 3.02가 3과 다를 이유가 사라진다.
        let period = Swift.max(1, Int(count.rounded(.down)))
        let span = mirror ? Swift.max(1, period * 2 - 2) : period
        let phase = counter % span
        counter += 1
        let slot = mirror && phase >= period ? span - phase : phase
        return Double(slot)
    }

    private func applyOperators(dt: Double) {
        for i in 0..<particleBuffer.count {
            guard particleBuffer[i].isAlive else { continue }

            // 수명에 따라 곱하는 연산자들은 기준값에서 다시 시작한다.
            // 여러 개가 겹쳐 곱해지되(섬광은 커지는 것과 작아지는 것 둘이다),
            // 프레임을 넘어 쌓이지는 않는다.
            if hasSizeCurve { particleBuffer[i].size = particleBuffer[i].baseSize }
            if hasAlphaCurve { particleBuffer[i].alpha = particleBuffer[i].baseAlpha }
            if hasColorCurve { particleBuffer[i].color = particleBuffer[i].baseColor }

            for op in preset.operators {
                applyOperator(op, to: &particleBuffer[i], dt: dt)
            }
        }
    }

    private func applyOperator(_ op: ParticleOperator, to particle: inout Particle, dt: Double) {
        switch op {
        case .movement(let gravity, let drag):
            // 중력은 힘이다. 초기 속도와 함께 speed 배율을 받아야 궤적이 같은
            // 모양으로 늘어난다(문서: "initial velocity and forces").
            let force = instance.speed
            particle.velocity = Vec3(
                x: particle.velocity.x + gravity.x * force * dt,
                y: particle.velocity.y + gravity.y * force * dt,
                z: particle.velocity.z + gravity.z * force * dt
            )

            // drag는 초당 감쇠 계수다 — dv/dt = −drag·v. 실물 프리셋의 3분의 1이 1을
            // 넘는다(반딧불 2.5, 불꽃 3.5~4). `pow(1 − drag, dt)`는 그때 밑이 음수라
            // NaN이 되어 파티클이 첫 프레임 뒤 사라졌다.
            if drag > 0 {
                let dampFactor = exp(-drag * dt)
                particle.velocity = Vec3(
                    x: particle.velocity.x * dampFactor,
                    y: particle.velocity.y * dampFactor,
                    z: particle.velocity.z * dampFactor
                )
            }

            // Update position
            particle.position = Vec3(
                x: particle.position.x + particle.velocity.x * dt,
                y: particle.position.y + particle.velocity.y * dt,
                z: particle.position.z + particle.velocity.z * dt
            )

        case .angularMovement(let force, let drag):
            // Apply force as angular acceleration
            particle.angularVelocity = Vec3(
                x: particle.angularVelocity.x + force.x * dt,
                y: particle.angularVelocity.y + force.y * dt,
                z: particle.angularVelocity.z + force.z * dt
            )

            if drag > 0 {
                let dampFactor = pow(1 - drag, dt)
                particle.angularVelocity = Vec3(
                    x: particle.angularVelocity.x * dampFactor,
                    y: particle.angularVelocity.y * dampFactor,
                    z: particle.angularVelocity.z * dampFactor
                )
            }

            particle.rotation = Vec3(
                x: particle.rotation.x + particle.angularVelocity.x * dt,
                y: particle.rotation.y + particle.angularVelocity.y * dt,
                z: particle.rotation.z + particle.angularVelocity.z * dt
            )

        case .alphaFade(let fadeInTime, let fadeOutTime):
            // 시각은 수명 대비 비율이다. 나이를 그대로 쓰면 수명이 0.3초짜리
            // 물방울이 `fadeouttime: 0.9`에 걸려 통째로 사라진다.
            guard particle.lifetime > 0 else { return }
            let progress = min(max(particle.age / particle.lifetime, 0), 1)
            var factor = 1.0
            if fadeInTime > 0, progress < fadeInTime {
                factor = progress / fadeInTime
            }
            if fadeOutTime < 1, progress > fadeOutTime {
                factor = min(factor, (1 - progress) / (1 - fadeOutTime))
            }
            particle.alpha = max(0, min(1, particle.baseAlpha * factor))

        case .sizeChange(let startTime, let endTime, let startValue, let endValue):
            guard particle.lifetime > 0 else { return }
            let progress = min(max(particle.age / particle.lifetime, 0), 1)
            let factor: Double
            if progress <= startTime {
                factor = startValue
            } else if progress >= endTime || endTime <= startTime {
                factor = endValue
            } else {
                let t = (progress - startTime) / (endTime - startTime)
                factor = startValue + (endValue - startValue) * t
            }
            // 겹쳐 곱한다. 실물 섬광은 앞 절반에 0→1로 커지는 것과 뒤 절반에
            // 1→0으로 작아지는 것 둘을 함께 건다.
            particle.size = max(0, particle.size * factor)

        case .oscillatePosition(let mask, let scaleMin, let scaleMax, let frequencyMin, let frequencyMax, let phaseMin, let phaseMax):
            let scale = scaleMin + random.next() * (scaleMax - scaleMin)
            let frequency = frequencyMin + random.next() * (frequencyMax - frequencyMin)
            let phase = phaseMin + random.next() * (phaseMax - phaseMin)

            let oscillation = sin(frequency * particle.age * 2 * .pi + phase) * scale

            particle.position = Vec3(
                x: particle.position.x + mask.x * oscillation * dt,
                y: particle.position.y + mask.y * oscillation * dt,
                z: particle.position.z + mask.z * oscillation * dt
            )

        case .oscillateAlpha(let frequencyMin, let frequencyMax, let scaleMin, let scaleMax):
            // 진동수와 위상은 **파티클마다 태어날 때 정해진다.** 프레임마다 새로
            // 뽑으면 파티클 하나가 매 프레임 다른 주기를 타서, 흔들리는 게 아니라
            // 무작위로 깜빡인다.
            let frequency = frequencyMin
                + Self.hash(particle.frameSeed, 11) * (frequencyMax - frequencyMin)
            let phase = Self.hash(particle.frameSeed, 12) * 2 * .pi
            let wave = 0.5 + 0.5 * sin(frequency * particle.age * 2 * .pi + phase)
            particle.alpha = particle.baseAlpha * (scaleMin + (scaleMax - scaleMin) * wave)

        case .oscillateSize(let frequencyMin, let frequencyMax, let scaleMin, let scaleMax):
            let frequency = frequencyMin
                + Self.hash(particle.frameSeed, 21) * (frequencyMax - frequencyMin)
            let phase = Self.hash(particle.frameSeed, 22) * 2 * .pi
            let wave = 0.5 + 0.5 * sin(frequency * particle.age * 2 * .pi + phase)
            particle.size = Swift.max(
                0, particle.size * (scaleMin + (scaleMax - scaleMin) * wave))

        case .colorChange(let startTime, let endTime, let startValue, let endValue):
            guard particle.lifetime > 0 else { return }
            let progress = min(max(particle.age / particle.lifetime, 0), 1)
            let factor: Vec3
            if progress <= startTime || endTime <= startTime {
                factor = progress <= startTime ? startValue : endValue
            } else if progress >= endTime {
                factor = endValue
            } else {
                let t = (progress - startTime) / (endTime - startTime)
                factor = Vec3(
                    x: startValue.x + (endValue.x - startValue.x) * t,
                    y: startValue.y + (endValue.y - startValue.y) * t,
                    z: startValue.z + (endValue.z - startValue.z) * t)
            }
            particle.color = Vec3(
                x: particle.color.x * factor.x,
                y: particle.color.y * factor.y,
                z: particle.color.z * factor.z)

        case .turbulence(let mask, let scale, let speedMin, let speedMax,
                         let timeScale, let phaseMin, let phaseMax):
            let speed = (speedMin + Self.hash(particle.frameSeed, 31) * (speedMax - speedMin))
                * instance.speed
            guard speed != 0 else { return }
            let phase = phaseMin + Self.hash(particle.frameSeed, 32) * (phaseMax - phaseMin)
            // 자리와 시간으로 잡음 마당을 읽는다. 같은 자리면 같은 값이 나와야
            // 파티클들이 **함께** 흐른다 — 파티클마다 따로 흔들면 지저분해진다.
            let t = elapsed * timeScale * 0.01 + phase
            let field = Vec3(
                x: Self.noise(particle.position.x * scale, particle.position.y * scale,
                              particle.position.z * scale + t),
                y: Self.noise(particle.position.y * scale + 19.7,
                              particle.position.z * scale, particle.position.x * scale + t),
                z: Self.noise(particle.position.z * scale + 43.3,
                              particle.position.x * scale, particle.position.y * scale + t))
            particle.velocity = Vec3(
                x: particle.velocity.x + field.x * mask.x * speed * dt,
                y: particle.velocity.y + field.y * mask.y * speed * dt,
                z: particle.velocity.z + field.z * mask.z * speed * dt)

        case .vortex(let axis, let distanceInner, let distanceOuter,
                     let speedInner, let speedOuter):
            // 축은 시스템 원점을 지난다. 파티클을 축에 내린 수선이 반지름이다.
            let toParticle = Vec3(
                x: particle.position.x - originOffset.x,
                y: particle.position.y - originOffset.y,
                z: particle.position.z - originOffset.z)
            let axisLength = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
            guard axisLength > 1e-9 else { return }
            let unit = Vec3(x: axis.x / axisLength, y: axis.y / axisLength,
                            z: axis.z / axisLength)
            let along = toParticle.x * unit.x + toParticle.y * unit.y + toParticle.z * unit.z
            let radial = Vec3(x: toParticle.x - unit.x * along,
                              y: toParticle.y - unit.y * along,
                              z: toParticle.z - unit.z * along)
            let radius = (radial.x * radial.x + radial.y * radial.y
                + radial.z * radial.z).squareRoot()
            guard radius > 1e-6 else { return }
            // 안쪽 속력에서 바깥쪽 속력으로 섞는다. 두 거리가 같으면 바깥값이다.
            let span = distanceOuter - distanceInner
            let ratio = span > 1e-9
                ? min(max((radius - distanceInner) / span, 0), 1) : 1.0
            let speed = (speedInner + (speedOuter - speedInner) * ratio) * instance.speed
            // 접선 = 축 × 반지름 방향.
            let tangent = Vec3(
                x: unit.y * radial.z - unit.z * radial.y,
                y: unit.z * radial.x - unit.x * radial.z,
                z: unit.x * radial.y - unit.y * radial.x)
            let tangentLength = (tangent.x * tangent.x + tangent.y * tangent.y
                + tangent.z * tangent.z).squareRoot()
            guard tangentLength > 1e-9 else { return }
            particle.velocity = Vec3(
                x: particle.velocity.x + tangent.x / tangentLength * speed * dt,
                y: particle.velocity.y + tangent.y / tangentLength * speed * dt,
                z: particle.velocity.z + tangent.z / tangentLength * speed * dt)

        case .remapValue(let output, let transform, let inputScale,
                         let outputMin, let outputMax):
            // 0~1 하나를 만들어 범위에 옮긴다. 파티클마다 다른 씨앗을 쓰고
            // 시간에 따라 천천히 흐르게 한다 — 유리창의 물방울이 저마다 다른
            // 속도로 흘러내리는 모양이 이것이다.
            //
            // **입력을 고르는 부분은 아직 없다.** 실물이 쓰는 둘 다 입력 없이
            // 잡음만 쓴다. 그리고 `simplexnoise`와 `fbmnoise`는 결이 다르지만
            // 우리 잡음 하나로 받는다 — 흐르는 모양은 나오지만 같지는 않다.
            let seed = Self.hash(particle.frameSeed, 41) * 64
            let t: Double
            switch transform {
            case .sine:
                t = 0.5 + 0.5 * sin(elapsed * inputScale + seed)
            case .noise:
                t = 0.5 + 0.5 * Self.noise(seed, elapsed * inputScale * 0.05, 0)
            }
            let value = Vec3(
                x: outputMin.x + (outputMax.x - outputMin.x) * t,
                y: outputMin.y + (outputMax.y - outputMin.y) * t,
                z: outputMin.z + (outputMax.z - outputMin.z) * t)
            switch output {
            case .velocity:
                // 속도를 정하는 연산자도 speed 배율을 받는다(실물 rain_screen).
                particle.velocity = Vec3(x: value.x * instance.speed, y: value.y * instance.speed,
                                         z: value.z * instance.speed)
            case .opacity:
                particle.alpha = min(max(particle.baseAlpha * value.x, 0), 1)
            case .size:
                particle.size = max(0, particle.baseSize * value.x)
            case .color:
                particle.color = value
            case .speed:
                // 방향은 그대로 두고 크기만 바꾼다. 속도가 0이면(가만히 있는
                // 파티클) 바꿀 방향이 없으니 손대지 않는다.
                let vx = particle.velocity.x, vy = particle.velocity.y, vz = particle.velocity.z
                let magnitude = (vx * vx + vy * vy + vz * vz).squareRoot()
                if magnitude > 1e-9 {
                    let scale = value.x * instance.speed / magnitude
                    particle.velocity = Vec3(x: vx * scale, y: vy * scale, z: vz * scale)
                }
            case .unsupported:
                // 여기 오면 생성자가 이미 이름과 함께 보고했다.
                break
            }

        case .controlPointAttract(let controlPoint, let origin, let scale, let threshold):
            // 0번 제어점은 시스템 자신의 자리다. 그 위에 연산자가 적은 `origin`을
            // 얹는다. **다른 번호는 씬이 자리를 따로 정해 주는데 우리 모델에
            // 그 데이터가 없다** — 그때는 여기서 아무것도 하지 않고
            // `unimplementedOperators`로 보고한다.
            guard let point = controlPointPosition(controlPoint) else { return }
            let target = Vec3(x: point.x + origin.x,
                              y: point.y + origin.y,
                              z: point.z + origin.z)
            let delta = Vec3(x: target.x - particle.position.x,
                             y: target.y - particle.position.y,
                             z: target.z - particle.position.z)
            let distance = (delta.x * delta.x + delta.y * delta.y
                + delta.z * delta.z).squareRoot()
            guard distance > 1e-6, distance < threshold else { return }
            // 가까울수록 세게 당긴다. 문턱에서 0이 되게 두어야 파티클이 문턱을
            // 넘나들 때 속도가 튀지 않는다. 음수 scale이면 밀어낸다(커서 피하기).
            let falloff = threshold > 0 ? (1 - distance / threshold) : 1
            let strength = scale * falloff * dt * instance.speed
            particle.velocity = Vec3(
                x: particle.velocity.x + delta.x / distance * strength,
                y: particle.velocity.y + delta.y / distance * strength,
                z: particle.velocity.z + delta.z / distance * strength)
        }
    }

    private func ageParticles(dt: Double) {
        for i in 0..<particleBuffer.count {
            if particleBuffer[i].isAlive {
                particleBuffer[i].age += dt
            }
        }
    }

    /// 제어점의 자리. 못 풀면 nil이다.
    ///
    /// 0번은 시스템 자신의 자리다. 프리셋이 정의한 제어점은 그 자리에 자기
    /// `offset`을 얹고, `flags`에 마우스 비트가 있으면 커서를 따라간다 —
    /// 반딧불이 손끝을 피해 흩어지는 것이 이것이다. 커서를 아직 못 받은
    /// 프레임에는 시스템 자리에 둔다(가만히 있는 편이 튀는 것보다 낫다).
    func controlPointPosition(_ id: Int) -> Vec3? {
        guard let point = preset.controlPoints.first(where: { $0.id == id }) else {
            // 프리셋에 없는 번호라도 0번은 시스템 자신의 자리로 본다.
            return id == 0 ? originOffset : nil
        }
        if point.hasUnknownBinding { return nil }
        let base = point.followsCursor ? (cursorPosition ?? originOffset) : originOffset
        return Vec3(x: base.x + point.offset.x,
                    y: base.y + point.offset.y,
                    z: base.z + point.offset.z)
    }

    /// 그 번호를 못 푸는지. 생성자에서 보고할지 정하는 데 쓴다.
    static func unresolvableControlPoint(_ id: Int, in preset: ParticlePreset) -> Bool {
        guard let point = preset.controlPoints.first(where: { $0.id == id }) else {
            return id != 0
        }
        return point.hasUnknownBinding
    }

    /// 파티클마다 고정된 0~1 난수. `salt`로 용도를 나눈다.
    ///
    /// 프레임마다 `random.next()`를 부르면 같은 파티클이 매 프레임 다른 값을
    /// 받아, 주기 운동이 무작위 깜빡임이 된다. 씨앗에서 뽑으면 태어날 때
    /// 정해진 값이 죽을 때까지 간다.
    static func hash(_ seed: Double, _ salt: Int) -> Double {
        let x = sin(seed * 127.1 + Double(salt) * 311.7) * 43758.5453
        return x - x.rounded(.down)
    }

    /// 매끄러운 3차원 값 잡음. -1~1이다.
    ///
    /// **WE의 잡음 함수는 공개돼 있지 않다.** 이건 우리 것이고, 같은 자리에서
    /// 같은 값이 나오고 자리를 조금 옮기면 값도 조금 바뀐다는 성질만 같다.
    /// 불티가 흩날리는 모양은 나오지만 실물과 픽셀 단위로 같지는 않다.
    static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        func fade(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func corner(_ i: Double, _ j: Double, _ k: Double) -> Double {
            let h = sin(i * 12.9898 + j * 78.233 + k * 37.719) * 43758.5453
            return (h - h.rounded(.down)) * 2 - 1
        }
        let xi = x.rounded(.down), yi = y.rounded(.down), zi = z.rounded(.down)
        let xf = fade(x - xi), yf = fade(y - yi), zf = fade(z - zi)
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let c000 = corner(xi, yi, zi), c100 = corner(xi + 1, yi, zi)
        let c010 = corner(xi, yi + 1, zi), c110 = corner(xi + 1, yi + 1, zi)
        let c001 = corner(xi, yi, zi + 1), c101 = corner(xi + 1, yi, zi + 1)
        let c011 = corner(xi, yi + 1, zi + 1), c111 = corner(xi + 1, yi + 1, zi + 1)
        return lerp(
            lerp(lerp(c000, c100, xf), lerp(c010, c110, xf), yf),
            lerp(lerp(c001, c101, xf), lerp(c011, c111, xf), yf),
            zf)
    }

    private func isValidParticle(_ particle: Particle) -> Bool {
        // Check if position, velocity, size, and lifetime are finite
        return particle.position.x.isFinite && particle.position.y.isFinite && particle.position.z.isFinite &&
               particle.velocity.x.isFinite && particle.velocity.y.isFinite && particle.velocity.z.isFinite &&
               particle.size.isFinite && particle.size >= 0 &&
               particle.lifetime.isFinite && particle.lifetime > 0 &&
               particle.alpha.isFinite && particle.alpha >= 0
    }
}
