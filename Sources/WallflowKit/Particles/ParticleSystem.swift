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
    /// 이미터별 방출 크레딧. 못 내보낸 몫이 쌓이지 않는지는 aliveCount로 관찰할 수 없어서
    /// (슬롯 수가 구조적 상한이라 항상 통과한다) 테스트가 이 값을 직접 본다.
    var emissionCredits: [Double] = []

    /// 프리셋에 있지만 이 시뮬레이션이 아직 처리하지 않는 연산자 이름들.
    /// 조용히 무시하면 사용자가 레이어가 안 움직이는 이유를 알 수 없고,
    /// 나중에 렌더러 버그로 오인된다.
    public private(set) var unimplementedOperators: [String] = []

    public init(preset: ParticlePreset, random: RandomSource) {
        self.preset = preset
        self.random = random

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

        // Emit new particles
        emitParticles(dt: dt)

        // Apply operators to alive particles
        applyOperators(dt: dt)

        // Age particles
        ageParticles(dt: dt)
    }

    private func removeDeadParticles() {
        for i in 0..<particleBuffer.count {
            if !particleBuffer[i].isAlive && particleBuffer[i].age < Double.infinity {
                deadSlots.append(i)
                particleBuffer[i].age = Double.infinity
                numAlive -= 1
            }
        }
    }

    private func emitParticles(dt: Double) {
        for (emitterIndex, emitter) in preset.emitters.enumerated() {
            // Accumulate emission credit
            let rate: Double
            switch emitter {
            case .sphereRandom(let r, _, _, _, _):
                rate = r
            case .boxRandom(let r, _, _, _, _):
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
            lifetime: 1
        )

        // Apply emitter position and velocity
        switch emitter {
        case .sphereRandom(_, let origin, let directions, let distanceMin, let distanceMax):
            particle.position = origin
            // Random direction within cone
            let theta = random.next() * 2 * .pi
            let phi = acos(2 * random.next() - 1)
            let distance = distanceMin + random.next() * (distanceMax - distanceMin)
            let offset = Vec3(
                x: distance * sin(phi) * cos(theta) * directions.x,
                y: distance * sin(phi) * sin(theta) * directions.y,
                z: distance * cos(phi) * directions.z
            )
            particle.position = Vec3(
                x: origin.x + offset.x,
                y: origin.y + offset.y,
                z: origin.z + offset.z
            )

        case .boxRandom(_, let origin, let directions, let min, let max):
            let offset = Vec3(
                x: (min.x + random.next() * (max.x - min.x)) * directions.x,
                y: (min.y + random.next() * (max.y - min.y)) * directions.y,
                z: (min.z + random.next() * (max.z - min.z)) * directions.z
            )
            particle.position = Vec3(
                x: origin.x + offset.x,
                y: origin.y + offset.y,
                z: origin.z + offset.z
            )
        }

        // Apply initializers
        for initializer in preset.initializers {
            applyInitializer(initializer, to: &particle)
        }

        return particle
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

        case .turbulentVelocityRandom(let min, let max):
            let turbulence = Vec3(
                x: min.x + random.next() * (max.x - min.x),
                y: min.y + random.next() * (max.y - min.y),
                z: min.z + random.next() * (max.z - min.z)
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

        case .angularMovement(let gravity, let drag):
            // Similar to movement but for angular velocity
            particle.angularVelocity = Vec3(
                x: particle.angularVelocity.x + gravity.x * dt,
                y: particle.angularVelocity.y + gravity.y * dt,
                z: particle.angularVelocity.z + gravity.z * dt
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
            // Fade is computed fresh each frame based on age, not accumulated
            var alpha = 1.0

            if fadeInTime > 0 && particle.age < fadeInTime {
                // Fade in from 0 to 1
                alpha = particle.age / fadeInTime
            } else if fadeOutTime > 0 {
                let fadeOutStart = particle.lifetime - fadeOutTime
                if particle.age >= fadeOutStart {
                    // Fade out from 1 to 0
                    let timeInFadeOut = particle.age - fadeOutStart
                    alpha = 1.0 - (timeInFadeOut / fadeOutTime)
                }
            }

            particle.alpha = max(0, min(1, alpha))

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

        case .oscillateAlpha(let frequencyMin, let frequencyMax, let phaseMin, let phaseMax):
            let frequency = frequencyMin + random.next() * (frequencyMax - frequencyMin)
            let phase = phaseMin + random.next() * (phaseMax - phaseMin)

            particle.alpha = abs(sin(frequency * particle.age * 2 * .pi + phase))

        case .controlPointAttract(let controlPoint, let scale, let radius):
            // 제어점 데이터가 모델에 없어 구현하지 못했고 unimplementedOperators로 보고한다.
            // 조용히 무시하면 사용자가 레이어가 안 움직이는 이유를 알 수 없다.
            _ = controlPoint
            _ = scale
            _ = radius
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
