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

/// `remapvalue` — 유리창에 맺힌 비가 이걸로 흘러내린다. 없으면 중력만 남아
/// 방울이 느리게 떨어지기만 한다.
extension ParticleOperatorTests {
    /// 실물 `rain_screen_4k`의 두 줄 그대로. 하나는 우리가 넣고, 하나는
    /// 아직 못 넣는다 — 못 넣는 것은 **이름과 함께** 남겨야 한다.
    func testParsesRealRainRemaps() throws {
        let json = """
        {"maxcount": 60, "material": "m.json",
         "operator": [{"name": "remapvalue", "operation": "remap", "output": "velocity",
                       "outputrangemax": "200 -1000 0", "outputrangemin": "-200 -100 0",
                       "transformfunction": "simplexnoise", "transforminputscale": 10},
                      {"flags": 3, "name": "remapvalue", "output": "speed",
                       "outputrangemax": 7, "outputrangemin": -5,
                       "transformfunction": "fbmnoise", "transforminputscale": 8}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.operators.count, 2)
        guard case .remapValue(let output, _, let scale, let lo, let hi) = preset.operators[0]
        else { return XCTFail("remapvalue여야 한다") }
        XCTAssertEqual(output, .velocity)
        XCTAssertEqual(scale, 10)
        XCTAssertEqual(lo, Vec3(x: -200, y: -100, z: 0))
        XCTAssertEqual(hi, Vec3(x: 200, y: -1000, z: 0))

        // 실물 rain_screen*.json이 4곳에서 쓰는 두 번째 연산자. `output: "speed"`는
        // 속도의 크기만 바꾸는 출력이고, 이제 넣었으니 더 이상 못 넣는 목록에 없다.
        guard case .remapValue(let output2, _, let scale2, let lo2, let hi2) = preset.operators[1]
        else { return XCTFail("remapvalue여야 한다") }
        XCTAssertEqual(output2, .speed)
        XCTAssertEqual(scale2, 8)
        XCTAssertEqual(lo2, Vec3(x: -5, y: -5, z: -5))
        XCTAssertEqual(hi2, Vec3(x: 7, y: 7, z: 7))

        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.unimplementedOperators, [],
                       "speed 출력을 이제 넣으므로 더 이상 보고하면 안 된다")
    }

    /// `output: speed`는 방향은 그대로 두고 크기만 갈아끼워야 한다.
    /// 실물이 이 값을 `output: velocity` 뒤에 붙여 낙하 속력을 2차로 흔든다.
    func testRemapSpeedKeepsDirectionButChangesMagnitude() throws {
        // 3:4:0 방향(크기 5)으로 고정한 뒤, speed 출력으로 크기를 10으로 갈아끼운다.
        // 방향(비율)은 그대로여야 한다.
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 3, y: 4, z: 0),
                                           max: Vec3(x: 3, y: 4, z: 0))],
            operators: [.remapValue(output: .speed, transform: .noise, inputScale: 8,
                                    outputMin: Vec3(x: 10, y: 10, z: 10),
                                    outputMax: Vec3(x: 10, y: 10, z: 10))],
            burst: 8)
        system.update(deltaTime: 1.0 / 60)
        XCTAssertFalse(system.particles.isEmpty)
        for particle in system.particles {
            let magnitude = (particle.velocity.x * particle.velocity.x
                + particle.velocity.y * particle.velocity.y
                + particle.velocity.z * particle.velocity.z).squareRoot()
            // 범위가 10~10으로 고정이라 크기는 항상 10에 가까워야 한다.
            XCTAssertEqual(magnitude, 10, accuracy: 0.01)
            // 방향(3:4 비율)은 지켜야 한다 — 통째로 갈아끼우는 `.velocity`와 다르다.
            XCTAssertEqual(particle.velocity.x / particle.velocity.y, 3.0 / 4.0, accuracy: 0.01)
        }
    }

    /// 방울마다 다른 속도를 받아야 한다. 하나로 뭉치면 전부 같은 줄로 떨어진다.
    func testRemapGivesEachParticleItsOwnVelocity() throws {
        let system = self.system(
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .remapValue(output: .velocity, transform: .noise, inputScale: 10,
                                    outputMin: Vec3(x: -200, y: -100, z: 0),
                                    outputMax: Vec3(x: 200, y: -1000, z: 0))],
            burst: 16)
        system.update(deltaTime: 1.0 / 60)
        let speeds = system.particles.map(\.velocity.y)
        XCTAssertFalse(speeds.isEmpty)
        // 전부 범위 안이어야 하고, 서로 달라야 한다.
        XCTAssertTrue(speeds.allSatisfy { $0 <= -100 && $0 >= -1000 },
                      "범위를 벗어난 값이 있다: \(speeds)")
        XCTAssertGreaterThan(Set(speeds.map { Int($0 / 10) }).count, 3, "전부 같은 속도다")
    }
}

/// 제어점 — 프리셋이 정의하고 연산자가 번호로 가리킨다.
///
/// `flags`의 1번 비트가 **마우스를 따라가라**는 뜻이다. 실물
/// `examplecursoravoid`(이름 그대로 커서를 피하는 예제)의 1번 제어점이
/// `flags: 1`이고, `fireflies`·`vapor0` 같은 상호작용 프리셋이 전부 같은 꼴이다.
extension ParticleOperatorTests {
    private func preset(controlPoints: String, operators: String) throws -> ParticlePreset {
        let json = """
        {"maxcount": 8, "material": "m.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1,
                      "distancemin": 100, "distancemax": 100}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "sizerandom", "min": 10, "max": 10}],
         "controlpoint": \(controlPoints),
         "operator": \(operators)}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(ParticlePreset.parse(object))
    }

    func testParsesControlPoints() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 0, "offset": "0 0 0", "flags": 0}, {"id": 1, "offset": "50 0 0", "flags": 1}]"#,
            operators: "[]")
        XCTAssertEqual(preset.controlPoints.count, 2)
        XCTAssertFalse(preset.controlPoints[0].followsCursor)
        XCTAssertTrue(preset.controlPoints[1].followsCursor)
        XCTAssertEqual(preset.controlPoints[1].offset, Vec3(x: 50, y: 0, z: 0))
    }

    /// 커서를 따라가는 제어점은 커서 자리로 간다. 못 받았으면 시스템 자리다.
    func testCursorControlPointFollowsTheMouse() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "0 0 0", "flags": 1}]"#, operators: "[]")
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 0, y: 0, z: 0),
                       "커서를 못 받았으면 시스템 자리")
        system.cursorPosition = Vec3(x: 300, y: 200, z: 0)
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 300, y: 200, z: 0))
    }

    /// 커서를 피한다. 실물 `fireflies`가 `scale: -50`으로 이렇게 흩어진다.
    func testParticlesAvoidTheCursor() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "0 0 0", "flags": 1}]"#,
            operators: """
            [{"name": "movement", "gravity": "0 0 0", "drag": 0},
             {"name": "controlpointattract", "controlpoint": 1,
              "scale": -2000, "threshold": 400}]
            """)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 60)
        let before = try XCTUnwrap(system.particles.first).position
        // 커서를 파티클 쪽에 둔다. 밀려나야 한다.
        system.cursorPosition = before
        for _ in 0..<60 { system.update(deltaTime: 1.0 / 60) }
        let after = try XCTUnwrap(system.particles.first).position
        let moved = ((after.x - before.x) * (after.x - before.x)
            + (after.y - before.y) * (after.y - before.y)).squareRoot()
        XCTAssertGreaterThan(moved, 10, "커서에서 밀려나야 한다")
        XCTAssertTrue(system.unimplementedOperators.isEmpty, "이제 이 조합은 다 한다")
    }

    /// 우리가 모르는 묶임(4, 부모 복사)은 손대지 않고 번호와 함께 남긴다.
    /// 2(월드 좌표)와 16(편집기 전용)은 이제 안다 — 아래 테스트들 참고.
    func testUnknownControlPointBindingIsReported() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "0 0 0", "flags": 4}]"#,
            operators: """
            [{"name": "controlpointattract", "controlpoint": 1, "scale": 100, "threshold": 100}]
            """)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.unimplementedOperators, ["controlpointattract(제어점 1)"])
        XCTAssertNil(system.controlPointPosition(1))
    }

    /// 16(편집기 전용 표시)은 런타임에 아무 효과가 없다 — 실물 `dripping_water`의
    /// 두 제어점이 이 모양이다. 손대지 않고 그대로 쓰고, 보고하지도 않는다.
    func testEditorOnlyFlagIsIgnoredNotReported() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "5 0 0", "flags": 16}]"#,
            operators: """
            [{"name": "controlpointattract", "controlpoint": 1, "scale": 1, "threshold": 1}]
            """)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertTrue(system.unimplementedOperators.isEmpty, "16은 편집기 전용 — 보고하면 안 된다")
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 5, y: 0, z: 0))
    }

    /// `controlpoint0` 덮어쓰기는 프리셋이 0번을 따로 정의하지 않았어도 먹어야
    /// 한다 — 0번은 "이 시스템 자신의 자리"라 항상 있는 취급이지, 프리셋이 안
    /// 적었다고 덮어쓰기까지 무시하면 안 된다.
    func testControlPointZeroOverrideAppliesWithoutPresetDeclaration() throws {
        let preset = try preset(controlPoints: "[]", operators: "[]")
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.controlPointPosition(0), Vec3(x: 0, y: 0, z: 0), "덮어쓰기 전에는 원점")
        system.instance.controlPoints[0] = Vec3(x: 7, y: 8, z: 9)
        XCTAssertEqual(system.controlPointPosition(0), Vec3(x: 7, y: 8, z: 9))
    }

    /// 씬의 `controlpointN` 덮어쓰기는 프리셋의 offset을 통째로 대신한다.
    func testControlPointOverrideReplacesPresetOffset() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "5 0 0", "flags": 0}]"#, operators: "[]")
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 5, y: 0, z: 0), "덮어쓰기 전에는 프리셋 offset")
        system.instance.controlPoints[1] = Vec3(x: 99, y: 1, z: 2)
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 99, y: 1, z: 2), "덮어쓰기가 대신해야 한다")
    }

    /// 월드(화면) 좌표(플래그 2)는 `(값 − 레이어 원점)/배율`로 이 시스템의 로컬
    /// 좌표로 바뀐다. 프리셋 offset과 씬의 덮어쓰기 둘 다 같은 규칙을 받는다 —
    /// 어느 쪽에서 왔든 플래그가 월드 좌표라고 하면 화면 좌표라는 뜻이기 때문이다.
    func testWorldSpaceControlPointConvertsUsingLayerOriginAndScale() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "1000 500 0", "flags": 2}]"#, operators: "[]")
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.layerOrigin = Vec3(x: 100, y: 100, z: 0)
        system.layerScale = Vec3(x: 2, y: 2, z: 1)
        // (1000-100)/2 = 450, (500-100)/2 = 200
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 450, y: 200, z: 0))

        // 덮어쓰기(스크립트 포함)도 같은 규칙을 받는다: (1100-100)/2=500, (300-100)/2=100
        system.instance.controlPoints[1] = Vec3(x: 1100, y: 300, z: 0)
        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 500, y: 100, z: 0))
    }

    /// 배율 0(또는 비유한)은 나눗셈을 피하려고 1로 본다. NaN이 여기서 새면
    /// 이 자리를 쓰는 파티클이 전부 화면에서 사라진다.
    func testWorldSpaceControlPointGuardsDegenerateScale() throws {
        let preset = try preset(
            controlPoints: #"[{"id": 1, "offset": "50 0 0", "flags": 2}]"#, operators: "[]")
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.layerOrigin = Vec3(x: 0, y: 0, z: 0)
        system.layerScale = Vec3(x: 0, y: 1, z: 1)
        XCTAssertEqual(system.controlPointPosition(1)?.x, 50)
    }
}

