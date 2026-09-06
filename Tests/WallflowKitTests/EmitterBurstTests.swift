import XCTest
@testable import WallflowKit

/// 이미터가 주는 두 가지 — 시작할 때의 한꺼번에 방출과 초기 속력.
///
/// 이 둘이 없으면 **실물 불꽃놀이가 통째로 안 보인다.** 그 프리셋은 `rate: 0`이고
/// 속도 초기화자도 없어서, 터뜨리는 것도 날리는 것도 전부 이미터가 한다.
final class EmitterBurstTests: XCTestCase {
    /// 실물 `fireworks2hit`의 이미터 모양 그대로.
    private func fireworksPreset() -> ParticlePreset? {
        let json = """
        {"maxcount": 300, "material": "m",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 150,
                      "origin": "0 0 0", "directions": "1 1 0",
                      "distancemin": 0, "distancemax": 16, "speedmax": 1100}],
         "initializer": [{"name": "lifetimerandom", "min": 0.5, "max": 1.5},
                         {"name": "sizerandom", "min": 5, "max": 10}]}
        """
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any] else { return nil }
        return ParticlePreset.parse(object)
    }

    func testParsesBurstAndSpeed() throws {
        let preset = try XCTUnwrap(fireworksPreset())
        let burst = preset.emitters[0].burst
        XCTAssertEqual(burst.count, 150)
        XCTAssertEqual(burst.speedMax, 1100, accuracy: 0.001)
        XCTAssertEqual(burst.speedMin, 0, accuracy: 0.001)
    }

    /// `rate: 0`이면 한꺼번에 방출이 **유일한** 출처다.
    /// 이걸 안 하면 불꽃이 하나도 안 나온다.
    func testBurstEmitsEvenWhenRateIsZero() throws {
        let preset = try XCTUnwrap(fireworksPreset())
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.update(deltaTime: 1.0 / 60)
        XCTAssertEqual(system.particles.filter(\.isAlive).count, 150)
    }

    /// 한 번만 터진다. 매 프레임 터지면 불꽃이 끝없이 쏟아진다.
    func testBurstHappensOnlyOnce() throws {
        let preset = try XCTUnwrap(fireworksPreset())
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        for _ in 0..<10 { system.update(deltaTime: 1.0 / 60) }
        // 수명이 0.5~1.5초라 0.17초 뒤에는 아직 아무도 안 죽었다.
        XCTAssertEqual(system.particles.filter(\.isAlive).count, 150)
    }

    /// 이미터 속력이 파티클을 **바깥으로** 날린다. 이게 없으면 불꽃이
    /// 한 점에 뭉쳐 그대로 떨어진다.
    func testEmitterSpeedPushesParticlesOutward() throws {
        let preset = try XCTUnwrap(fireworksPreset())
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 2))
        system.update(deltaTime: 1.0 / 60)
        let alive = system.particles.filter(\.isAlive)
        let speeds = alive.map {
            ($0.velocity.x * $0.velocity.x + $0.velocity.y * $0.velocity.y).squareRoot()
        }
        XCTAssertFalse(speeds.isEmpty)
        XCTAssertGreaterThan(speeds.max() ?? 0, 100, "바깥으로 날아가야 한다")
        XCTAssertLessThanOrEqual(speeds.max() ?? 0, 1100.001, "최대 속력을 넘지 않는다")
        // 방향이 제각각이어야 원형으로 퍼진다. 전부 같으면 한 줄기로 나간다.
        let angles = Set(alive.map { Int(atan2($0.velocity.y, $0.velocity.x) * 4) })
        XCTAssertGreaterThan(angles.count, 4, "사방으로 퍼져야 한다")
    }

    /// 속도 초기화자가 있으면 그것이 이긴다. 초기화자가 이미터 위에 얹힌다.
    func testVelocityInitializerWinsOverEmitterSpeed() throws {
        let json = """
        {"maxcount": 10, "material": "m",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 5,
                      "distancemax": 10, "speedmax": 900}],
         "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5},
                         {"name": "velocityrandom", "min": "0 -7 0", "max": "0 -7 0"}]}
        """
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 3))
        system.update(deltaTime: 1.0 / 60)
        for particle in system.particles.filter(\.isAlive) {
            XCTAssertEqual(particle.velocity.y, -7, accuracy: 0.001)
            XCTAssertEqual(particle.velocity.x, 0, accuracy: 0.001)
        }
    }

    /// 파일에서 온 값이다. 터무니없는 개수로 반복문을 돌면 안 된다.
    func testAbsurdBurstCountIsClamped() throws {
        let json = """
        {"maxcount": 4, "material": "m",
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 999999999,
                      "distancemax": "10 10 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}]}
        """
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertLessThanOrEqual(preset.emitters[0].burst.count, ParticlePreset.maxAllowedCount)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 4))
        system.update(deltaTime: 1.0 / 60)
        // 버퍼가 4개뿐이라 그 이상은 나올 수 없다.
        XCTAssertEqual(system.particles.filter(\.isAlive).count, 4)
    }

    /// 음수나 비유한값은 없는 것으로 본다.
    func testNegativeAndNonFiniteAreIgnored() throws {
        let json = """
        {"maxcount": 4, "material": "m",
         "emitter": [{"name": "boxrandom", "rate": 5, "instantaneous": -3,
                      "speedmin": -100, "distancemax": "10 10 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}]}
        """
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.emitters[0].burst.count, 0)
        XCTAssertEqual(preset.emitters[0].burst.speedMin, 0, accuracy: 0.001)
    }
}
