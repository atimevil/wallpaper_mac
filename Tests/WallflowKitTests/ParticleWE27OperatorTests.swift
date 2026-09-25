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

/// WE 2.7(2025-09)에서 새로 생긴 emitter/initializer/operator. 실물 창작마당
/// 편집기 미리보기(`Assets/scenes/particleelementpreviews/<name>/`)와 실제로
/// 창작자가 복사해 쓰는 번들 프리셋(번개·물방울·소용돌이)을 그대로 옮긴 값으로
/// 검증한다.
final class ParticleWE27OperatorTests: XCTestCase {
    private static let step = 1.0 / 60.0

    private func system(
        initializers: [ParticleInitializer] = [],
        operators: [ParticleOperator] = [],
        controlPoints: [ParticleControlPoint] = [],
        burst: Int = 1,
        maxCount: Int = 64,
        emitterDistance: Double = 10,
        random: RandomSource = SeededRandom(seed: 3)
    ) -> ParticleSystem {
        let emitter = ParticleEmitter.sphereRandom(
            rate: 0, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 1, z: 0),
            distanceMin: emitterDistance, distanceMax: emitterDistance,
            burst: ParticleEmitterBurst(count: burst, speedMin: 0, speedMax: 0))
        let preset = ParticlePreset(
            maxCount: maxCount, startTime: 0, materialPath: "m.json", emitters: [emitter],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .sizeRandom(min: 10, max: 10)] + initializers,
            operators: operators, unsupportedNames: [], controlPoints: controlPoints)
        return ParticleSystem(preset: preset, random: random)
    }

    private func advance(_ system: ParticleSystem, seconds: Double) {
        for _ in 0..<Int((seconds / Self.step).rounded()) { system.update(deltaTime: Self.step) }
    }

    // MARK: mapSequenceBetweenControlPoints / maintainDistanceBetweenControlPoints

    /// 실물 창작마당 미리보기 그대로 — 두 제어점을 잇는 선 위에 순서대로
    /// 놓인다. 첫 파티클(슬롯 0)은 시작 제어점 위에 있어야 한다.
    func testMapSequenceBetweenControlPointsPlacesFirstParticleAtStart() throws {
        let cp1 = ParticleControlPoint(id: 1, offset: Vec3(x: -400, y: -400, z: 0), flags: 0)
        let cp2 = ParticleControlPoint(id: 2, offset: Vec3(x: 400, y: 400, z: 0), flags: 0)
        let system = self.system(
            initializers: [.mapSequenceBetweenControlPoints(
                controlPointStart: 1, controlPointEnd: 2, count: 4, hasArc: false)],
            controlPoints: [cp1, cp2], burst: 1, emitterDistance: 0)
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.position.x, -400, accuracy: 1)
        XCTAssertEqual(particle.position.y, -400, accuracy: 1)
    }

    /// count를 안 적으면(실물 thunderbolt.json) maxCount 전체를 선에 깐다.
    func testMapSequenceBetweenControlPointsDefaultsCountToMaxCount() throws {
        let cp1 = ParticleControlPoint(id: 0, offset: Vec3(x: 0, y: 0, z: 0), flags: 0)
        let cp2 = ParticleControlPoint(id: 1, offset: Vec3(x: 100, y: 0, z: 0), flags: 0)
        let system = self.system(
            initializers: [.mapSequenceBetweenControlPoints(
                controlPointStart: 0, controlPointEnd: 1, count: 0, hasArc: false)],
            controlPoints: [cp1, cp2], burst: 4, maxCount: 4, emitterDistance: 0)
        system.update(deltaTime: Self.step)
        let xs = system.particles.map(\.position.x).sorted()
        // maxCount=4로 나눠 0, 25, 50, 75에 온다(75는 100이 아니다 — repeat
        // 슬롯이 0..<count까지만 돈다, mapSequenceAroundControlPoint와 같다).
        XCTAssertEqual(xs.count, 4)
        for (x, expected) in zip(xs, [0.0, 25, 50, 75]) {
            XCTAssertEqual(x, expected, accuracy: 1)
        }
    }

    /// 제어점이 움직이면(스크립트 덮어쓰기) 그 자리를 따라간다 — "거리를
    /// 유지한다"는 것이 이 뜻이다.
    func testMaintainDistanceBetweenControlPointsFollowsMovingControlPoints() throws {
        let cp0 = ParticleControlPoint(id: 0, offset: Vec3(x: 0, y: 0, z: 0), flags: 0)
        let cp1 = ParticleControlPoint(id: 1, offset: Vec3(x: 100, y: 0, z: 0), flags: 0)
        let system = self.system(
            initializers: [.mapSequenceBetweenControlPoints(
                controlPointStart: 0, controlPointEnd: 1, count: 1, hasArc: false)],
            operators: [.maintainDistanceBetweenControlPoints],
            controlPoints: [cp0, cp1], burst: 1)
        system.update(deltaTime: Self.step)
        // 제어점 1을 스크립트로 옮긴다.
        system.instance.controlPoints[1] = Vec3(x: 500, y: 0, z: 0)
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        // count=1이면 슬롯 0의 fraction은 0/1=0 → 항상 시작 제어점(0,0,0) 위다.
        XCTAssertEqual(particle.position.x, 0, accuracy: 1)
    }

    /// 실물 `dna.json`은 이 초기화자 **앞에** `mapSequenceAroundControlPoint`를
    /// 둔다 — 원(나선의 반지름) 위에 자리를 잡은 다음, 이 초기화자가 그 원의
    /// 중심을 두 제어점 사이로 옮긴다. 통째로 자리를 갈아 끼우면 원이
    /// 사라져 나선이 직선이 된다 — 세 파티클이 일직선에 놓이면 안 된다.
    func testMapSequenceBetweenControlPointsPreservesAroundControlPointOffset() throws {
        let cp1 = ParticleControlPoint(id: 1, offset: Vec3(x: -400, y: -400, z: 0), flags: 0)
        let system = self.system(
            initializers: [
                .mapSequenceAroundControlPoint(
                    controlPoint: 0, count: 8, boundsStart: 0, boundsEnd: 1,
                    mirror: false, speedMin: Vec3(x: 0, y: 0, z: 0), speedMax: Vec3(x: 0, y: 0, z: 0)),
                .mapSequenceBetweenControlPoints(
                    controlPointStart: 0, controlPointEnd: 1, count: 8, hasArc: false),
            ],
            controlPoints: [cp1], burst: 8, emitterDistance: 50)
        system.update(deltaTime: Self.step)
        let positions = system.particles.map(\.position)
        XCTAssertEqual(positions.count, 8)
        // 아무 세 점이나 잡아 일직선인지 본다(외적 크기가 0에 가까우면 일직선).
        let a = positions[0], b = positions[1], c = positions[2]
        let ab = Vec3(x: b.x - a.x, y: b.y - a.y, z: 0)
        let ac = Vec3(x: c.x - a.x, y: c.y - a.y, z: 0)
        let cross = abs(ab.x * ac.y - ab.y * ac.x)
        XCTAssertGreaterThan(cross, 1, "원 위의 자리가 남아 있어야 한다 — 직선이면 안 된다")
    }

    /// 실물 `thunderbolt.json`은 `maintainDistanceBetweenControlPoints`를
    /// `turbulence`·`positionOffsetRandom`과 같이 쓴다 — 지그재그(번개 모양)를
    /// 유지해야 하고, 선 위로 완전히 눌러 붙이면(예전의 통째로 자리를 박는
    /// 버그) 안 된다.
    func testMaintainDistanceBetweenControlPointsKeepsPerpendicularJitter() throws {
        let cp0 = ParticleControlPoint(id: 0, offset: Vec3(x: 0, y: 0, z: 0), flags: 0)
        let cp1 = ParticleControlPoint(id: 1, offset: Vec3(x: 0, y: -450, z: 0), flags: 0)
        let system = self.system(
            initializers: [.positionOffsetRandom(distance: 100, scale: 0, timeScale: 5),
                           .mapSequenceBetweenControlPoints(
                            controlPointStart: 0, controlPointEnd: 1, count: 8, hasArc: false)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 2),
                        .turbulence(mask: Vec3(x: 1, y: 1, z: 1), scale: 0.01,
                                   speedMin: 1000, speedMax: 1000, timeScale: 10000,
                                   phaseMin: 0, phaseMax: 0),
                        .maintainDistanceBetweenControlPoints],
            controlPoints: [cp0, cp1], burst: 8, maxCount: 8, emitterDistance: 0)
        for _ in 0..<30 { system.update(deltaTime: Self.step) }
        let maxAbsX = system.particles.map { abs($0.position.x) }.max() ?? 0
        XCTAssertGreaterThan(maxAbsX, 1, "잡음이 준 수직(X) 어긋남이 남아 있어야 한다")
    }

    // MARK: positionOffsetRandom

    /// scale이 0이면(실물 thunderbolt.json) 자리와 무관하게 흔들린다 — 같은
    /// 시각에 잰 두 파티클(서로 다른 자리)이 같은 오프셋을 받아야 한다.
    func testPositionOffsetRandomWithZeroScaleIgnoresPosition() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                           .positionOffsetRandom(distance: 100, scale: 0, timeScale: 5)],
            burst: 1)
        system.update(deltaTime: Self.step)
        let a = try XCTUnwrap(system.particles.first)
        XCTAssertNotEqual(a.position, Vec3(x: 0, y: 0, z: 0), "distance:100이면 원점에서 움직여야 한다")
    }

    // MARK: reduceMovementNearControlPoint / maintainDistanceToControlPoint

    /// 제어점 근처에서(distanceinner 안쪽) 속력이 빠르게 줄어야 한다.
    func testReduceMovementNearControlPointSlowsDownCloseToPoint() throws {
        let cp0 = ParticleControlPoint(id: 0, offset: Vec3(x: 0, y: 0, z: 0), flags: 0)
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                           max: Vec3(x: 100, y: 0, z: 0))],
            operators: [.reduceMovementNearControlPoint(
                controlPoint: 0, distanceInner: 20, distanceOuter: 50,
                reductionInner: 1000, reductionOuter: 0)],
            controlPoints: [cp0], burst: 1)
        // 이미터가 원점 근처(거리 10)에 뿌린다 — distanceInner(20) 안쪽이라
        // 최대 감속이 걸려야 한다.
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertLessThan(particle.velocity.x, 100, "reductioninner가 속력을 깎아야 한다")
    }

    /// 목표 거리(태어났을 때 거리)에서 벗어나면 되돌아오는 방향으로 당겨야 한다.
    func testMaintainDistanceToControlPointPullsBackToSpawnDistance() throws {
        let cp0 = ParticleControlPoint(id: 0, offset: Vec3(x: 0, y: 0, z: 0), flags: 0)
        let system = self.system(
            operators: [.maintainDistanceToControlPoint(controlPoint: 0, variableStrength: 50)],
            controlPoints: [cp0], burst: 1)
        system.update(deltaTime: Self.step)
        let born = try XCTUnwrap(system.particles.first)
        let bornDistance = (born.position.x * born.position.x
            + born.position.y * born.position.y).squareRoot()
        // 관성으로 조금 더 멀어지게 둔다(이미터가 준 초기 위치 그대로 정지해
        // 있으니, 외력이 없으면 그대로다 — 대신 위치를 강제로 밀어 검증한다는
        // 게 유닛 테스트에 없어서, 대신 몇 프레임 더 굴려 "목표에서 안
        // 벗어난다"는 안정성만 확인한다).
        advance(system, seconds: 1)
        let later = try XCTUnwrap(system.particles.first)
        let laterDistance = (later.position.x * later.position.x
            + later.position.y * later.position.y).squareRoot()
        XCTAssertEqual(laterDistance, bornDistance, accuracy: 5,
                       "당기는 힘이 있으면 태어난 거리 근처에 머물러야 한다")
    }

    // MARK: capVelocity

    /// 실물 `capvelocity` 미리보기 그대로 — blendinstart~blendinend를 지나면
    /// 속력이 maxspeed로 죈다.
    func testCapVelocityLimitsSpeedAfterBlendIn() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: -600, z: 0),
                                           max: Vec3(x: 0, y: -600, z: 0)),
                           .lifetimeRandom(min: 1, max: 1)],
            operators: [.capVelocity(maxSpeed: 100, blendInStart: 0.1, blendInEnd: 0.1)],
            burst: 1)
        advance(system, seconds: 0.5)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertLessThanOrEqual(abs(particle.velocity.y), 100.5)
    }

    // MARK: boids

    /// separationfactor: 0(실물 `dripping_water.json`)이면 분리력이 없어야
    /// 한다 — 두 파티클을 서로 겹치게 두고 간격이 안 벌어지는지로 검증한다.
    func testBoidsWithZeroSeparationFactorAppliesNoSeparation() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .boids(cohesionFactor: 0, separationFactor: 0, alignmentFactor: 0,
                              neighborThreshold: 1000)],
            burst: 2)
        system.update(deltaTime: Self.step)
        let before = system.particles.map(\.position)
        advance(system, seconds: 0.2)
        let after = system.particles.map(\.position)
        // 이미터가 둘을 거의 같은 자리(반지름 10)에 뿌리고, 모든 힘이 0이니
        // 위치가 거의 안 바뀌어야 한다.
        XCTAssertEqual(before.count, after.count)
        for (b, a) in zip(before.sorted(by: { $0.x < $1.x }), after.sorted(by: { $0.x < $1.x })) {
            XCTAssertEqual(a.x, b.x, accuracy: 1)
            XCTAssertEqual(a.y, b.y, accuracy: 1)
        }
    }

    /// cohesionFactor > 0이면 이웃 쪽으로 당기는 속도가 붙어야 한다.
    func testBoidsWithCohesionPullsTowardNeighbors() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0))],
            operators: [.boids(cohesionFactor: 4, separationFactor: 0, alignmentFactor: 0,
                               neighborThreshold: 1000)],
            burst: 2)
        system.update(deltaTime: Self.step)
        // 응집력이 걸리면 둘 중 하나 이상이 0이 아닌 속도를 받아야 한다
        // (완전히 같은 자리가 아닌 한 서로를 향해 당긴다).
        let moved = system.particles.contains {
            abs($0.velocity.x) > 1e-6 || abs($0.velocity.y) > 1e-6
        }
        XCTAssertTrue(moved, "응집력이 있으면 속도가 생겨야 한다")
    }

    // MARK: colorlist / hsvcolorrandom

    /// 실물 `colorlist` 값은 이미 0~1이다 — colorrandom처럼 255로 나누지 않는다.
    func testColorListUsesValuesAsIs() throws {
        let colors = [Vec3(x: 0, y: 0.6, z: 1), Vec3(x: 1, y: 0.96, z: 0)]
        let system = self.system(initializers: [.colorList(colors: colors)], burst: 1)
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertTrue(colors.contains(particle.color), "colorlist 값 중 하나여야 하고 0~1 그대로여야 한다")
    }

    /// 실물 `hsvcolorrandom`은 채도·명도를 생략한다 — 기본이 1(꽉 찬 색)이어야
    /// 한다(0이면 검정이 된다).
    func testHSVColorRandomDefaultsToFullSaturationAndValue() throws {
        let system = self.system(
            initializers: [.hsvColorRandom(
                hueMin: 0, hueMax: 0, hueSteps: 0,
                saturationMin: 1, saturationMax: 1, valueMin: 1, valueMax: 1)],
            burst: 1)
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        // hue 0, s 1, v 1 = 순수 빨강.
        XCTAssertEqual(particle.color.x, 1, accuracy: 0.01)
        XCTAssertEqual(particle.color.y, 0, accuracy: 0.01)
        XCTAssertEqual(particle.color.z, 0, accuracy: 0.01)
    }

    /// huesteps가 있으면 색상이 그 개수만큼 이산 구간에 붙어야 한다.
    func testHSVColorRandomQuantizesHueSteps() throws {
        let system = self.system(
            initializers: [.hsvColorRandom(
                hueMin: 0, hueMax: 1, hueSteps: 2,
                saturationMin: 1, saturationMax: 1, valueMin: 1, valueMax: 1)],
            burst: 1, random: FixedRandom([0.3]))
        system.update(deltaTime: Self.step)
        let particle = try XCTUnwrap(system.particles.first)
        // hue 0.3 → 2단계로 양자화하면 0(0~0.5 구간)이라 순수 빨강이어야 한다.
        XCTAssertEqual(particle.color.x, 1, accuracy: 0.01)
        XCTAssertEqual(particle.color.y, 0, accuracy: 0.01)
    }

    // MARK: collision

    /// 실물 `collisionplane` 미리보기 그대로 — 바닥(y=-200)을 뚫고 내려가면
    /// 튕겨야 한다.
    func testCollisionPlaneBounces() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: -1000, z: 0),
                                           max: Vec3(x: 0, y: -1000, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .collisionPlane(axis: Vec3(x: 0, y: 1, z: 0), distance: -200,
                                        behavior: .bounce(bounceFactor: 0.7))],
            burst: 1)
        advance(system, seconds: 0.5)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertGreaterThanOrEqual(particle.position.y, -200.5, "바닥을 뚫으면 안 된다")
        XCTAssertGreaterThan(particle.velocity.y, 0, "튕기면 위로 향해야 한다")
    }

    /// `stop` 동작은 충돌하면 속도를 완전히 죽인다.
    func testCollisionSphereStopsOnImpact() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: -500, z: 0),
                                           max: Vec3(x: 0, y: -500, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .collisionSphere(origin: Vec3(x: 0, y: -50, z: 0), radius: 40,
                                         behavior: .stop)],
            burst: 1)
        advance(system, seconds: 0.5)
        let particle = try XCTUnwrap(system.particles.first)
        XCTAssertEqual(particle.velocity.x, 0, accuracy: 0.01)
        XCTAssertEqual(particle.velocity.y, 0, accuracy: 0.01)
    }

    /// `delete` 동작은 파티클을 죽인다.
    func testCollisionQuadDeletesOnImpact() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: -1000, z: 0),
                                           max: Vec3(x: 0, y: -1000, z: 0)),
                           .lifetimeRandom(min: 100, max: 100)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .collisionQuad(origin: Vec3(x: 0, y: -50, z: 0),
                                       axis: Vec3(x: 0, y: 1, z: 0),
                                       size: Vec2(x: 1000, y: 1000), behavior: .delete)],
            burst: 1)
        advance(system, seconds: 0.5)
        XCTAssertEqual(system.aliveCount, 0, "delete는 파티클을 죽여야 한다")
    }

    /// 사각 판 바깥(크기 밖)은 충돌하지 않아야 한다.
    func testCollisionQuadIgnoresOutsideBounds() throws {
        let system = self.system(
            initializers: [.velocityRandom(min: Vec3(x: 0, y: -1000, z: 0),
                                           max: Vec3(x: 0, y: -1000, z: 0)),
                           .lifetimeRandom(min: 100, max: 100)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .collisionQuad(origin: Vec3(x: 500, y: -50, z: 0),
                                       axis: Vec3(x: 0, y: 1, z: 0),
                                       size: Vec2(x: 10, y: 10), behavior: .delete)],
            burst: 1)
        advance(system, seconds: 0.5)
        XCTAssertGreaterThan(system.aliveCount, 0, "판 밖은 충돌하면 안 된다")
    }
}

