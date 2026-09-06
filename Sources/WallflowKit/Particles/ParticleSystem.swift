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
    private let hasSizeChange: Bool
    private let hasAlphaFade: Bool

    public init(preset: ParticlePreset, random: RandomSource) {
        self.preset = preset
        self.random = random
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

        // Detect unimplemented operators
        var unimplemented = Set<String>()
        for op in preset.operators {
            if case .controlPointAttract = op {
                unimplemented.insert("controlpointattract")
            }
        }
        self.unimplementedOperators = Array(unimplemented).sorted()
        self.hasSizeChange = preset.operators.contains {
            if case .sizeChange = $0 { return true } else { return false }
        }
        self.hasAlphaFade = preset.operators.contains {
            if case .alphaFade = $0 { return true } else { return false }
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
    public func update(deltaTime: Double) {
        // Check for invalid deltaTime
        guard deltaTime.isFinite, deltaTime > 0 else { return }

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
        for initializer in preset.initializers {
            applyInitializer(initializer, to: &particle)
        }

        // 초기화자가 끝난 값이 기준값이다.
        particle.baseSize = particle.size
        particle.baseAlpha = particle.alpha

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

    private func applyInitializer(_ initializer: ParticleInitializer, to particle: inout Particle) {
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
        }
    }

    private func applyOperators(dt: Double) {
        for i in 0..<particleBuffer.count {
            guard particleBuffer[i].isAlive else { continue }

            // 수명에 따라 곱하는 연산자들은 기준값에서 다시 시작한다.
            // 여러 개가 겹쳐 곱해지되(섬광은 커지는 것과 작아지는 것 둘이다),
            // 프레임을 넘어 쌓이지는 않는다.
            if hasSizeChange { particleBuffer[i].size = particleBuffer[i].baseSize }
            if hasAlphaFade { particleBuffer[i].alpha = particleBuffer[i].baseAlpha }

            for op in preset.operators {
                applyOperator(op, to: &particleBuffer[i], dt: dt)
            }
        }
    }

    private func applyOperator(_ op: ParticleOperator, to particle: inout Particle, dt: Double) {
        switch op {
        case .movement(let gravity, let drag):
            // Apply gravity
            particle.velocity = Vec3(
                x: particle.velocity.x + gravity.x * dt,
                y: particle.velocity.y + gravity.y * dt,
                z: particle.velocity.z + gravity.z * dt
            )

            // Apply drag (velocity damping)
            if drag > 0 {
                let dampFactor = pow(1 - drag, dt)
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
            let frequency = frequencyMin + random.next() * (frequencyMax - frequencyMin)
            let scale = scaleMin + random.next() * (scaleMax - scaleMin)

            particle.alpha = scale * abs(sin(frequency * particle.age * 2 * .pi))

        case .controlPointAttract(let controlPoint, let origin, let scale, let threshold):
            // 제어점 데이터가 모델에 없어 구현하지 못했고 unimplementedOperators로 보고한다.
            // 조용히 무시하면 사용자가 레이어가 안 움직이는 이유를 알 수 없다.
            _ = controlPoint
            _ = origin
            _ = scale
            _ = threshold
        }
    }

    private func ageParticles(dt: Double) {
        for i in 0..<particleBuffer.count {
            if particleBuffer[i].isAlive {
                particleBuffer[i].age += dt
            }
        }
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