/// 이미터 `controlpoint` — 이미터가 뿌리는 자리를 시스템 원점 대신 제어점으로 바꾼다.
/// 실물 `dripping_water`가 두 낙수 자리(제어점 1·2)에서 각각 뿌린다.
extension ParticleOperatorTests {
    /// 제어점 자리에서 뿌려야 한다. 이미터 자신의 `origin`은 그 위에 더한다.
    /// distancemin=distancemax=0이라 흩어짐 없이 정확히 그 자리여야 한다.
    func testEmitterSpawnsFromControlPoint() throws {
        let json = """
        {"maxcount": 8, "material": "m.json",
         "controlpoint": [{"id": 1, "offset": "22 0 0", "flags": 0}],
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 8,
                      "controlpoint": 1, "distancemin": 0, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 60)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.position, Vec3(x: 22, y: 0, z: 0))
    }

    /// 없으면(대부분의 실물 이미터) 지금처럼 이 시스템의 원점에서 뿌린다 —
    /// 생략을 0번으로 보면 0번을 따로 정의한 프리셋의 뿌리는 자리가 조용히 바뀐다.
    func testEmitterWithoutControlPointKeepsOriginBehavior() throws {
        let json = """
        {"maxcount": 8, "material": "m.json",
         "controlpoint": [{"id": 0, "offset": "500 500 0", "flags": 0}],
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 8,
                      "distancemin": 0, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 60)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.position, Vec3(x: 0, y: 0, z: 0),
                       "controlpoint 키가 없으면 0번 제어점의 offset을 끌어오면 안 된다")
    }

    /// 이미터가 못 푸는 제어점을 쓰면 원점으로 물러나고, 생성자에서 한 번만 보고한다.
    func testEmitterControlPointFallsBackAndReportsOnce() throws {
        let json = """
        {"maxcount": 8, "material": "m.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 8,
                      "controlpoint": 3, "distancemin": 0, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.unimplementedOperators, ["sphererandom(제어점 3)"])
        system.update(deltaTime: 1.0 / 60)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.position, Vec3(x: 0, y: 0, z: 0), "못 풀면 원점으로 물러나야 한다")
    }
}

/// `mapsequencearoundcontrolpoint` — 실물에서 `magic_trinity` 프리셋 하나만 쓴다.
/// 문서 표시 이름은 "Position around control point"지만 원본 JSON 이름은 이거다.
extension ParticleOperatorTests {
    private func sequencePreset(
        controlPoints: String = "[]", initializer: String
    ) throws -> ParticlePreset {
        // boxrandom을 쓴다. 세 축의 min==max라 난수를 뽑아도 자리가 항상
        // (48, 0, 0)으로 고정된다 — sphererandom은 각도가 난수라 z를 0으로
        // 지워도(2D 기본값) xy 반지름이 sin(phi)만큼 흔들려 "반지름을 지키는지"
        // 시험이 아니라 "난수가 뭐가 나왔는지" 시험이 돼 버린다.
        let json = """
        {"maxcount": 8, "material": "m.json",
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 8,
                      "distancemin": "48 0 0", "distancemax": "48 0 0"}],
         "controlpoint": \(controlPoints),
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "sizerandom", "min": 10, "max": 10}, \(initializer)],
         "operator": []}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(ParticlePreset.parse(object))
    }

    /// 실물 `magic_trinity`의 값 그대로 읽는다.
    func testParsesMapSequenceAroundControlPoint() throws {
        let preset = try sequencePreset(initializer: """
            {"bounds": "0 1", "count": 3.02, "id": 4, "limitbehavior": "repeat",
             "name": "mapsequencearoundcontrolpoint",
             "speedmax": "0 100 0", "speedmin": "0 10 0"}
            """)
        XCTAssertEqual(preset.initializers.count, 3)
        guard case .mapSequenceAroundControlPoint(let point, let count, let start, let end,
                                                  let mirror, let lo, let hi) = preset.initializers[2]
        else { return XCTFail("mapsequencearoundcontrolpoint여야 한다") }
        XCTAssertEqual(point, 0, "번호가 없으면 0번(시스템 자신의 자리)이다")
        XCTAssertEqual(count, 3.02)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 1)
        XCTAssertFalse(mirror, "limitbehavior가 repeat이면 왕복이 아니다")
        XCTAssertEqual(lo, Vec3(x: 0, y: 10, z: 0))
        XCTAssertEqual(hi, Vec3(x: 0, y: 100, z: 0))
    }

    /// 반지름은 이 초기화자가 정하지 않는다 — 이미터가 뿌린 거리를 그대로 지켜야 한다.
    /// 이미터가 항상 (48, 0, 0)에 뿌리므로(boxrandom, min==max) 모든 파티클이
    /// 원점에서 48이어야 한다 — 각도만 바뀌고 반지름은 그대로.
    func testMapSequencePreservesEmitterRadius() throws {
        let preset = try sequencePreset(initializer: """
            {"bounds": "0 1", "count": 4, "name": "mapsequencearoundcontrolpoint",
             "speedmin": "0 0 0", "speedmax": "0 0 0"}
            """)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 60)
        XCTAssertFalse(system.particles.isEmpty)
        for particle in system.particles {
            let radius = (particle.position.x * particle.position.x
                + particle.position.y * particle.position.y).squareRoot()
            XCTAssertEqual(radius, 48, accuracy: 0.01, "반지름이 이미터 거리와 달라졌다")
        }
    }

    /// count개 자리를 순서대로 돌아야 한다(repeat: 0,1,2,0,1,2,…).
    func testNextSequenceSlotRepeatsInOrder() {
        var counter = 0
        let slots = (0..<6).map { _ in
            ParticleSystem.nextSequenceSlot(&counter, count: 3, mirror: false)
        }
        XCTAssertEqual(slots, [0, 1, 2, 0, 1, 2])
    }

    /// mirror는 끝에서 되돌아가야 한다(0,1,2,1,0,1,2,1,…).
    func testNextSequenceSlotMirrorsBackAndForth() {
        var counter = 0
        let slots = (0..<8).map { _ in
            ParticleSystem.nextSequenceSlot(&counter, count: 3, mirror: true)
        }
        XCTAssertEqual(slots, [0, 1, 2, 1, 0, 1, 2, 1])
    }

    /// 0번이 아닌 번호인데 씬이 그 제어점을 안 주면 못 푼다 — 이름과 번호로 남긴다.
    func testMapSequenceReportsUnresolvableControlPoint() throws {
        let preset = try sequencePreset(initializer: """
            {"bounds": "0 1", "controlpoint": 3, "count": 3,
             "name": "mapsequencearoundcontrolpoint",
             "speedmin": "0 0 0", "speedmax": "0 0 0"}
            """)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        XCTAssertEqual(system.unimplementedOperators, ["mapsequencearoundcontrolpoint(제어점 3)"])
        // 못 풀어도 파티클은 이미터가 준 자리에 그대로 있어야 한다(원점 순간이동 금지).
        system.update(deltaTime: 1.0 / 60)
        for particle in system.particles {
            XCTAssertTrue(particle.position.x.isFinite && particle.position.y.isFinite)
        }
    }

    /// `stop()`은 살아 있는 파티클을 거두고 더 뿌리지 않는다. `play()`면 다시 뿌린다.
    func testStopClearsAndPlayResumes() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"maxcount": 50, "material": "m.json", "emitter": [{"name": "boxrandom", "rate": 100, "instantaneous": 10}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}], "renderer": [{"name": "sprite"}]}
        """.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 0.1)
        XCTAssertGreaterThan(system.aliveCount, 0)
        system.stop()
        XCTAssertEqual(system.aliveCount, 0)
        XCTAssertFalse(system.isPlaying)
        system.update(deltaTime: 0.5)
        XCTAssertEqual(system.aliveCount, 0, "멈춘 동안은 뿌리지 않는다")
        system.play()
        system.update(deltaTime: 0.1)
        XCTAssertGreaterThan(system.aliveCount, 0)
    }
}