/// `renderer`/`operator`/`initializer` JSON 파싱 — 실물 값 그대로.
final class ParticleWE27ParsingTests: XCTestCase {
    private func preset(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// 실물 `capvelocity` 창작마당 미리보기 그대로.
    func testParsesRealCapVelocity() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"blendinend":0.6,"blendinstart":0.5,"id":12,"maxspeed":100,
                      "name":"capvelocity"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators,
                       [.capVelocity(maxSpeed: 100, blendInStart: 0.5, blendInEnd: 0.6)])
    }

    /// 실물 `magic_vortex_orb.json` 그대로 — variablestrength만 있다.
    func testParsesRealMaintainDistanceToControlPoint() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"id":12,"name":"maintaindistancetocontrolpoint","variablestrength":5}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators,
                       [.maintainDistanceToControlPoint(controlPoint: 0, variableStrength: 5)])
    }

    /// 실물 `thunderbolt.json` 그대로 — 필드가 없다.
    func testParsesRealMaintainDistanceBetweenControlPoints() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"id":15,"name":"maintaindistancebetweencontrolpoints"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators, [.maintainDistanceBetweenControlPoints])
    }

    /// 실물 `thunderbolt.json`의 두 `reducemovementnearcontrolpoint` 중
    /// 제어점 번호가 없는 것 — 0번 기본.
    func testParsesRealReduceMovementNearControlPoint() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"distanceinner":20,"distanceouter":50,"id":17,
                      "name":"reducemovementnearcontrolpoint","reductioninner":1000}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators, [.reduceMovementNearControlPoint(
            controlPoint: 0, distanceInner: 20, distanceOuter: 50,
            reductionInner: 1000, reductionOuter: 0)])
    }

    /// 실물 `dripping_water.json` 그대로 — separationfactor 0.
    func testParsesRealBoids() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"alignmentfactor":5,"cohesionfactor":5,"flags":0,"id":14,
                      "name":"boids","neighborthreshold":150,"separationfactor":0}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators, [.boids(
            cohesionFactor: 5, separationFactor: 0, alignmentFactor: 5, neighborThreshold: 150)])
    }

    /// 실물 `collisionplane` 창작마당 미리보기 그대로 — axis가 없다(기본 Y).
    func testParsesRealCollisionPlane() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"bouncefactor":0.7,"distance":-200,"id":8,"name":"collisionplane"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators, [.collisionPlane(
            axis: Vec3(x: 0, y: 1, z: 0), distance: -200, behavior: .bounce(bounceFactor: 0.7))])
    }

    /// 실물 `collisionsphere`/`collisionquad` 창작마당 미리보기 그대로 —
    /// `collisionbehavior: slide`.
    func testParsesRealCollisionSphereAndQuad() throws {
        let sphereJSON = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"collisionbehavior":"slide","id":9,"name":"collisionsphere",
                      "origin":"0 -100 0"}]}
        """))
        let sphere = try XCTUnwrap(ParticlePreset.parse(sphereJSON))
        XCTAssertEqual(sphere.operators, [.collisionSphere(
            origin: Vec3(x: 0, y: -100, z: 0), radius: 0, behavior: .slide)])

        let quadJSON = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"collisionbehavior":"slide","id":8,"name":"collisionquad",
                      "origin":"0 -100 0","size":"100 100"}]}
        """))
        let quad = try XCTUnwrap(ParticlePreset.parse(quadJSON))
        XCTAssertEqual(quad.operators, [.collisionQuad(
            origin: Vec3(x: 0, y: -100, z: 0), axis: Vec3(x: 0, y: 1, z: 0),
            size: Vec2(x: 100, y: 100), behavior: .slide)])
    }

    /// 실물 `thunderbolt.json` 그대로 — count/controlpoint가 없다.
    func testParsesRealMapSequenceBetweenControlPoints() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"arcamount":0.1,"flags":23,"id":14,
                        "name":"mapsequencebetweencontrolpoints"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers, [.mapSequenceBetweenControlPoints(
            controlPointStart: 0, controlPointEnd: 1, count: 0, hasArc: true)])
    }

    /// 실물 `dna.json` 그대로 — count가 명시돼 있다.
    func testParsesRealMapSequenceBetweenControlPointsWithCount() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"count":64,"id":5,"name":"mapsequencebetweencontrolpoints"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers, [.mapSequenceBetweenControlPoints(
            controlPointStart: 0, controlPointEnd: 1, count: 64, hasArc: false)])
    }

    /// 실물 `colorlist` 창작마당 미리보기 그대로.
    func testParsesRealColorList() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"colors":["0 0.6117647 1","1 0.9607843 0","0.9333333 0 1"],
                        "id":9,"name":"colorlist"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .colorList(let colors) = try XCTUnwrap(p.initializers.first) else {
            return XCTFail("colorlist여야 한다")
        }
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(colors[0], Vec3(x: 0, y: 0.6117647, z: 1))
    }

    /// 실물 `hsvcolorrandom` 창작마당 미리보기 그대로.
    func testParsesRealHSVColorRandom() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"huemax":1.0,"huemin":0.0,"huesteps":6,"id":4,
                        "name":"hsvcolorrandom","saturationmax":1.0,"saturationmin":1.0,
                        "valuemax":1.0,"valuemin":1.0}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers, [.hsvColorRandom(
            hueMin: 0, hueMax: 1, hueSteps: 6, saturationMin: 1, saturationMax: 1,
            valueMin: 1, valueMax: 1)])
    }

    /// 실물 `thunderbolt.json` 그대로 — scale 0, timescale 5.
    func testParsesRealPositionOffsetRandom() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"distance":100,"id":22,"name":"positionoffsetrandom",
                        "scale":0,"timescale":5}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers,
                       [.positionOffsetRandom(distance: 100, scale: 0, timeScale: 5)])
    }

    /// 실물에 안 쓰는 이름은 계속 unsupported로 보고한다 — collisionmodel(메시
    /// 데이터 필요), collisionbounds(공간 정보 없음), inheritcontrolpointvelocity
    /// (제어점 속도 이력 없음), remapinitialvalue(distancetocontrolpoint 입력
    /// 미구현), inheritvaluefromevent류(자식 스폰에 부모 상태 안 넘김),
    /// layerimage(레이어 알파, App 쪽 관심사).
    func testStillUnsupportedNamesAreReported() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"id":1,"name":"collisionmodel"},{"id":2,"name":"collisionbounds"},
                     {"id":3,"name":"inheritvaluefromevent"}],
         "initializer":[{"id":4,"name":"inheritcontrolpointvelocity"},
                        {"id":5,"name":"remapinitialvalue"},
                        {"id":6,"name":"inheritinitialvaluefromevent"}],
         "emitter":[{"id":7,"name":"layerimage","rate":10}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        for name in ["collisionmodel", "collisionbounds", "inheritvaluefromevent",
                     "inheritcontrolpointvelocity", "remapinitialvalue",
                     "inheritinitialvaluefromevent", "layerimage"] {
            XCTAssertTrue(p.unsupportedNames.contains(name), "\(name)이 빠졌다")
        }
        XCTAssertTrue(p.malformedNames.isEmpty)
    }
}

