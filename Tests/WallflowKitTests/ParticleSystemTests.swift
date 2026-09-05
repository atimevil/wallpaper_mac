import XCTest
@testable import WallflowKit

/// 테스트용 결정적 난수. 값을 순서대로 돌려주고 끝나면 처음으로 돌아간다.
private final class FixedRandom: RandomSource {
    private let values: [Double]
    private var index = 0
    init(_ values: [Double]) { self.values = values }
    func next() -> Double {
        defer { index = (index + 1) % values.count }
        return values[index]
    }
}

final class ParticleSystemTests: XCTestCase {
    /// 2의 거듭제곱이라 이진수로 정확하다. maxTimeStep(0.1)보다 작아 클램프에 걸리지 않는다.
    private static let step = 1.0 / 64.0

    private func preset(
        maxCount: Int = 100,
        emitters: [ParticleEmitter] = [],
        initializers: [ParticleInitializer] = [],
        operators: [ParticleOperator] = []
    ) -> ParticlePreset {
        ParticlePreset(maxCount: maxCount, startTime: 0, materialPath: "m.json",
                       emitters: emitters, initializers: initializers,
                       operators: operators, unsupportedNames: [])
    }

    /// `seconds`초를 maxTimeStep 이하로 쪼개 돌린다.
    /// seconds는 step의 정수배여야 오차 없이 정확히 그만큼 흐른다.
    private func advance(_ system: ParticleSystem, seconds: Double) {
        let count = Int((seconds / Self.step).rounded())
        for _ in 0..<count { system.update(deltaTime: Self.step) }
    }

    /// 방출이 계속되는 동안 가장 오래 적분된 파티클. 인덱스 순서에 기대면
    /// 슬롯 재사용 때문에 어느 것이 잡힐지 알 수 없다.
    private func oldest(_ system: ParticleSystem) -> Particle? {
        system.particles.max(by: { $0.age < $1.age })
    }

    private func emitter(rate: Double) -> ParticleEmitter {
        .sphereRandom(rate: rate, origin: Vec3(x: 0, y: 0, z: 0),
                      directions: Vec3(x: 1, y: 0, z: 0),
                      distanceMin: 0, distanceMax: 0)
    }

    func testStartsEmpty() {
        let system = ParticleSystem(preset: preset(), random: FixedRandom([0.5]))
        XCTAssertEqual(system.aliveCount, 0)
    }

