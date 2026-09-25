import XCTest
@testable import WallflowKit

/// 로프가 필요로 하는 `ParticleSystem` 쪽 행동: 생성 순번, `age` 동률 가르기,
/// `one_per_frame` 이미터, 자식 벌끼리 안 섞이는 로프 그룹.
final class RopeParticleSystemTests: XCTestCase {
    private static let step = 1.0 / 64.0

    private func advance(_ system: ParticleSystem, seconds: Double) {
        let count = Int((seconds / Self.step).rounded())
        for _ in 0..<count { system.update(deltaTime: Self.step) }
    }

    private func preset(
        maxCount: Int = 100, emitters: [ParticleEmitter],
        initializers: [ParticleInitializer] = [],
        children: [ParticleChild] = []
    ) -> ParticlePreset {
        ParticlePreset(maxCount: maxCount, startTime: 0, materialPath: "m.json",
                       emitters: emitters, initializers: initializers,
                       operators: [], unsupportedNames: []).withChildren(children)
    }

    // MARK: 생성 순번 · age 동률

    /// 한 프레임에 여럿이 태어나면 나이가 완전히 같다 — 생성 순번만이
    /// 태어난 차례를 가른다. 순번은 0부터 하나씩 늘어야 한다.
    func testSameFrameSpawnsGetIncreasingSequence() {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 0, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0,
            burst: ParticleEmitterBurst(count: 5, speedMin: 0, speedMax: 0))
        let system = ParticleSystem(
            preset: preset(emitters: [emitter],
                          initializers: [.lifetimeRandom(min: 10, max: 10)]),
            random: SeededRandom(seed: 1))
        system.update(deltaTime: Self.step)
        let ordered = system.ropeOrderedParticles
        XCTAssertEqual(ordered.count, 5)
        XCTAssertTrue(ordered.allSatisfy { $0.age == ordered[0].age }, "다 같은 프레임에 났다")
        XCTAssertEqual(ordered.map(\.spawnSequence), (0..<5).map { $0 })
    }

    /// `age` 내림차순이 1순위다 — 먼저 난 것이 배열 앞(로프의 꼬리)이다.
    func testOlderParticlesComeFirst() {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 60, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [emitter],
                          initializers: [.lifetimeRandom(min: 10, max: 10)]),
            random: SeededRandom(seed: 1))
        advance(system, seconds: 0.2)
        let ordered = system.ropeOrderedParticles
        XCTAssertGreaterThan(ordered.count, 1)
        for i in 1..<ordered.count {
            XCTAssertLessThanOrEqual(ordered[i].age, ordered[i - 1].age)
        }
    }

    // MARK: one_per_frame

    /// `flags: 2`가 있으면 `rate`가 커도 한 프레임에 하나만 난다 — 실물
    /// `orbTrail.json`(rate 60, flags 2)이 이 모양이다.
    func testOnePerFrameCapsEmissionRegardlessOfRate() {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 60, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0, flags: 2)
        let system = ParticleSystem(
            preset: preset(emitters: [emitter],
                          initializers: [.lifetimeRandom(min: 10, max: 10)]),
            random: SeededRandom(seed: 1))
        // 60fps 한 걸음(1/60초)이면 rate 60은 credit 1을 쌓아 보통도 1개지만,
        // 느린 프레임(1/10초, credit 6)에서 갈린다.
        system.update(deltaTime: 1.0 / 10)
        XCTAssertEqual(system.aliveCount, 1, "느린 프레임이어도 하나만 나야 한다")
        system.update(deltaTime: 1.0 / 10)
        XCTAssertEqual(system.aliveCount, 2, "다음 프레임에 딱 하나 더")
    }

    func testWithoutOnePerFrameSlowFrameEmitsMany() {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 60, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(emitters: [emitter],
                          initializers: [.lifetimeRandom(min: 10, max: 10)]),
            random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 10)
        XCTAssertEqual(system.aliveCount, 6, "flags 없으면 credit만큼 한꺼번에 난다")
    }

    // MARK: 인스턴스끼리 안 섞임

    /// 부모 파티클 둘이 각자 `eventfollow` 자식 벌을 하나씩 거느리면, 로프
    /// 그룹은 벌마다 따로여야 한다 — `renderableGroups`처럼 합치면 안 된다.
    func testRopeGroupsKeepChildInstancesSeparate() throws {
        let parentEmitter = ParticleEmitter.sphereRandom(
            rate: 0, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0,
            burst: ParticleEmitterBurst(count: 2, speedMin: 0, speedMax: 0))
        let childEmitter = ParticleEmitter.sphereRandom(
            rate: 30, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let childPreset = ParticlePreset(
            maxCount: 20, startTime: 0, materialPath: "c.json", emitters: [childEmitter],
            initializers: [.lifetimeRandom(min: 10, max: 10)], operators: [],
            unsupportedNames: [])
        let child = ParticleChild(
            reference: ParticleChildReference(
                name: "trail", trigger: .follow, maxCount: 4, origin: Vec3(x: 0, y: 0, z: 0)),
            preset: childPreset, texturePath: "t", blend: .additive)
        let system = ParticleSystem(
            preset: preset(emitters: [parentEmitter],
                          initializers: [.lifetimeRandom(min: 10, max: 10)],
                          children: [child]),
            random: SeededRandom(seed: 3))
        advance(system, seconds: 0.5)
        let groups = system.ropeGroups()
        let childGroup = try XCTUnwrap(groups.first { $0.key == "0.0" })
        XCTAssertEqual(childGroup.instances.count, 2, "부모 파티클 둘 → 벌 둘, 안 합친다")
        for instance in childGroup.instances {
            XCTAssertFalse(instance.isEmpty)
        }
    }
}
