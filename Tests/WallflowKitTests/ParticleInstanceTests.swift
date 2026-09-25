import XCTest
@testable import WallflowKit

/// 씬 배율(`instanceoverride`)은 초기화자가 아니라 **스폰 결과**와 힘에 곱한다.
/// 공식 문서 IParticleSystemInstance: 전부 배율이고 1이면 그대로다.
final class ParticleInstanceTests: XCTestCase {
    let zero = Vec3(x: 0, y: 0, z: 0)

    /// 초기화자가 하나도 없는 프리셋. 기본값(크기 1·투명도 1·수명 1·흰색)만 있다.
    func bare(rate: Double = 0, burst: ParticleEmitterBurst = ParticleEmitterBurst(count: 8),
              initializers: [ParticleInitializer] = [],
              operators: [ParticleOperator] = []) -> ParticlePreset {
        ParticlePreset(
            maxCount: 64, startTime: 0, materialPath: "m.json",
            emitters: [.sphereRandom(rate: rate, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0, burst: burst)],
            initializers: initializers, operators: operators, unsupportedNames: [])
    }

    func spawn(_ preset: ParticlePreset, _ o: ParticleOverride, dt: Double = 0.05) -> [Particle] {
        let system = ParticleSystem(preset: preset.applying(o), random: SeededRandom(seed: 7))
        system.update(deltaTime: dt)
        return system.particles
    }

