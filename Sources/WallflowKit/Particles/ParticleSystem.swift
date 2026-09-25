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
    /// 태어난 차례. 슬롯은 재사용돼 버퍼 순서가 스폰 순서가 아니다 — 로프가
    /// `age` 동률(같은 프레임에 여럿 태어남)을 가를 때만 쓴다.
    public var spawnSequence: Int = 0
    /// `mapSequenceBetweenControlPoints`가 태어날 때 고른 두 제어점 사이의
    /// 자리(0~1)와 그 제어점 번호. `nil`이면 그 초기화자를 안 썼다는 뜻이라
    /// `maintainDistanceBetweenControlPoints`가 아무것도 안 한다.
    public var sequenceFraction: Double?
    public var sequenceControlPointStart: Int = 0
    public var sequenceControlPointEnd: Int = 1
    /// `maintainDistanceToControlPoint`가 처음 만난 프레임(태어난 순간)에 잰
    /// 제어점까지의 거리. 목표 거리를 적는 필드가 없어 이것을 기준으로 삼는다
    /// (타입 선언부 주석 참고).
    public var maintainedDistanceToControlPoint: Double?

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
    /// 프리웜 상한(초). 파일에서 온 값이라 한 번에 치를 만큼으로 죈다.
    public static let maxPrewarm = 30.0
    private var didPrewarm = false

    /// 이 시스템이 놓인 자리. 자식 시스템이 부모 파티클을 따라다닐 때 여기가 바뀐다.
    /// 방출할 때 파티클 위치에 더해진다.
    public var originOffset = Vec3(x: 0, y: 0, z: 0)

    /// 이 시스템을 담은 레이어의 씬 좌표 원점·배율. `cursorPosition`처럼 렌더러가
    /// 만들 때 한 번 넣어 준다 — 월드(화면) 좌표 제어점(플래그 2)을 이 시스템의
    /// 로컬 좌표로 바꿀 때만 쓴다(파티클 좌표계 자체가 레이어 기준 상대 좌표라서다).
    public var layerOrigin = Vec3(x: 0, y: 0, z: 0)
    public var layerScale = Vec3(x: 1, y: 1, z: 1)

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
    /// 다음에 태어날 파티클에 매길 순번. 버퍼 슬롯은 재사용되므로 태어난
    /// 차례를 아는 유일한 길이다 — 로프가 `age` 동률을 가를 때 쓴다.
    private var nextSpawnSequence: Int = 0
    /// 제어점의 지난 프레임 자리(`inheritControlPointVelocity`가 프레임 간
    /// 이동으로 속도를 내려고 쓴다). 못 푼 프레임은 안 남긴다 — 다음 프레임에
    /// 다시 시도한다.
    private var previousControlPointPositions: [Int: Vec3] = [:]
    /// `(현재 자리 − 지난 자리) / dt`. 매 프레임 `step` 시작에서 갱신한다.
    private var controlPointVelocities: [Int: Vec3] = [:]
    /// 부모 사건(자식을 낳은 파티클)의 스냅샷. `inheritInitialValueFromEvent`·
    /// `inheritValueFromEvent`가 색·크기·알파·속도를 그대로 받을 때 쓴다.
    /// `follow` 자식은 `updateChildren`이 매 프레임 다시 채운다 — 부모가
    /// 계속 움직이며 값이 바뀔 수 있어서다.
    var parentSnapshot: Particle?

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
            // 우리가 안 넣는 출력·입력은 이름과 함께 남긴다.
            if case .remapValue(let output, _, _, _, _, let input) = op {
                if case .unsupported(let name) = output {
                    unimplemented.insert("remapvalue(\(name))")
                }
                if case .unsupported(let name) = input {
                    unimplemented.insert("remapvalue(입력 \(name))")
                }
                if case .distanceToControlPoint(let point, _, _) = input,
                   Self.unresolvableControlPoint(point, in: preset) {
                    unimplemented.insert("remapvalue(제어점 \(point))")
                }
            }
            if case .maintainDistanceToControlPoint(let point, _) = op,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("maintaindistancetocontrolpoint(제어점 \(point))")
            }
            if case .reduceMovementNearControlPoint(let point, _, _, _, _) = op,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("reducemovementnearcontrolpoint(제어점 \(point))")
            }
        }
        for initializer in preset.initializers {
            if case .mapSequenceAroundControlPoint(let point, _, _, _, _, _, _) = initializer,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("mapsequencearoundcontrolpoint(제어점 \(point))")
            }
            if case .mapSequenceBetweenControlPoints(let start, let end, _, let hasArc) = initializer {
                if Self.unresolvableControlPoint(start, in: preset) {
                    unimplemented.insert("mapsequencebetweencontrolpoints(제어점 \(start))")
                }
                if Self.unresolvableControlPoint(end, in: preset) {
                    unimplemented.insert("mapsequencebetweencontrolpoints(제어점 \(end))")
                }
                // arcamount는 실물 값만으로 정확한 공식을 확정할 수 없어
                // 반영하지 않는다(타입 선언부 주석 참고) — 적혀 있으면 남긴다.
                if hasArc {
                    unimplemented.insert("mapsequencebetweencontrolpoints(arc)")
                }
            }
            if case .remapInitialValue(let output, let input, _, _) = initializer {
                if case .unsupported(let name) = output {
                    unimplemented.insert("remapinitialvalue(\(name))")
                }
                if case .unsupported(let name) = input {
                    unimplemented.insert("remapinitialvalue(입력 \(name))")
                }
                if case .distanceToControlPoint(let point, _, _) = input,
                   Self.unresolvableControlPoint(point, in: preset) {
                    unimplemented.insert("remapinitialvalue(제어점 \(point))")
                }
            }
            if case .remapInitialValueMultiplyUnsupported = initializer {
                // output 필드가 없어 무엇을 곱하는지 실물만으로 알 수 없다
                // (타입 선언부 주석 참고).
                unimplemented.insert("remapinitialvalue(multiply)")
            }
            if case .inheritControlPointVelocity(let point, _, _) = initializer,
               Self.unresolvableControlPoint(point, in: preset) {
                unimplemented.insert("inheritcontrolpointvelocity(제어점 \(point))")
            }
        }
        for emitter in preset.emitters {
            // 이미터가 못 푸는 제어점을 쓰면 뿌리는 자리는 원점으로 물러난다
            // (emitParticle 참고) — 그 사실은 여기서 한 번만 남긴다.
            guard let point = emitter.controlPoint, Self.unresolvableControlPoint(point, in: preset)
            else { continue }
            switch emitter {
            case .sphereRandom: unimplemented.insert("sphererandom(제어점 \(point))")
            case .boxRandom: unimplemented.insert("boxrandom(제어점 \(point))")
            }
        }
        self.unimplementedOperators = Array(unimplemented).sorted()
        self.hasSizeCurve = preset.operators.contains {
            switch $0 {
            case .sizeChange, .oscillateSize: return true
            case .remapValue(let output, _, _, _, _, _): return output == .size
            default: return false
            }
        }
        self.hasAlphaCurve = preset.operators.contains {
            switch $0 {
            case .alphaFade, .alphaChange, .oscillateAlpha: return true
            case .remapValue(let output, _, _, _, _, _): return output == .opacity
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

    /// 로프가 이을 순서로 정렬한 살아 있는 파티클. `age` 내림차순, 같으면
    /// 생성 순번(`spawnSequence`) 오름차순 — 슬롯이 재사용돼 버퍼 순서가
    /// 스폰 순서가 아니고, 같은 프레임에 여럿 태어나면 나이가 완전히 같다
    /// (`ageParticles`가 모두에게 같은 dt를 더한다).
    public var ropeOrderedParticles: [Particle] {
        particles.sorted { a, b in
            if a.age != b.age { return a.age > b.age }
            return a.spawnSequence < b.spawnSequence
        }
    }

    /// `renderableGroups`의 로프 판. 같은 정의에서 나온 자식 벌들을 **합치지
    /// 않고** 벌마다 따로 순서 있는 배열로 돌려준다 — 로프는 다른 인스턴스의
    /// 파티클과 이어지면 안 된다(오브 하나의 꼬리가 다른 오브 자리로 튄다).
    public func ropeGroups(
        prefix: String = "", depth: Int = 0
    ) -> [(key: String, preset: ParticlePreset, instances: [[Particle]])] {
        var out: [(key: String, preset: ParticlePreset, instances: [[Particle]])] = [
            (prefix.isEmpty ? "0" : prefix, preset, [ropeOrderedParticles])
        ]
        guard depth < 2 else { return out }
        for (index, list) in childInstances.enumerated() {
            guard !list.isEmpty else { continue }
            let key = (prefix.isEmpty ? "0" : prefix) + ".\(index)"
            var instances: [[Particle]] = []
            var nested: [String: (ParticlePreset, [[Particle]])] = [:]
            for instance in list {
                for group in instance.system.ropeGroups(prefix: key, depth: depth + 1) {
                    if group.key == key {
                        instances.append(contentsOf: group.instances)
                    } else {
                        nested[group.key, default: (group.preset, [])].1
                            .append(contentsOf: group.instances)
                    }
                }
            }
            out.append((key, children[index].preset, instances))
            for (key, value) in nested.sorted(by: { $0.key < $1.key }) {
                out.append((key, value.0, value.1))
            }
        }
        return out
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
    /// 렌더러가 마지막으로 본 스크립트 `stop()` 횟수.
    public var restartsSeen = 0

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
        // `didPrewarm`은 안 지운다. 프리웜은 콜드 스타트에서 밀린 시간을 따라잡는
        // 몫이라 스크립트가 거는 `stop(); play()` 재시작에는 안 낀다 — 재시작은
        // 한꺼번에 뿌리는 몫만 다시 하고 `starttime`은 다시 돌지 않는다.
        emissionCredits = Array(repeating: 0.0, count: preset.emitters.count)
    }

    public func update(deltaTime: Double) {
        // Check for invalid deltaTime
        guard deltaTime.isFinite, deltaTime > 0, isPlaying else { return }

        // `starttime`(프리웜): 처음 보일 때 이미 이만큼 돈 상태여야 한다. 시뮬레이션
        // 시간이라 rate 배율과 상관없이 그대로 돈다.
        if !didPrewarm {
            didPrewarm = true
            var remaining = Swift.min(Swift.max(preset.startTime, 0), Self.maxPrewarm)
            while remaining > 1e-9 {
                let dt = Swift.min(remaining, Self.maxTimeStep)
                step(dt)
                remaining -= dt
            }
        }

        // rate는 "simulation rate"(공식 문서) — 이 시스템의 시계를 늦추거나 당긴다.
        // 곱한 뒤 다시 죈다. 큰 배율이 한 걸음에 길게 걷게 두면 적분이 튄다.
        let dt = Swift.min(deltaTime * instance.rate, Self.maxTimeStep)
        guard dt > 0 else { return }
        step(dt)
    }

    /// 시뮬레이션 한 걸음. `dt`는 이미 시뮬레이션 시간이다.
    private func step(_ dt: Double) {
        // 이번 프레임 파티클이 새로 날 **전에** 갱신해야 그 파티클이
        // `inheritControlPointVelocity`로 이번 프레임 속도를 받는다.
        updateControlPointVelocities(dt: dt)

        // Remove dead particles from alive tracking
        removeDeadParticles()

        // 시작할 때 한꺼번에 뿌리는 몫. 첫 걸음에서 한 번만 한다.
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
            // 월드 좌표(플래그 2) 제어점을 자식도 풀 수 있어야 한다 — 안 물려주면
            // 기본값(원점 0, 배율 1)이라 변환이 헛돈다(worldToLocal 참고).
            system.layerOrigin = layerOrigin
            system.layerScale = layerScale
            // `inheritInitialValueFromEvent`/`inheritValueFromEvent`가 쓸
            // 부모 스냅샷. `once`는 부모 파티클 하나에 안 묶여 slot이 nil이다.
            if let slot, particleBuffer.indices.contains(slot) {
                system.parentSnapshot = particleBuffer[slot]
            }
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
                        // 부모가 계속 움직이며 값이 바뀔 수 있어 매 프레임 새로
                        // 채운다 — `inheritValueFromEvent`가 이걸 읽는다.
                        instance.system.parentSnapshot = particleBuffer[slot]
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
            // count는 한꺼번에 뿌리는 몫에도 먹는다. 있던 것을 0으로 만들지는 않는다
            // (실물 PS2 오브는 일괄 1개다). 슬롯 수보다 크게 잡을 이유는 없다.
            let authored = emitter.burst.count
            guard authored > 0 else { continue }
            let count = Swift.max(1, Int(Swift.min((Double(authored) * instance.count).rounded(),
                                                   Double(particleBuffer.count))))
            for _ in 0..<count {
                guard let slot = deadSlots.popLast() else { break }
                var particle = emitParticle(from: emitter)
                guard isValidParticle(particle) else {
                    deadSlots.append(slot)
                    continue
                }
                particle.age = 0
                particle.spawnSequence = nextSpawnSequence
                nextSpawnSequence += 1
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
            case .sphereRandom(let r, _, _, _, _, _, _, _):
                rate = r
            case .boxRandom(let r, _, _, _, _, _, _, _):
                rate = r
            }

            // count는 "emission rate"(공식 문서). 개수 상한은 불러올 때 이미 곱했다.
            emissionCredits[emitterIndex] += rate * instance.count * dt

            // Clamp credit to prevent infinite loops
            guard emissionCredits[emitterIndex].isFinite else {
                emissionCredits[emitterIndex] = 0
                continue
            }

            // Emit integer number of particles
            // Int(Double)은 범위 밖에서 트랩한다. 파일에서 온 rate가 거대할 수 있으므로
            // Double 단계에서 먼저 슬롯 수 이하로 죈다. 그 뒤엔 변환이 안전하다.
            let available = Double(deadSlots.count)
            var toEmit = Swift.min(emissionCredits[emitterIndex].rounded(.down), available)
            // 로프 트레일 이미터(실물 `orbTrail`)는 `rate: 60`이라도 한 프레임에
            // 마디 하나씩만 자라야 한다 — 안 그러면 트레일이 프레임마다 여러 개를
            // 한꺼번에 토해내 같은 자리에 뭉친다.
            if emitter.onePerFrame { toEmit = Swift.min(toEmit, 1) }
            let emitCount = toEmit > 0 ? Int(toEmit) : 0

            for _ in 0..<emitCount {
                if let slotIndex = deadSlots.popLast() {
                    var particle = emitParticle(from: emitter)
                    if isValidParticle(particle) {
                        particle.age = 0
                        particle.spawnSequence = nextSpawnSequence
                        nextSpawnSequence += 1
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

        // 제어점 이미터는 그 제어점 자리에서 뿌린다(실물 `dripping_water`의 두
        // 낙수 자리). 없으면(대부분) 지금처럼 이 시스템의 원점이다. 번호를 못
        // 풀면 원점으로 물러난다 — 생성자가 이미 이름과 번호로 한 번 보고했다.
        let base = emitter.controlPoint.flatMap { controlPointPosition($0) } ?? originOffset

        // Apply emitter position and velocity
        switch emitter {
        case .sphereRandom(_, let origin, let directions, let distanceMin, let distanceMax, _, _, _):
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
                x: base.x + origin.x + unit.x * distance,
                y: base.y + origin.y + unit.y * distance,
                z: base.z + origin.z + unit.z * distance
            )
            applyEmitterSpeed(emitter.burst, direction: unit, to: &particle)

        case .boxRandom(_, let origin, let directions, let distanceMin, let distanceMax, _, _, _):
            let offset = Vec3(
                x: (distanceMin.x + random.next() * (distanceMax.x - distanceMin.x)) * directions.x,
                y: (distanceMin.y + random.next() * (distanceMax.y - distanceMin.y)) * directions.y,
                z: (distanceMin.z + random.next() * (distanceMax.z - distanceMin.z)) * directions.z
            )
            particle.position = Vec3(
                x: base.x + origin.x + offset.x,
                y: base.y + origin.y + offset.y,
                z: base.z + origin.z + offset.z
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

        case .mapSequenceBetweenControlPoints(let cpStart, let cpEnd, let rawCount, _):
            let start = controlPointPosition(cpStart) ?? originOffset
            let end = controlPointPosition(cpEnd) ?? originOffset
            // count를 안 적으면(실물 대부분) 선 전체에 maxCount개를 고르게 깐다
            // — 타입 선언부 주석 참고.
            let count = rawCount > 0 ? rawCount : Double(preset.maxCount)
            let slot = Self.nextSequenceSlot(&sequenceCounters[index, default: 0], count: count,
                                             mirror: false)
            let fraction = count > 0 ? slot / count : 0
            // 통째로 갈아 끼우면 안 된다 — 실물 dna.json은 이 초기화자 **앞에**
            // mapSequenceAroundControlPoint가 원 위의 자리를 이미 잡아 둔다.
            // 그 결과를 지우면 나선(DNA)이 직선이 된다. 대신 지금 자리에서
            // 시스템 원점만큼의 "오프셋"(원 위의 자리 등)을 지키고, 그 오프셋의
            // 기준점만 선 위의 자리로 옮긴다.
            let offset = Vec3(x: particle.position.x - originOffset.x,
                              y: particle.position.y - originOffset.y,
                              z: particle.position.z - originOffset.z)
            let target = Vec3(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction,
                z: start.z + (end.z - start.z) * fraction)
            particle.position = Vec3(
                x: target.x + offset.x, y: target.y + offset.y, z: target.z + offset.z)
            // maintainDistanceBetweenControlPoints가 매 프레임 이 자리를 다시
            // 지킬 수 있게 저장해 둔다.
            particle.sequenceFraction = fraction
            particle.sequenceControlPointStart = cpStart
            particle.sequenceControlPointEnd = cpEnd

        case .colorList(let colors):
            // 실물 값이 이미 0~1이다 — colorrandom과 달리 255로 안 나눈다.
            let pick = colors[Int(random.next() * Double(colors.count)) % colors.count]
            particle.color = pick

        case .hsvColorRandom(let hueMin, let hueMax, let hueSteps, let saturationMin,
                             let saturationMax, let valueMin, let valueMax):
            var hue = hueMin + random.next() * (hueMax - hueMin)
            if hueSteps > 0 {
                hue = (hue * Double(hueSteps)).rounded(.down) / Double(hueSteps)
            }
            let saturation = saturationMin + random.next() * (saturationMax - saturationMin)
            let value = valueMin + random.next() * (valueMax - valueMin)
            particle.color = Self.hsvToRGB(hue: hue, saturation: saturation, value: value)

        case .positionOffsetRandom(let distance, let scale, let timeScale):
            // scale이 0이면(실물 thunderbolt.json) 공간 항이 사라져 잡음이
            // 자리와 무관하게 시간에만 따라 흔들린다 — 타입 선언부 주석 참고.
            // turbulence 연산자와 같은 시간 배율(0.01)을 쓴다.
            let t = elapsed * timeScale * 0.01
            let field = Vec3(
                x: Self.noise(particle.position.x * scale, particle.position.y * scale,
                              particle.position.z * scale + t),
                y: Self.noise(particle.position.y * scale + 19.7,
                              particle.position.z * scale, particle.position.x * scale + t),
                z: Self.noise(particle.position.z * scale + 43.3,
                              particle.position.x * scale, particle.position.y * scale + t))
            particle.position = Vec3(
                x: particle.position.x + field.x * distance,
                y: particle.position.y + field.y * distance,
                z: particle.position.z + field.z * distance)

        case .remapInitialValue(let output, let input, let outputMin, let outputMax):
            // remapValue와 같은 식이지만 태어날 때 한 번만 돈다 — transform이
            // 없다(실물이 한 번도 안 쓴다, 타입 선언부 주석 참고).
            let t: Double
            switch input {
            case .none, .particleSystemTime:
                // 실물 remapinitialvalue는 이 둘을 안 쓴다 — 값을 못 정하니
                // 손대지 않는다.
                return
            case .distanceToControlPoint(let controlPoint, let rangeMin, let rangeMax):
                guard let center = controlPointPosition(controlPoint) else { return }
                let delta = Vec3(x: particle.position.x - center.x,
                                 y: particle.position.y - center.y,
                                 z: particle.position.z - center.z)
                let distance = Self.length(delta)
                let span = rangeMax - rangeMin
                t = span > 1e-9 ? min(max((distance - rangeMin) / span, 0), 1) : 0
            case .unsupported:
                return
            }
            let value = Vec3(
                x: outputMin.x + (outputMax.x - outputMin.x) * t,
                y: outputMin.y + (outputMax.y - outputMin.y) * t,
                z: outputMin.z + (outputMax.z - outputMin.z) * t)
            switch output {
            case .velocity: particle.velocity = value
            case .opacity: particle.alpha = min(max(value.x, 0), 1)
            case .size: particle.size = max(0, value.x)
            case .color: particle.color = value
            case .speed:
                let vx = particle.velocity.x, vy = particle.velocity.y, vz = particle.velocity.z
                let magnitude = (vx * vx + vy * vy + vz * vz).squareRoot()
                if magnitude > 1e-9 {
                    let scale = value.x / magnitude
                    particle.velocity = Vec3(x: vx * scale, y: vy * scale, z: vz * scale)
                }
            case .unsupported:
                break
            }

        case .remapInitialValueMultiplyUnsupported:
            // 생성자가 이미 이름과 함께 보고했다.
            break

        case .inheritControlPointVelocity(let controlPoint, let scaleMin, let scaleMax):
            // 못 풀거나(제어점 없음) 아직 속도가 없으면(첫 프레임) 손대지 않는다.
            guard let velocity = controlPointVelocities[controlPoint] else { return }
            let scale = scaleMin + random.next() * (scaleMax - scaleMin)
            particle.velocity = Vec3(
                x: velocity.x * scale, y: velocity.y * scale, z: velocity.z * scale)

        case .inheritInitialValueFromEvent:
            // 부모가 없으면(예: `once` 자식) 아무것도 안 한다.
            guard let parent = parentSnapshot else { return }
            particle.color = parent.color
            particle.size = parent.size
            particle.alpha = parent.alpha
            particle.velocity = parent.velocity
        }
    }

    /// HSV(0~1 셋 다)를 RGB(0~1)로 바꾼다. 표준 공식 그대로다.
    static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> Vec3 {
        guard saturation > 0 else { return Vec3(x: value, y: value, z: value) }
        let h = (hue - hue.rounded(.down)) * 6
        let i = Int(h.rounded(.down))
        let f = h - h.rounded(.down)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return Vec3(x: value, y: t, z: p)
        case 1: return Vec3(x: q, y: value, z: p)
        case 2: return Vec3(x: p, y: value, z: t)
        case 3: return Vec3(x: p, y: q, z: value)
        case 4: return Vec3(x: t, y: p, z: value)
        default: return Vec3(x: value, y: p, z: q)
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
        // boids는 다른 파티클의 자리·속도를 읽어야 해서 파티클 하나만 보고
        // 도는 나머지 연산자와 다르다. 이번 프레임 시작 스냅샷으로 미리
        // 힘을 다 계산해 두고, 아래 루프에서는 더하기만 한다 — 안 그러면
        // 먼저 갱신된 파티클이 뒤 파티클 계산에 섞여 순서에 따라 결과가
        // 달라진다. 실물에 boids가 둘 이상인 프리셋은 없어 첫 번째만 쓴다.
        var boidForce: [Vec3]?
        for op in preset.operators {
            if case .boids(let cohesionFactor, let separationFactor, let alignmentFactor,
                          let neighborThreshold) = op {
                boidForce = computeBoidForces(
                    cohesionFactor: cohesionFactor, separationFactor: separationFactor,
                    alignmentFactor: alignmentFactor, neighborThreshold: neighborThreshold)
                break
            }
        }

        for i in 0..<particleBuffer.count {
            guard particleBuffer[i].isAlive else { continue }

            // 수명에 따라 곱하는 연산자들은 기준값에서 다시 시작한다.
            // 여러 개가 겹쳐 곱해지되(섬광은 커지는 것과 작아지는 것 둘이다),
            // 프레임을 넘어 쌓이지는 않는다.
            if hasSizeCurve { particleBuffer[i].size = particleBuffer[i].baseSize }
            if hasAlphaCurve { particleBuffer[i].alpha = particleBuffer[i].baseAlpha }
            if hasColorCurve { particleBuffer[i].color = particleBuffer[i].baseColor }

            if let boidForce {
                particleBuffer[i].velocity = Self.add(
                    particleBuffer[i].velocity, Self.scale(boidForce[i], dt))
            }
            for op in preset.operators {
                applyOperator(op, to: &particleBuffer[i], dt: dt)
            }
        }
    }

    /// 이웃(半threshold 안) 파티클과의 응집·분리·정렬 힘. O(n²) — ponytail: 실물
    /// `maxcount`가 수백 단위라 문제없지만, 수천 단위 프리셋이 나오면 공간
    /// 격자로 이웃만 추려야 한다.
    private func computeBoidForces(
        cohesionFactor: Double, separationFactor: Double, alignmentFactor: Double,
        neighborThreshold: Double
    ) -> [Vec3] {
        var forces = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: particleBuffer.count)
        guard neighborThreshold > 0 else { return forces }
        let thresholdSq = neighborThreshold * neighborThreshold
        for i in 0..<particleBuffer.count {
            guard particleBuffer[i].isAlive else { continue }
            let pi = particleBuffer[i]
            var centerSum = Vec3(x: 0, y: 0, z: 0)
            var separationSum = Vec3(x: 0, y: 0, z: 0)
            var velocitySum = Vec3(x: 0, y: 0, z: 0)
            var neighborCount = 0
            for j in 0..<particleBuffer.count where j != i {
                guard particleBuffer[j].isAlive else { continue }
                let pj = particleBuffer[j]
                let delta = Self.subtract(pj.position, pi.position)
                let distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
                guard distSq < thresholdSq, distSq > 1e-9 else { continue }
                neighborCount += 1
                centerSum = Self.add(centerSum, pj.position)
                velocitySum = Self.add(velocitySum, pj.velocity)
                let dist = distSq.squareRoot()
                separationSum = Self.subtract(separationSum, Self.scale(delta, 1 / dist))
            }
            guard neighborCount > 0 else { continue }
            let n = Double(neighborCount)
            let cohesionDir = Self.subtract(Self.scale(centerSum, 1 / n), pi.position)
            let alignmentDir = Self.subtract(Self.scale(velocitySum, 1 / n), pi.velocity)
            forces[i] = Self.add(
                Self.add(Self.scale(cohesionDir, cohesionFactor),
                        Self.scale(separationSum, separationFactor)),
                Self.scale(alignmentDir, alignmentFactor))
        }
        return forces
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

            // drag는 초당 각속도 감쇠 계수다 — dω/dt = −drag·ω(위 movement와 같은 뜻).
            // `pow(1 − drag, dt)`는 drag가 1을 넘으면 밑이 음수라 NaN이 된다.
            if drag > 0 {
                let dampFactor = exp(-drag * dt)
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

        case .alphaChange(let startTime, let endTime, let startValue, let endValue):
            // `sizeChange`와 같은 식이다 — 알파 판이라고 보면 된다.
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
            // 겹쳐 곱한다 — `alphaFade`와 함께 쓰이면 둘 다 걸린다(`sizeChange`
            // 둘을 겹쳐 쓰는 실물 fireworks2flare와 같은 관례).
            particle.alpha = max(0, min(1, particle.alpha * factor))

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
                         let outputMin, let outputMax, let input):
            // 0~1 하나를 만들어 범위에 옮긴다.
            //
            // `simplexnoise`와 `fbmnoise`는 결이 다르지만 우리 잡음 하나로
            // 받는다 — 흐르는 모양은 나오지만 같지는 않다.
            let t: Double
            switch input {
            case .none:
                // 안 적으면(실물 대다수) 파티클마다 다른 씨앗을 쓰고 시간에
                // 따라 천천히 흐르게 한다 — 유리창의 물방울이 저마다 다른
                // 속도로 흘러내리는 모양이 이것이다.
                let seed = Self.hash(particle.frameSeed, 41) * 64
                switch transform {
                case .sine: t = 0.5 + 0.5 * sin(elapsed * inputScale + seed)
                case .noise: t = 0.5 + 0.5 * Self.noise(seed, elapsed * inputScale * 0.05, 0)
                }
            case .particleSystemTime:
                // 시스템 전체가 같은 시각을 쓴다 — 파티클별 씨앗을 안 섞는다
                // (실물 thunderbolt.json — 번개 전체가 함께 깜빡인다).
                switch transform {
                case .sine: t = 0.5 + 0.5 * sin(elapsed * inputScale)
                case .noise: t = 0.5 + 0.5 * Self.noise(0, elapsed * inputScale * 0.05, 0)
                }
            case .distanceToControlPoint(let controlPoint, let rangeMin, let rangeMax):
                // 거리를 그대로(잡음 없이) 0~1로 정규화한다 — 타입 선언부
                // 주석 참고. 제어점을 못 풀면(생성자가 이미 보고했다) 이번
                // 프레임은 손대지 않는다.
                guard let center = controlPointPosition(controlPoint) else { return }
                let delta = Self.subtract(particle.position, center)
                let distance = Self.length(delta)
                let span = rangeMax - rangeMin
                t = span > 1e-9 ? min(max((distance - rangeMin) / span, 0), 1) : 0
            case .unsupported:
                // 여기 오면 생성자가 이미 이름과 함께 보고했다.
                return
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

        case .capVelocity(let maxSpeed, let blendInStart, let blendInEnd):
            // alphaFade와 같은 "비율 구간" 관례 — 수명의 [blendInStart,
            // blendInEnd] 사이에서 0→1로 켜진다. 둘이 같으면 그 지점에서 바로
            // 켠다(실물 thunderbolt_child_spawner.json이 0.2, 0.2).
            guard particle.lifetime > 0 else { return }
            let progress = min(max(particle.age / particle.lifetime, 0), 1)
            let span = blendInEnd - blendInStart
            let factor = span > 1e-9
                ? min(max((progress - blendInStart) / span, 0), 1)
                : (progress >= blendInStart ? 1.0 : 0.0)
            guard factor > 0 else { return }
            let speed = Self.length(particle.velocity)
            guard speed > maxSpeed else { return }
            // 완전히 안 죈 속력에서 maxSpeed로 factor만큼 섞는다.
            let limitedSpeed = speed - (speed - maxSpeed) * factor
            let scale = limitedSpeed / speed
            particle.velocity = Self.scale(particle.velocity, scale)

        case .maintainDistanceBetweenControlPoints:
            // "선 방향으로 벗어난 만큼만" 되돌린다 — 통째로 목표 자리에 박으면
            // 안 된다. 실물 thunderbolt.json은 이 연산자와 turbulence(속도
            // 1000)·positionOffsetRandom을 같이 쓴다 — 그 잡음이 준 **수직**
            // 어긋남(번개가 지그재그로 흔들리는 모양)은 남기고, 선을 따라
            // 미끄러진 성분만 원래 자리로 되돌린다. 그래서 "제어점 사이의
            // 상대 거리"를 유지한다는 문서 문구가 성립한다 — 지그재그를
            // 지우면 지그재그가 있던 이유(잡음)와 이 연산자가 서로 모순된다.
            guard let fraction = particle.sequenceFraction else { return }
            let start = controlPointPosition(particle.sequenceControlPointStart) ?? originOffset
            let end = controlPointPosition(particle.sequenceControlPointEnd) ?? originOffset
            let segment = Self.subtract(end, start)
            let segmentLength = Self.length(segment)
            let target = Vec3(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction,
                z: start.z + (end.z - start.z) * fraction)
            guard segmentLength > 1e-9 else {
                // 두 제어점이 같은 자리면 "선 방향"이 없다 — 통째로 그 점에 둔다.
                particle.position = target
                return
            }
            let direction = Self.scale(segment, 1 / segmentLength)
            let deviation = Self.subtract(particle.position, target)
            let alongDeviation = Self.dot(deviation, direction)
            particle.position = Self.subtract(particle.position, Self.scale(direction, alongDeviation))

        case .maintainDistanceToControlPoint(let controlPoint, let variableStrength):
            // "태어났을 때의 거리"를 목표로 삼는다 — 필드에 목표 거리가 없어
            // 유일하게 지어내지 않는 기준점이다. 이 연산자를 처음 만나는
            // 프레임(태어난 순간)에 그 거리를 저장해 둔다.
            guard let center = controlPointPosition(controlPoint) else { return }
            let delta = Self.subtract(particle.position, center)
            let distance = Self.length(delta)
            guard distance > 1e-6 else { return }
            if particle.maintainedDistanceToControlPoint == nil {
                particle.maintainedDistanceToControlPoint = distance
            }
            guard let target = particle.maintainedDistanceToControlPoint else { return }
            // 목표보다 가까우면(diff>0) 밀어내고, 멀면(diff<0) 당긴다.
            let diff = target - distance
            let strength = variableStrength * diff * dt
            particle.velocity = Self.add(
                particle.velocity, Self.scale(delta, strength / distance))

        case .reduceMovementNearControlPoint(let controlPoint, let distanceInner,
                                             let distanceOuter, let reductionInner,
                                             let reductionOuter):
            // vortex의 distanceInner/distanceOuter와 같은 보간 관례 —
            // distanceInner에서 reductionInner, distanceOuter에서 reductionOuter다.
            guard let center = controlPointPosition(controlPoint) else { return }
            let distance = Self.length(Self.subtract(particle.position, center))
            let span = distanceOuter - distanceInner
            let ratio = span > 1e-9
                ? min(max((distance - distanceInner) / span, 0), 1) : 1.0
            let reduction = reductionInner + (reductionOuter - reductionInner) * ratio
            guard reduction > 0 else { return }
            let speed = Self.length(particle.velocity)
            guard speed > 1e-9 else { return }
            // "reduction"은 초당 줄이는 속력이다(문서화된 공식 없음 — 실물
            // `reductioninner: 1000`이 속도 단위와 같은 자리수라 드래그로
            // 읽었다). 0 아래로는 안 내려간다.
            let newSpeed = max(0, speed - reduction * dt)
            particle.velocity = Self.scale(particle.velocity, newSpeed / speed)

        case .boids:
            // 다른 파티클을 봐야 하는 연산자라 여기서는 처리하지 않는다 —
            // `applyOperators`가 프레임 시작 스냅샷으로 미리 힘을 계산해 얹는다.
            break

        case .collisionPlane(let axis, let distance, let behavior):
            let axisLength = Self.length(axis)
            guard axisLength > 1e-9 else { return }
            let normal = Self.scale(axis, 1 / axisLength)
            let signedDistance = Self.dot(particle.position, normal) - distance
            guard signedDistance < 0 else { return }
            particle.position = Self.subtract(particle.position, Self.scale(normal, signedDistance))
            Self.applyCollisionResponse(normal: normal, behavior: behavior, to: &particle)

        case .collisionSphere(let origin, let radius, let behavior):
            guard radius > 0 else { return }
            let center = Self.add(origin, originOffset)
            let delta = Self.subtract(particle.position, center)
            let dist = Self.length(delta)
            guard dist < radius, dist > 1e-6 else { return }
            let normal = Self.scale(delta, 1 / dist)
            particle.position = Self.add(center, Self.scale(normal, radius))
            Self.applyCollisionResponse(normal: normal, behavior: behavior, to: &particle)

        case .collisionQuad(let origin, let axis, let size, let behavior):
            let axisLength = Self.length(axis)
            guard axisLength > 1e-9 else { return }
            let normal = Self.scale(axis, 1 / axisLength)
            let center = Self.add(origin, originOffset)
            // 평면 위 두 접선축. `ParticleOrientationBasis`와 같은 방식 —
            // 법선이 월드 업과 거의 평행하면 대신 +X를 씨앗으로 쓴다.
            let worldUp = Vec3(x: 0, y: 1, z: 0)
            let seed = abs(normal.y) > 0.999 ? Vec3(x: 1, y: 0, z: 0) : worldUp
            guard let right = Self.normalize(Self.cross(seed, normal)) else { return }
            let forward = Self.cross(normal, right)
            let delta = Self.subtract(particle.position, center)
            let alongNormal = Self.dot(delta, normal)
            // 문서: "한쪽 면에서만" 막는다 — 법선이 가리키는 반대쪽에서 온
            // 파티클만 막는다(collisionPlane과 같은 부호 관례).
            guard alongNormal < 0 else { return }
            let alongRight = Self.dot(delta, right)
            let alongForward = Self.dot(delta, forward)
            guard abs(alongRight) <= size.x / 2, abs(alongForward) <= size.y / 2 else { return }
            particle.position = Self.subtract(particle.position, Self.scale(normal, alongNormal))
            Self.applyCollisionResponse(normal: normal, behavior: behavior, to: &particle)

        case .inheritValueFromEvent:
            // `inheritInitialValueFromEvent`의 매 프레임 판 — `updateChildren`이
            // `follow` 자식의 `parentSnapshot`을 매 프레임 새로 채운다.
            guard let parent = parentSnapshot else { return }
            particle.color = parent.color
            particle.size = parent.size
            particle.alpha = parent.alpha
            particle.velocity = parent.velocity
        }
    }

    // MARK: - Vec3 도우미(충돌·거리 유지 연산자가 여럿 쓴다)

    static func length(_ v: Vec3) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }
    static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }
    static func add(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }
    static func subtract(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }
    static func scale(_ v: Vec3, _ s: Double) -> Vec3 { Vec3(x: v.x * s, y: v.y * s, z: v.z * s) }
    static func normalize(_ v: Vec3) -> Vec3? {
        let len = length(v)
        guard len > 1e-9, len.isFinite else { return nil }
        return scale(v, 1 / len)
    }

    /// 충돌 네 연산자가 공유하는 반응 — 반사/미끄러짐/정지/삭제.
    /// `normal`은 충돌면에서 파티클 쪽을 향하는 단위 벡터다.
    static func applyCollisionResponse(
        normal: Vec3, behavior: ParticleCollisionBehavior, to particle: inout Particle
    ) {
        let vn = dot(particle.velocity, normal)
        // 이미 면에서 멀어지는 중이면(같은 프레임에 두 번 안 걸리게) 아무것도
        // 안 한다.
        guard vn < 0 else { return }
        switch behavior {
        case .bounce(let bounceFactor):
            let reflected = subtract(particle.velocity, scale(normal, 2 * vn))
            particle.velocity = scale(reflected, bounceFactor)
        case .slide:
            particle.velocity = subtract(particle.velocity, scale(normal, vn))
        case .stop:
            particle.velocity = Vec3(x: 0, y: 0, z: 0)
        case .delete:
            // 다음 프레임 시작(`removeDeadParticles`)에서 onDeath 자식을 낳고
            // 슬롯을 돌려준다 — 다른 수명 만료와 같은 경로다.
            particle.age = particle.lifetime
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
            // 프리셋에 없는 번호라도 0번은 시스템 자신의 자리로 본다. 덮어쓰기가
            // 있으면 그 위에 얹는다 — 정의된 점이 없어 플래그를 모르니 로컬로 본다
            // (world 플래그는 프리셋의 점에만 달리므로 여기선 판단할 근거가 없다).
            guard id == 0 else { return nil }
            guard let raw = instance.controlPoints[0] else { return originOffset }
            return Vec3(x: originOffset.x + raw.x,
                        y: originOffset.y + raw.y,
                        z: originOffset.z + raw.z)
        }
        if point.hasUnknownBinding { return nil }
        // 씬의 controlpointN 덮어쓰기(스크립트 포함)가 있으면 프리셋 offset을
        // 통째로 대신한다. 매번 다시 읽는다 — 스크립트가 언제든 바꿀 수 있다.
        let raw = instance.controlPoints[id] ?? point.offset
        if point.isWorldSpace {
            // 월드 좌표는 씬 전체 기준 절대 좌표라 그 자체가 최종 로컬 자리다 —
            // 이 시스템의 원점/커서(base)를 더하면 안 된다. 특히 자식 시스템은
            // originOffset이 "부모 파티클이 지금 있는 자리"라서, 더하면 화면
            // 좌표에 부모 위치가 또 얹혀 이중으로 밀린다.
            return worldToLocal(raw)
        }
        let base = point.followsCursor ? (cursorPosition ?? originOffset) : originOffset
        return Vec3(x: base.x + raw.x,
                    y: base.y + raw.y,
                    z: base.z + raw.z)
    }

    /// 제어점 0~7의 이번 프레임 속도를 지난 프레임 자리와 비교해 낸다.
    /// `inheritControlPointVelocity`가 쓴다 — 못 푸는 번호는 건너뛴다(다음
    /// 프레임에 다시 시도, 풀리면 그때부터 속도가 생긴다. 첫 프레임은 지난
    /// 자리가 없어 속도가 0이다).
    private func updateControlPointVelocities(dt: Double) {
        guard dt > 1e-9 else { return }
        for id in 0...7 {
            guard let current = controlPointPosition(id) else { continue }
            if let previous = previousControlPointPositions[id] {
                controlPointVelocities[id] = Vec3(
                    x: (current.x - previous.x) / dt,
                    y: (current.y - previous.y) / dt,
                    z: (current.z - previous.z) / dt)
            }
            previousControlPointPositions[id] = current
        }
    }

    /// 월드(화면) 좌표(플래그 2)를 이 시스템의 로컬 좌표로 바꾼다. 파티클
    /// 좌표계 자체가 레이어 원점 기준 상대 좌표라서 그렇다(이미터 스폰 위치가
    /// `originOffset + origin`으로 쌓이는 것과 같은 이유).
    ///
    /// ponytail: 레이어 회전은 무시한다 — 회전한 그룹 밑의 월드 좌표 제어점은
    /// 실물에서 아직 못 봤다. `layerOrigin`/`layerScale`은 렌더러가 시스템을
    /// 만들 때 한 번 넣어 준 값이라, 스크립트가 나중에 레이어를 옮겨도 다시
    /// 갱신되지 않는다 — 그런 조합도 아직 실물에서 못 봤다. 둘 다 필요해지면
    /// 렌더러가 `cursorPosition`처럼 매 틱 갱신해야 한다. 자식 시스템도 부모가
    /// 스폰하는 순간 이 값을 한 번만 물려받는다(`spawnChildren` 참고) — 부모
    /// 레이어가 나중에 옮겨져도 이미 만들어진 자식에는 다시 전파되지 않는다.
    private func worldToLocal(_ v: Vec3) -> Vec3 {
        func axis(_ value: Double, _ origin: Double, _ scale: Double) -> Double {
            // 배율 0(또는 비유한)은 나눗셈을 피하려고 1로 본다 — NaN이 여기서
            // 새면 이 자리를 쓰는 파티클이 전부 화면에서 사라진다.
            guard scale.isFinite, scale != 0 else { return value - origin }
            return (value - origin) / scale
        }
        return Vec3(x: axis(v.x, layerOrigin.x, layerScale.x),
                    y: axis(v.y, layerOrigin.y, layerScale.y),
                    z: axis(v.z, layerOrigin.z, layerScale.z))
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
