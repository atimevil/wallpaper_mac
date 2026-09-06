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

/// 수명에 따라 크기와 투명도를 바꾸는 연산자들.
///
/// 시각은 **초가 아니라 수명 대비 비율**이다. 실물 `rain_splashes_droplets`는
/// 수명이 0.3~0.5초인데 `fadeouttime: 0.9`를 적는다 — 초로 읽으면 태어나기도
/// 전에 사라져야 하므로 비율이 유일하게 말이 된다.
final class ParticleLifetimeCurveTests: XCTestCase {
    private static let step = 1.0 / 64.0

    private func preset(
        initializers: [ParticleInitializer],
        operators: [ParticleOperator]
    ) -> ParticlePreset {
        // 시작할 때 한 개만 뿌린다. 나이가 하나뿐이라 곡선을 그대로 읽을 수 있다.
        let emitter = ParticleEmitter.sphereRandom(
            rate: 0, origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 0, z: 0),
            distanceMin: 0, distanceMax: 0,
            burst: ParticleEmitterBurst(count: 1, speedMin: 0, speedMax: 0))
        return ParticlePreset(
            maxCount: 4, startTime: 0, materialPath: "m.json", emitters: [emitter],
            initializers: initializers, operators: operators, unsupportedNames: [])
    }

    /// 수명의 몇 할이 지난 시점의 파티클 하나. 시스템은 매번 새로 만든다 —
    /// 하나를 여러 번 되감을 수는 없다.
    private func particle(
        _ make: () -> ParticleSystem, at progress: Double, lifetime: Double
    ) throws -> Particle {
        let system = make()
        let target = progress * lifetime
        var elapsed = 0.0
        while elapsed + Self.step <= target + 1e-9 {
            system.update(deltaTime: Self.step)
            elapsed += Self.step
        }
        return try XCTUnwrap(system.particles.first)
    }

    // MARK: alphafade

    /// 수명이 짧아도 `fadeouttime: 0.9`는 **끝의 10%**를 뜻한다.
    /// 초로 읽으면 이 파티클은 태어나자마자 투명해진다.
    func testFadeOutIsAFractionOfLifetime() throws {
        let lifetime = 0.4
        let make = {
            ParticleSystem(
                preset: self.preset(
                    initializers: [.lifetimeRandom(min: lifetime, max: lifetime)],
                    operators: [.alphaFade(fadeInTime: 0, fadeOutTime: 0.9)]),
                random: FixedRandom([0.5]))
        }
        let middle = try particle(make, at: 0.5, lifetime: lifetime)
        XCTAssertEqual(middle.alpha, 1.0, accuracy: 0.001, "절반 지점은 아직 온전해야 한다")
        let late = try particle(make, at: 0.99, lifetime: lifetime)
        XCTAssertLessThan(late.alpha, 0.7)
        XCTAssertGreaterThan(late.alpha, 0.2)
    }

    /// 페이드는 `alpharandom`이 정한 값에 **곱한다**. 덮어쓰면 반투명하게
    /// 그리라던 프리셋이 전부 불투명해진다.
    func testFadeMultipliesInitialAlpha() throws {
        let lifetime = 1.0
        let make = {
            ParticleSystem(
                preset: self.preset(
                    initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                                   .alphaRandom(min: 0.5, max: 0.5)],
                    operators: [.alphaFade(fadeInTime: 0.2, fadeOutTime: 1)]),
                random: FixedRandom([0.5]))
        }
        let middle = try particle(make, at: 0.5, lifetime: lifetime)
        XCTAssertEqual(middle.alpha, 0.5, accuracy: 0.001)
    }

    // MARK: sizechange

    /// 기본값은 처음 크기에서 0까지 줄어드는 것이다.
    func testSizeShrinksOverLifetime() throws {
        let lifetime = 1.0
        let make = {
            ParticleSystem(
                preset: self.preset(
                    initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                                   .sizeRandom(min: 100, max: 100)],
                    operators: [.sizeChange(startTime: 0, endTime: 1,
                                            startValue: 1, endValue: 0)]),
                random: FixedRandom([0.5]))
        }
        let middle = try particle(make, at: 0.5, lifetime: lifetime)
        // 곡선 위에 있는지를 본다. 연산자는 나이를 더하기 **전에** 돌므로
        // 한 프레임(=step)만큼 앞선 값이 나온다.
        XCTAssertEqual(middle.size, 100 * (1 - middle.age / lifetime),
                       accuracy: 100 * Self.step + 0.01)
        XCTAssertEqual(middle.size, 50, accuracy: 3)
    }

    /// 실물 불꽃 섬광은 커지는 것과 작아지는 것 **둘**을 함께 건다.
    /// 곱해지지 않으면 1200px짜리 원반이 수명 내내 그대로 떠 있다.
    func testTwoCurvesMultiply() throws {
        let lifetime = 1.0
        let make = {
            ParticleSystem(
                preset: self.preset(
                    initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                                   .sizeRandom(min: 100, max: 100)],
                    // 실물 fireworks2flare 그대로: 앞 절반에 0→1, 뒤 절반에 1→0.
                    operators: [.sizeChange(startTime: 0.5, endTime: 1,
                                            startValue: 1, endValue: 0),
                                .sizeChange(startTime: 0, endTime: 0.5,
                                            startValue: 0, endValue: 1)]),
                random: FixedRandom([0.5]))
        }
        let start = try particle(make, at: 0.05, lifetime: lifetime)
        let middle = try particle(make, at: 0.5, lifetime: lifetime)
        let end = try particle(make, at: 0.95, lifetime: lifetime)
        XCTAssertLessThan(start.size, 20, "태어날 때는 거의 점이어야 한다")
        XCTAssertEqual(middle.size, 100, accuracy: 5, "가운데가 가장 크다")
        XCTAssertLessThan(end.size, 20, "꺼질 때도 거의 점이어야 한다")
    }

    /// 같은 시점이면 프레임을 몇 번에 나눠 갔든 크기가 같아야 한다.
    /// 직전 값에 곱하면 프레임마다 복리로 줄어들어, 주사율이 다른 화면에서
    /// 같은 배경화면이 다르게 보인다.
    func testCurveDoesNotCompoundAcrossFrames() throws {
        func measure(step: Double) throws -> (size: Double, age: Double) {
            let system = ParticleSystem(
                preset: preset(
                    initializers: [.lifetimeRandom(min: 1, max: 1),
                                   .sizeRandom(min: 100, max: 100)],
                    operators: [.sizeChange(startTime: 0, endTime: 1,
                                            startValue: 1, endValue: 0)]),
                random: FixedRandom([0.5]))
            var elapsed = 0.0
            while elapsed + step <= 0.5 + 1e-9 {
                system.update(deltaTime: step)
                elapsed += step
            }
            let particle = try XCTUnwrap(system.particles.first)
            return (particle.size, particle.age)
        }
        // 프레임 수가 16배 달라도 크기는 나이만의 함수여야 한다. 직전 값에
        // 곱하면 잘게 쪼갠 쪽이 복리로 줄어 0에 가까워진다.
        for step in [1.0 / 128, 1.0 / 8] {
            let m = try measure(step: step)
            XCTAssertEqual(m.size, 100 * (1 - m.age), accuracy: 100 * step + 0.01,
                           "step \(step)에서 곡선을 벗어났다")
        }
    }

    /// 실물 프리셋 그대로 읽는다. 필드 이름이 하나라도 어긋나면 여기서 걸린다.
    func testParsesRealFlareOperators() throws {
        let json = """
        {"maxcount": 4, "material": "m.json",
         "operator": [{"name": "alphafade"},
                      {"name": "sizechange", "starttime": 0.5},
                      {"name": "sizechange", "endtime": 0.5,
                       "endvalue": 1, "startvalue": 0}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.operators.count, 3)
        XCTAssertTrue(preset.unsupportedNames.isEmpty)
        guard case .sizeChange(let startTime, let endTime, let startValue, let endValue)
            = preset.operators[1] else { return XCTFail("sizechange여야 한다") }
        XCTAssertEqual(startTime, 0.5)
        XCTAssertEqual(endTime, 1, "안 적으면 수명 끝이다")
        XCTAssertEqual(startValue, 1, "안 적으면 처음 크기 그대로다")
        XCTAssertEqual(endValue, 0, "안 적으면 0까지 줄어든다")
    }
}