    /// 실물 PS2 시계 파티클은 colorrandom이 없다. 초기화자에 곱하던 때는 colorn이
    /// 통째로 버려졌다. 크기·투명도·수명도 같은 처지였다.
    func testFactorsApplyWithoutInitializers() {
        var o = ParticleOverride()
        o.size = 2; o.alpha = 0.5; o.lifetime = 3
        o.color = Vec3(x: 0.2, y: 0.4, z: 0.6)
        let ps = spawn(bare(), o)
        XCTAssertEqual(ps.count, 8)
        for p in ps {
            XCTAssertEqual(p.size, 2, accuracy: 1e-9)
            XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-9)
            XCTAssertEqual(p.lifetime, 3, accuracy: 1e-9)
            XCTAssertEqual(p.color, Vec3(x: 0.2, y: 0.4, z: 0.6))  // 흰색 × 틴트
        }
    }

    /// colorn은 틴트다 — 프리셋 색에 곱한다. WE 자체 물 튀김 미리보기가 이미 하늘색인
    /// 프리셋에 파란 colorn을 얹는다.
    func testColornTintsPresetColor() throws {
        var o = ParticleOverride()
        o.color = Vec3(x: 0.5, y: 0.5, z: 1)
        let preset = bare(initializers: [.colorRandom(min: Vec3(x: 1, y: 0.5, z: 0.5),
                                                      max: Vec3(x: 1, y: 0.5, z: 0.5))])
        let p = try XCTUnwrap(spawn(preset, o).first)
        XCTAssertEqual(p.color.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.color.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-9)
    }

    /// WE 자체 번개 미리보기가 brightness 5를, 실물 Universal Reflex 3이 10·3을 쓴다.
    /// 색에 곱한다 — 1을 넘어도 된다(가산 혼합에서 더 밝게 더해진다).
    func testBrightnessMultipliesColor() throws {
        var o = ParticleOverride()
        o.brightness = 10
        let p = try XCTUnwrap(spawn(bare(), o).first)
        XCTAssertEqual(p.color, Vec3(x: 10, y: 10, z: 10))
    }

    /// speed는 "initial velocity" — 이미터가 주는 속력(불꽃)까지 포함한 최종 속도다.
    func testSpeedScalesEmitterSpeed() throws {
        var o = ParticleOverride()
        o.speed = 3
        let preset = bare(burst: ParticleEmitterBurst(count: 1, speedMin: 10, speedMax: 10))
        let p = try XCTUnwrap(spawn(preset, o, dt: 1e-6).first)
        let v = p.velocity
        XCTAssertEqual((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), 30, accuracy: 1e-6)
    }

    /// speed는 "and forces" — 중력도 같이 커져야 궤적이 같은 모양으로 늘어난다.
    func testSpeedScalesGravity() throws {
        var o = ParticleOverride()
        o.speed = 2
        let preset = bare(burst: ParticleEmitterBurst(count: 1),
                          operators: [.movement(gravity: Vec3(x: 0, y: -10, z: 0), drag: 0)])
        let p = try XCTUnwrap(spawn(preset, o, dt: 0.1).first)
        XCTAssertEqual(p.velocity.y, -2, accuracy: 1e-9)  // -10 × 2 × 0.1
    }

    /// remapvalue가 속도를 정하는 프리셋(실물 rain_screen)도 speed 배율을 받는다.
    func testSpeedScalesRemapVelocity() throws {
        var o = ParticleOverride()
        o.speed = 2
        let preset = bare(burst: ParticleEmitterBurst(count: 1), operators: [
            .remapValue(output: .velocity, transform: .noise, inputScale: 1,
                        outputMin: Vec3(x: 10, y: 0, z: 0), outputMax: Vec3(x: 10, y: 0, z: 0)),
        ])
        let p = try XCTUnwrap(spawn(preset, o, dt: 0.05).first)
        XCTAssertEqual(p.velocity.x, 20, accuracy: 1e-9)
    }

    /// drag는 초당 감쇠 계수다(dv/dt = −drag·v). 실물 프리셋의 3분의 1이 1을 넘는다
    /// (반딧불 2.5, 불꽃 3.5~4). `pow(1 − drag, dt)`는 그때 NaN이 되어 파티클이 사라졌다.
    func testDragAboveOneStaysFinite() throws {
        let preset = bare(burst: ParticleEmitterBurst(count: 1, speedMin: 10, speedMax: 10),
                          operators: [.movement(gravity: zero, drag: 2.5)])
        let p = try XCTUnwrap(spawn(preset, ParticleOverride(), dt: 0.1).first)
        let v = p.velocity
        let speed = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        XCTAssertTrue(speed.isFinite)
        XCTAssertEqual(speed, 10 * exp(-0.25), accuracy: 1e-9)
    }

    /// angularmovement의 drag도 movement와 같은 공식이어야 한다 — dω/dt = −drag·ω.
    /// `pow(1 − drag, dt)`는 여기서도 drag > 1이면 NaN이 된다.
    func testAngularDragAboveOneStaysFinite() throws {
        let preset = bare(burst: ParticleEmitterBurst(count: 1),
                          initializers: [.angularVelocityRandom(min: Vec3(x: 0, y: 0, z: 10),
                                                                max: Vec3(x: 0, y: 0, z: 10))],
                          operators: [.angularMovement(force: zero, drag: 2.5)])
        let p = try XCTUnwrap(spawn(preset, ParticleOverride(), dt: 0.1).first)
        XCTAssertTrue(p.angularVelocity.z.isFinite)
        XCTAssertEqual(p.angularVelocity.z, 10 * exp(-0.25), accuracy: 1e-9)
    }

    /// 예산은 개수만 줄인다. 씬 배율을 지우면 안 된다.
    func testBudgetKeepsSceneInstance() {
        var o = ParticleOverride()
        o.size = 2
        let p = bare(rate: 10).applying(o).scaledToBudget(0.5)
        XCTAssertEqual(p.instance.size, 2)
        XCTAssertEqual(p.maxCount, 32)
    }

    /// 스크립트가 쓴 값도 파일과 같은 규칙으로 거른다.
    func testApplyFiltersScriptValues() {
        var o = ParticleOverride()
        o.apply(["rate": .scalar(0.5), "size": .scalar(.nan), "speed": .scalar(-1),
                 "count": .scalar(1e9), "colorn": .vector([0.1, 0.2, 0.3]),
                 "brightness": .vector([1, 2, 3])])
        XCTAssertEqual(o.rate, 0.5)
        XCTAssertEqual(o.size, 1)
        XCTAssertEqual(o.speed, 1)
        XCTAssertEqual(o.count, 1)
        XCTAssertEqual(o.brightness, 1)
        XCTAssertEqual(o.color, Vec3(x: 0.1, y: 0.2, z: 0.3))
    }

    /// 스크립트 쪽 시작값은 지금 배율 그대로다. 색은 있을 때만.
    func testScriptValuesRoundTrip() {
        var o = ParticleOverride()
        o.rate = 0.19
        var back = ParticleOverride()
        back.apply(o.scriptValues)
        XCTAssertEqual(back, o)
        XCTAssertNil(o.scriptValues["colorn"])
    }

    /// rate는 "simulation rate" — 시간을 늦춘다. 방출률이 아니다.
    /// 실물 The Gilded Shore의 소용돌이 8개가 rate 0.18이다(magic_vortex_0: maxcount 256,
    /// 방출 512/s, 수명 0.4~0.7). 방출률로 읽으면 ~50개가 빨리 돌고, 시간으로 읽으면
    /// ~256개가 5.5배 느리게 돈다.
    func testRateSlowsSimulationNotEmission() {
        let preset = ParticlePreset(
            maxCount: 256, startTime: 0, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 512, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0)],
            initializers: [.lifetimeRandom(min: 0.4, max: 0.7)],
            operators: [], unsupportedNames: [])
        var o = ParticleOverride()
        o.rate = 0.18
        let system = ParticleSystem(preset: preset.applying(o), random: SeededRandom(seed: 3))
        for _ in 0..<150 { system.update(deltaTime: 1.0 / 30) }  // 5초
        XCTAssertGreaterThan(system.aliveCount, 200)
    }

    /// 나이도 같은 시계를 따른다 — rate 0.5면 1초 뒤 나이는 0.5초다.
    func testRateScalesAge() throws {
        var o = ParticleOverride()
        o.rate = 0.5; o.lifetime = 100
        let system = ParticleSystem(preset: bare(burst: ParticleEmitterBurst(count: 1)).applying(o),
                                    random: SeededRandom(seed: 5))
        for _ in 0..<10 { system.update(deltaTime: 0.1) }
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age, 0.5, accuracy: 1e-9)
    }

    /// 큰 rate도 한 걸음에 maxTimeStep을 넘지 않는다. (0.05초 × 100 = 5초 → 0.1초로 죈다.
    /// 옛 코드는 rate를 무시해 0.05초라 실패한다.)
    func testHugeRateIsClamped() throws {
        var o = ParticleOverride()
        o.rate = 100; o.lifetime = 1000
        let system = ParticleSystem(preset: bare(burst: ParticleEmitterBurst(count: 1)).applying(o),
                                    random: SeededRandom(seed: 5))
        system.update(deltaTime: 0.05)
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age, ParticleSystem.maxTimeStep,
                       accuracy: 1e-9)
    }

    /// count는 "emission rate" — 계속 뿌리는 양도, 한꺼번에 뿌리는 양도 곱한다.
    func testCountScalesEmissionAndBurst() {
        var o = ParticleOverride()
        o.count = 3; o.lifetime = 100
        let continuous = ParticleSystem(preset: bare(rate: 10, burst: .none).applying(o),
                                        random: SeededRandom(seed: 1))
        for _ in 0..<10 { continuous.update(deltaTime: 0.1) }
        XCTAssertTrue((29...31).contains(continuous.aliveCount), "\(continuous.aliveCount)")

        o.count = 0.5
        XCTAssertEqual(spawn(bare(burst: ParticleEmitterBurst(count: 4)), o, dt: 1e-6).count, 2)
        // 있던 일괄 방출을 0으로 만들지는 않는다(실물 PS2 오브는 일괄 1개다).
        o.count = 0.05
        XCTAssertEqual(spawn(bare(burst: ParticleEmitterBurst(count: 1)), o, dt: 1e-6).count, 1)
    }

    /// starttime은 프리웜이다 — 첫 프레임에 이미 그만큼 돈 상태여야 한다.
    func testStartTimePrewarms() {
        let preset = ParticlePreset(
            maxCount: 64, startTime: 10, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 1, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], unsupportedNames: [])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 2))
        system.update(deltaTime: 1.0 / 30)
        XCTAssertTrue((9...11).contains(system.aliveCount), "\(system.aliveCount)")
    }

    /// 파일에서 온 값이라 상한을 둔다. 한 번에 치를 값이어야 한다.
    func testPrewarmIsCapped() throws {
        let preset = ParticlePreset(
            maxCount: 8, startTime: 1e6, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 0, origin: zero, directions: Vec3(x: 1, y: 1, z: 0),
                                     distanceMin: 0, distanceMax: 0,
                                     burst: ParticleEmitterBurst(count: 1))],
            initializers: [.lifetimeRandom(min: 1e7, max: 1e7)],
            operators: [], unsupportedNames: [])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 2))
        system.update(deltaTime: 0.05)
        XCTAssertEqual(try XCTUnwrap(system.particles.first).age,
                       ParticleSystem.maxPrewarm + 0.05, accuracy: 1e-6)
    }
}