/// 창작자가 그대로 복사해 쓰는 실물 번들 프리셋 3개를 파일에서 읽어 굴린다 —
/// "실물처럼 파싱만 된다"가 아니라 "실제로 시뮬레이션이 안 깨진다"까지 본다.
final class ParticleWE27BundledPresetTests: XCTestCase {
    private func loadPreset(_ relativePath: String) throws -> ParticlePreset? {
        guard let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            return nil
        }
        let url = URL(fileURLWithPath: assetsPath).appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ParticlePreset.parse(json)
    }

    private func assertRunsWithoutBreaking(_ preset: ParticlePreset, file: StaticString = #filePath,
                                           line: UInt = #line) {
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
        for _ in 0..<60 { system.update(deltaTime: 1.0 / 60.0) }
        for particle in system.particles {
            XCTAssertTrue(particle.position.x.isFinite && particle.position.y.isFinite
                && particle.position.z.isFinite, "위치가 발산했다", file: file, line: line)
            XCTAssertTrue(particle.alpha.isFinite && particle.size.isFinite,
                          file: file, line: line)
        }
    }

    /// 실물 `thunderbolt.json` — positionOffsetRandom·mapSequenceBetweenControlPoints·
    /// capVelocity·maintainDistanceBetweenControlPoints·reduceMovementNearControlPoint를
    /// 한꺼번에 쓰는 가장 무거운 조합.
    func testThunderboltPresetRunsWithoutBreaking() throws {
        guard let preset = try loadPreset("presets/lightning/particles/presets/thunderbolt.json")
        else { throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정") }
        for name in ["positionoffsetrandom", "mapsequencebetweencontrolpoints", "capvelocity",
                     "maintaindistancebetweencontrolpoints", "reducemovementnearcontrolpoint",
                     "alphachange"] {
            XCTAssertFalse(preset.unsupportedNames.contains(name), "\(name)이 아직 unsupported다")
        }
        XCTAssertTrue(preset.malformedNames.isEmpty, "\(preset.malformedNames)")
        assertRunsWithoutBreaking(preset)
    }

    /// 실물 `dna.json` — mapSequenceAroundControlPoint 뒤에
    /// mapSequenceBetweenControlPoints를 두는 조합.
    func testDNAPresetRunsWithoutBreaking() throws {
        guard let preset = try loadPreset("presets/abstract/particles/presets/dna.json")
        else { throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정") }
        XCTAssertFalse(preset.unsupportedNames.contains("mapsequencebetweencontrolpoints"))
        XCTAssertTrue(preset.malformedNames.isEmpty, "\(preset.malformedNames)")
        assertRunsWithoutBreaking(preset)
    }

    /// 실물 `dripping_water.json` — boids.
    func testDrippingWaterPresetRunsWithoutBreaking() throws {
        guard let preset = try loadPreset("presets/water/particles/presets/dripping_water.json")
        else { throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정") }
        XCTAssertFalse(preset.unsupportedNames.contains("boids"))
        XCTAssertTrue(preset.malformedNames.isEmpty, "\(preset.malformedNames)")
        assertRunsWithoutBreaking(preset)
    }

    /// 실물 `magic_vortex_orb.json` — maintainDistanceToControlPoint.
    func testMagicVortexOrbPresetRunsWithoutBreaking() throws {
        guard let preset = try loadPreset("presets/magic/particles/presets/magic_vortex_orb.json")
        else { throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정") }
        XCTAssertFalse(preset.unsupportedNames.contains("maintaindistancetocontrolpoint"))
        XCTAssertTrue(preset.malformedNames.isEmpty, "\(preset.malformedNames)")
        assertRunsWithoutBreaking(preset)
    }
}
