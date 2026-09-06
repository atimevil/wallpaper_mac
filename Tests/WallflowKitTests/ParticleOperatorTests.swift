import XCTest
@testable import WallflowKit

private final class FixedRandom: RandomSource {
    private let values: [Double]
    private var index = 0
    init(_ values: [Double]) { self.values = values }
    func next() -> Double {
        defer { index = (index + 1) % values.count }
        return values[index]
    }
}

/// 코퍼스를 세어 보니 아직 없던 연산자들 — `vortex_v2`(8곳), `turbulence`(22),
/// `oscillatesize`(8), `colorchange`(32), `controlpointattract`(34).
/// 없으면 파티클이 제자리에서만 뜨거나 색이 변하지 않는다.
final class ParticleOperatorTests: XCTestCase {
    private static let step = 1.0 / 60.0

    private func system(
        initializers: [ParticleInitializer] = [],
        operators: [ParticleOperator],
        burst: Int = 1
    ) -> ParticleSystem {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 0, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 1, z: 0),
            distanceMin: 10, distanceMax: 10,
            burst: ParticleEmitterBurst(count: burst, speedMin: 0, speedMax: 0))
        let preset = ParticlePreset(
            maxCount: 64, startTime: 0, materialPath: "m.json", emitters: [emitter],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .sizeRandom(min: 10, max: 10)] + initializers,
            operators: operators, unsupportedNames: [])
        return ParticleSystem(preset: preset, random: SeededRandom(seed: 3))
    }

    private func advance(_ system: ParticleSystem, seconds: Double) {
        for _ in 0..<Int((seconds / Self.step).rounded()) { system.update(deltaTime: Self.step) }
    }

    // MARK: colorchange

    /// 색은 **곱한다.** 갈아끼운다고 보면 `colorrandom`으로 정한 색이 사라진다.
    func testColorChangeMultipliesBaseColor() throws {
        // 바탕색을 흰색이 아닌 것으로 둔다. 흰색이면 곱하나 갈아끼우나 같아서
        // 어느 쪽인지 구별하지 못한다.
        let base = Vec3(x: 0.4, y: 0.4, z: 0.4)
        let system = self.system(
            initializers: [.colorRandom(min: base, max: base)],
            operators: [.colorChange(startTime: 0, endTime: 1,
                                     startValue: Vec3(x: 1, y: 1, z: 1),
                                     endValue: Vec3(x: 1, y: 0, z: 0))])
        advance(system, seconds: 50)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.color.x, 0.4, accuracy: 0.02, "바탕색을 지켜야 한다")
        XCTAssertEqual(particle.color.y, 0.2, accuracy: 0.02, "절반쯤 왔어야 한다")
        XCTAssertEqual(particle.color.z, 0.2, accuracy: 0.02)
    }

    /// 기본값(1 1 1 → 1 1 1)은 아무것도 바꾸지 않는다. 편집기가 기본값을 안 적어서
    /// 시각만 적힌 프리셋이 있는데, 그때 색이 튀면 안 된다.
    func testColorChangeDefaultsDoNothing() throws {
        let json = """
        {"maxcount": 4, "material": "m.json",
         "operator": [{"name": "colorchange", "starttime": 0.5, "endtime": 0.7}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        guard case .colorChange(_, _, let start, let end) = preset.operators[0] else {
            return XCTFail("colorchange여야 한다")
        }
        XCTAssertEqual(start, Vec3(x: 1, y: 1, z: 1))
        XCTAssertEqual(end, Vec3(x: 1, y: 1, z: 1))
    }

    // MARK: oscillate

    /// 진동수와 위상은 **태어날 때 정해진다.** 프레임마다 새로 뽑으면 흔들리는
    /// 게 아니라 무작위로 깜빡인다.
    func testOscillateSizeIsSmoothNotRandom() throws {
        let system = self.system(operators: [
            .oscillateSize(frequencyMin: 1, frequencyMax: 1, scaleMin: 0, scaleMax: 2),
        ])
        var sizes: [Double] = []
        for _ in 0..<30 {
            system.update(deltaTime: Self.step)
            if let particle = system.particles.first { sizes.append(particle.size) }
        }
        // 이웃한 프레임끼리 크게 튀면 안 된다. 1Hz면 한 프레임에 도는 각이 작다.
        let jumps = zip(sizes, sizes.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(try XCTUnwrap(jumps.max()), 3, "프레임마다 튀고 있다")
        // 그래도 움직이긴 해야 한다.
        XCTAssertGreaterThan(try XCTUnwrap(sizes.max()) - (try XCTUnwrap(sizes.min())), 0.5)
    }

    /// `scalemin`만 적힌 실물이 있다. 그게 뜻을 가지려면 `scalemax` 기본이 1이다.
    func testOscillateDefaultsFromRealPresets() throws {
        let json = """
        {"maxcount": 4, "material": "m.json",
         "operator": [{"name": "oscillatealpha", "frequencymin": 5, "frequencymax": 20,
                       "scalemin": 0.7},
                      {"name": "oscillatesize", "frequencymin": 10, "frequencymax": 25}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.operators.count, 2, "예전엔 scalemax가 없으면 통째로 버렸다")
        XCTAssertTrue(preset.malformedNames.isEmpty)
        guard case .oscillateAlpha(_, _, let scaleMin, let scaleMax) = preset.operators[0] else {
            return XCTFail("oscillatealpha여야 한다")
        }
        XCTAssertEqual(scaleMin, 0.7)
        XCTAssertEqual(scaleMax, 1)
    }

    // MARK: turbulence

    /// 잡음이 속도를 흔든다. 없으면 파티클이 뿌려진 자리에 그대로 있다.
    func testTurbulenceMovesParticlesAlongEnabledAxesOnly() throws {
        let system = self.system(
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .turbulence(mask: Vec3(x: 1, y: 0, z: 0), scale: 0.05,
                                    speedMin: 500, speedMax: 500, timeScale: 10,
                                    phaseMin: 0, phaseMax: 0)],
            burst: 8)
        // 첫 update에서 뿌린다. 그 전에는 아직 아무것도 없다.
        system.update(deltaTime: Self.step)
        let before = system.particles.map(\.position)
        advance(system, seconds: 2)
        let after = system.particles.map(\.position)
        XCTAssertEqual(before.count, after.count)
        let movedX = zip(before, after).map { abs($1.x - $0.x) }.max() ?? 0
        let movedY = zip(before, after).map { abs($1.y - $0.y) }.max() ?? 0
        XCTAssertGreaterThan(movedX, 1, "x축으로 흔들려야 한다")
        XCTAssertEqual(movedY, 0, accuracy: 0.0001, "마스크가 0인 축은 가만히 있어야 한다")
    }

    /// 잡음은 자리의 함수다. 같은 자리에서 두 번 물으면 같은 값이 나와야
    /// 파티클들이 **함께** 흐른다.
    func testNoiseIsStableAndSmooth() {
        XCTAssertEqual(ParticleSystem.noise(1.5, 2.5, 3.5),
                       ParticleSystem.noise(1.5, 2.5, 3.5))
        let a = ParticleSystem.noise(1.5, 2.5, 3.5)
        let b = ParticleSystem.noise(1.51, 2.5, 3.5)
        XCTAssertLessThan(abs(a - b), 0.3, "조금 옮겼는데 값이 튀면 매끄럽지 않다")
        for i in 0..<50 {
            let v = ParticleSystem.noise(Double(i) * 0.7, Double(i) * 1.3, Double(i) * 0.1)
            XCTAssertGreaterThanOrEqual(v, -1)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }

    // MARK: vortex

    /// 소용돌이는 축을 중심으로 **돌린다.** 원점에서의 거리는 크게 변하지 않고
    /// 각도가 돈다.
    func testVortexTurnsParticlesAroundTheAxis() throws {
        let system = self.system(
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .vortex(axis: Vec3(x: 0, y: 0, z: 1), distanceInner: 0,
                                distanceOuter: 10, speedInner: 0, speedOuter: 100)],
            burst: 4)
        system.update(deltaTime: Self.step)
        let before = try XCTUnwrap(system.particles.first)
        let startAngle = atan2(before.position.y, before.position.x)
        advance(system, seconds: 0.2)
        let after = try XCTUnwrap(system.particles.first)
        let endAngle = atan2(after.position.y, after.position.x)
        XCTAssertNotEqual(startAngle, endAngle, accuracy: 0.01, "각이 돌아야 한다")
        // 접선 방향으로만 밀었으므로 거리는 크게 늘지 않는다(원운동의 이산화 오차만).
        let r0 = (before.position.x * before.position.x
            + before.position.y * before.position.y).squareRoot()
        let r1 = (after.position.x * after.position.x
            + after.position.y * after.position.y).squareRoot()
        XCTAssertEqual(r1, r0, accuracy: r0 * 0.6)
    }

    /// `vortex_v2`의 고리는 아직 모델링하지 않는다. 나머지는 하고 그 사실을 남긴다.
    func testVortexV2ReportsUnmodelledRing() throws {
        let json = """
        {"maxcount": 4, "material": "m.json",
         "operator": [{"name": "vortex_v2", "distanceinner": 0, "distanceouter": 1,
                       "speedinner": 0, "speedouter": 2500,
                       "ringradius": 256, "ringwidth": 5, "ringpulldistance": 250}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.operators.count, 1, "고리가 있어도 도는 것은 해야 한다")
        XCTAssertTrue(preset.unsupportedNames.contains("vortex_v2(고리)"))
    }

    // MARK: controlpointattract

    /// 0번 제어점은 시스템 자신의 자리다. 양수면 끌어당기고 음수면 밀어낸다.
    func testControlPointAttractPullsTowardOrigin() throws {
        func run(scale: Double) throws -> Double {
            let system = self.system(
                operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                            .controlPointAttract(controlPoint: 0,
                                                 origin: Vec3(x: 0, y: 0, z: 0),
                                                 scale: scale, threshold: 100)])
            advance(system, seconds: 1)
            let particle = try XCTUnwrap(system.particles.first)
            return (particle.position.x * particle.position.x
                + particle.position.y * particle.position.y
                + particle.position.z * particle.position.z).squareRoot()
        }
        let pulled = try run(scale: 200)
        let pushed = try run(scale: -200)
        XCTAssertLessThan(pulled, 10, "당기면 원점으로 다가와야 한다")
        XCTAssertGreaterThan(pushed, 10, "음수면 멀어져야 한다")
    }
}