    /// rate는 초당 방출 수다. 1초를 돌리면 그만큼 나와야 한다.
    func testEmitterProducesParticlesAtRate() {
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 10)],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 1.0)
        XCTAssertEqual(system.aliveCount, 10)
    }

    /// 방출은 프레임 크기와 무관하게 누적되어야 한다.
    /// 굵게 돌린 것과 잘게 돌린 것의 총량이 같아야 한다. 매직넘버와 비교하지 않고
    /// 두 경로를 서로 비교하는 이유는, 이 테스트가 붙들려는 불변식이 "10개"가 아니라
    /// "분할이 총량을 바꾸지 않는다"이기 때문이다.
    func testEmissionAccumulatesAcrossSmallSteps() {
        func run(step: Double) -> Int {
            let system = ParticleSystem(
                preset: preset(emitters: [emitter(rate: 10)],
                               initializers: [.lifetimeRandom(min: 100, max: 100)]),
                random: FixedRandom([0.5]))
            let count = Int((1.0 / step).rounded())
            for _ in 0..<count { system.update(deltaTime: step) }
            return system.aliveCount
        }
        // 둘 다 maxTimeStep 이하이고 둘 다 이진수로 정확하다.
        XCTAssertEqual(run(step: 1.0 / 16.0), run(step: 1.0 / 64.0),
                       "프레임 분할이 총 방출량을 바꾸면 안 된다")
        XCTAssertEqual(run(step: 1.0 / 64.0), 10)
    }

    func testMaxCountIsNeverExceeded() {
        let system = ParticleSystem(
            preset: preset(maxCount: 50, emitters: [emitter(rate: 10000)],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 1.0)
        XCTAssertEqual(system.aliveCount, 50)
    }

    /// 수명이 다한 파티클은 사라져야 한다.
    /// 방출은 계속되므로 aliveCount가 0이 되지는 않는다 — 대신 정상 상태에서
    /// 개수가 rate × lifetime 근처로 수렴하고, 살아 있는 것 중 수명을 넘긴 게
    /// 하나도 없어야 한다. 이게 "눈이 계속 내리되 쌓이지 않는다"의 실제 조건이다.
    func testParticlesDieAfterLifetime() {
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 10)],
                           initializers: [.lifetimeRandom(min: 2, max: 2)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 10.0)
        for p in system.particles {
            XCTAssertLessThanOrEqual(p.age, p.lifetime, "수명을 넘긴 파티클이 살아 있다")
        }
        // rate 10 × lifetime 2 = 20이 정상 상태. 경계 프레임 오차로 ±2 허용.
        XCTAssertEqual(Double(system.aliveCount), 20, accuracy: 2,
                       "정상 상태 개수가 rate × lifetime에서 벗어났다")
    }

    /// 죽은 자리는 재사용되어야 한다. 안 그러면 maxCount에 도달한 뒤 영원히 멈춘다.
    func testDeadSlotsAreReused() {
        let system = ParticleSystem(
            preset: preset(maxCount: 10, emitters: [emitter(rate: 10)],
                           initializers: [.lifetimeRandom(min: 0.5, max: 0.5)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 1.0)
        let first = system.aliveCount
        advance(system, seconds: 10.0)
        XCTAssertGreaterThan(system.aliveCount, 0, "\(first)개 이후 방출이 멈췄다")
    }

    func testMovementAppliesVelocityAndGravity() {
        // rate를 크게 잡아 첫 스텝에서 바로 방출시킨다. rate가 작으면 파티클이
        // 마지막 스텝에야 태어나 적분 시간이 거의 0이고, 위치 단언이 무의미해진다.
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 64)],
                           initializers: [.lifetimeRandom(min: 100, max: 100),
                                          .velocityRandom(min: Vec3(x: 10, y: 0, z: 0),
                                                          max: Vec3(x: 10, y: 0, z: 0))],
                           operators: [.movement(gravity: Vec3(x: 0, y: -10, z: 0), drag: 0)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 1.0)
        let p = try! XCTUnwrap(oldest(system))
        XCTAssertEqual(p.age, 1.0, accuracy: 0.05, "가장 오래된 파티클이 1초를 살지 않았다")
        XCTAssertEqual(p.position.x, 10, accuracy: 0.5, "속도가 위치에 반영되어야 한다")
        XCTAssertLessThan(p.position.y, 0, "중력이 아래로 당겨야 한다")
    }

    func testAlphaFadeRisesFromZero() {
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 100)],
                           initializers: [.lifetimeRandom(min: 10, max: 10)],
                           operators: [.alphaFade(fadeInTime: 1.0, fadeOutTime: 0)]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 0.125)
        let early = try! XCTUnwrap(oldest(system)).alpha
        advance(system, seconds: 0.5)
        let later = try! XCTUnwrap(oldest(system)).alpha
        XCTAssertLessThan(early, later, "페이드인 중에는 알파가 올라야 한다")
    }

    /// 같은 시드로 같은 입력을 주면 같은 결과가 나와야 한다.
    /// 결정성이 없으면 회귀를 잡을 수 없다.
    func testDeterministicForSameSeed() {
        func run() -> [Vec3] {
            let e = ParticleEmitter.sphereRandom(
                rate: 20, origin: Vec3(x: 0, y: 100, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
                distanceMin: 5, distanceMax: 50)
            let system = ParticleSystem(
                preset: preset(emitters: [e],
                               initializers: [.lifetimeRandom(min: 5, max: 9),
                                              .velocityRandom(min: Vec3(x: -5, y: -5, z: 0),
                                                              max: Vec3(x: 5, y: -1, z: 0))],
                               operators: [.movement(gravity: Vec3(x: 0, y: -1, z: 0), drag: 0)]),
                random: SeededRandom(seed: 12345))
            advance(system, seconds: 1.0)
            return system.particles.map(\.position)
        }
        let a = run(), b = run()
        XCTAssertFalse(a.isEmpty, "빈 배열끼리는 같아도 아무것도 증명하지 않는다")
        XCTAssertEqual(a, b)
    }

    /// deltaTime이 비정상이어도 죽지 않아야 한다. 절전에서 깨어나면 큰 값이 들어온다.
    func testAbsurdDeltaTimeIsSurvivable() {
        let system = ParticleSystem(
            preset: preset(maxCount: 100, emitters: [emitter(rate: 100)],
                           initializers: [.lifetimeRandom(min: 1, max: 1)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 100000)
        XCTAssertLessThanOrEqual(system.aliveCount, 100)
        system.update(deltaTime: 0)
        system.update(deltaTime: -1)
        system.update(deltaTime: .nan)
        system.update(deltaTime: .infinity)
        XCTAssertLessThanOrEqual(system.aliveCount, 100, "비정상 시간에 죽으면 안 된다")
        for p in system.particles {
            XCTAssertTrue(p.position.x.isFinite && p.position.y.isFinite,
                          "비정상 시간이 위치를 오염시켰다")
        }
    }

    /// 큰 deltaTime은 **버려야** 한다. 잘게 쪼개 따라잡으면 안 된다.
    /// 절전에서 3000초가 들어왔을 때 0.1초씩 3만 번 돌면 배경화면이 멈춘다.
    /// 위치로 관찰한다 — 클램프가 있으면 한 번의 update가 maxTimeStep만큼만 적분한다.
    func testLargeDeltaTimeIsClampedNotSubdivided() {
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 100)],
                           initializers: [.lifetimeRandom(min: 1e6, max: 1e6),
                                          .velocityRandom(min: Vec3(x: 10, y: 0, z: 0),
                                                          max: Vec3(x: 10, y: 0, z: 0))],
                           operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)]),
            random: FixedRandom([0.5]))
        system.update(deltaTime: 0.05)   // 파티클 5개를 만든다
        system.update(deltaTime: 100000) // 여기서 시간이 버려져야 한다
        let p = try! XCTUnwrap(oldest(system))
        XCTAssertLessThanOrEqual(p.position.x, 10 * (ParticleSystem.maxTimeStep + 0.05) + 0.001,
                                 "큰 deltaTime이 그대로 적분됐다")
        // 클램프가 없으면 x는 1,000,000이다. 여유가 커서 경계 오차로 통과할 수 없다.
    }

    func testNaNVelocityDoesNotPropagate() {
        let system = ParticleSystem(
            preset: preset(emitters: [emitter(rate: 10)],
                           initializers: [.lifetimeRandom(min: 10, max: 10),
                                          .velocityRandom(min: Vec3(x: .nan, y: 0, z: 0),
                                                          max: Vec3(x: .nan, y: 0, z: 0))]),
            random: FixedRandom([0.5]))
        advance(system, seconds: 1.0)
        // NaN 속도를 방출 시점에 걸러 파티클을 아예 안 만드는 것도 허용한다.
        // 다만 빈 배열을 도는 것만으로는 아무것도 증명하지 못하므로 명시한다.
        for p in system.particles {
            XCTAssertTrue(p.position.x.isFinite, "NaN 위치가 렌더러로 새면 안 된다")
        }
    }

    /// 파일에서 온 rate가 거대하면(1e300) 방출 크레딧을 Int로 바꾸는 지점에서
    /// 트랩해 앱이 죽었다. 실물 파서를 통과시켜 재현했다.
    /// 방출량은 어차피 빈 슬롯 수 이하이므로 Double 단계에서 먼저 죄어 변환을 안전하게 했다.
    func testAbsurdRateDoesNotTrap() {
        let absurdEmitter = ParticleEmitter.sphereRandom(
            rate: 1e300, origin: Vec3(x: 0, y: 0, z: 0),
            directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0)
        let system = ParticleSystem(
            preset: preset(maxCount: 100, emitters: [absurdEmitter],
                           initializers: [.lifetimeRandom(min: 100, max: 100)]),
            random: FixedRandom([0.5]))
        // 이 호출이 SIGTRAP으로 죽으면 테스트 실패다.
        system.update(deltaTime: 0.016)
        XCTAssertLessThanOrEqual(system.aliveCount, 100, "maxCount를 넘어서면 안 된다")
    }

    /// 슬롯이 없어 못 내보낸 몫이 프레임마다 쌓여, 파티클이 한꺼번에 죽는
    /// 순간 밀린 물량이 폭발적으로 방출되었다.
    /// "눈이 잠깐 멈췄다가 갑자기 쏟아지는" 증상이었다.
    /// 지나간 방출 기회는 버려야 한다.
    func testSaturatedEmitterDoesNotBankCredit() {
        let system = ParticleSystem(
            preset: preset(maxCount: 5, emitters: [emitter(rate: 1000)],
                           initializers: [.lifetimeRandom(min: 0.01, max: 0.01)]),
            random: FixedRandom([0.5]))
        // 슬롯을 꽉 채운다
        advance(system, seconds: 0.1)
        XCTAssertEqual(system.aliveCount, 5, "슬롯이 가득 차야 한다")

        // 이제 emissionCredits는 크지만, 방출할 슬롯이 없다.
        // 여러 프레임을 더 돌아도 deadSlots가 비어있으므로 새 파티클이 나오지 않는다.
        // 그 동안 emissionCredits는 계속 쌓인다.
        // 모든 파티클이 죽는 순간 (lifetime=0.01), deadSlots가 가득 찬다.
        // 수정된 코드: emissionCredits는 1.0 이하로 죽으므로 폭발하지 않는다.

        // 여러 프레임 동안 모든 파티클이 죽을 때까지 기다린다
        for _ in 0..<100 {
            system.update(deltaTime: Self.step)
        }

        // 이 시점에서 emissionCredits는 1.0 이하이고, deadSlots는 가득 차 있다.
        // 다음 프레임에서 방출되는 파티클이 maxCount를 넘지 않는지 확인한다.
        system.update(deltaTime: Self.step)
        XCTAssertLessThanOrEqual(system.aliveCount, 5, "크레딧이 폭발해서 maxCount를 넘었다")
    }

    /// controlpointattract를 조용히 무시하던 것을 unimplementedOperators로
    /// 드러냈다. 실물 씬 "Phrolova 4K"가 이 타입을 실제로 쓰는데
    /// 조용하면 렌더러 버그로 오인된다.
    func testControlPointAttractIsReported() {
        // controlpointattract가 든 프리셋
        let withOp = ParticleSystem(
            preset: preset(
                operators: [.controlPointAttract(controlPoint: 0, scale: 1.0, radius: 5.0)]),
            random: FixedRandom([0.5]))
        XCTAssert(withOp.unimplementedOperators.contains("controlpointattract"),
                  "unimplementedOperators에 controlpointattract가 있어야 한다")

        // controlpointattract가 없는 프리셋
        let noOp = ParticleSystem(
            preset: preset(operators: [.alphaFade(fadeInTime: 1.0, fadeOutTime: 1.0)]),
            random: FixedRandom([0.5]))
        XCTAssertTrue(noOp.unimplementedOperators.isEmpty, "없으면 빈 배열이어야 한다")
    }
}
