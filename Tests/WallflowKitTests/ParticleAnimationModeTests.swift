import XCTest
@testable import WallflowKit

/// 스프라이트 시트를 훑을지, 한 장을 골라 고정할지.
///
/// 화면에 맺힌 빗방울 프리셋은 전부 `animationmode: randomframe`이다.
/// 훑으면 방울이 사는 2초 동안 16장을 오가며 **모양을 바꾸고 깜빡인다**.
final class ParticleAnimationModeTests: XCTestCase {
    func testParsesTheModeFromTheFile() {
        XCTAssertEqual(ParticleAnimationMode.parse("randomframe"), .randomFrame)
        // `null`이거나 없으면 훑는 쪽이 기본이다 — 실물 프리셋 대부분이 null이다.
        XCTAssertEqual(ParticleAnimationMode.parse(nil), .sequence)
        XCTAssertEqual(ParticleAnimationMode.parse(NSNull()), .sequence)
        XCTAssertEqual(ParticleAnimationMode.parse("sequence"), .sequence)
        // 모르는 값은 기본으로. 파일에서 온 문자열이라 무엇이든 올 수 있다.
        XCTAssertEqual(ParticleAnimationMode.parse("무엇이든"), .sequence)
    }

    /// 실물 `rain_screen_fast_4k` 프리셋의 모양 그대로.
    func testRealRainPresetIsRandomFrame() throws {
        let json = """
        {"animationmode": "randomframe", "maxcount": 28,
         "material": "materials/particle/water/rain_drops_sheet.json",
         "emitter": [{"name": "boxrandom", "rate": 1}],
         "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}]}
        """
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let preset = ParticlePreset.parse(object)
        XCTAssertEqual(preset?.animationMode, .randomFrame)
    }

    /// 프레임을 고르는 씨앗은 태어날 때 정해지고 **사는 동안 바뀌지 않는다.**
    /// 매 프레임 새로 뽑으면 고정이 아니라 난수 깜빡임이 된다.
    func testFrameSeedIsStableOverLifetime() {
        let preset = ParticlePreset(
            maxCount: 4, startTime: 0, materialPath: "m",
            emitters: [.boxRandom(rate: 50, origin: Vec3(x: 0, y: 0, z: 0),
                                  directions: Vec3(x: 1, y: 1, z: 1),
                                  distanceMin: Vec3(x: 0, y: 0, z: 0),
                                  distanceMax: Vec3(x: 1, y: 1, z: 1))],
            initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], unsupportedNames: [], animationMode: .randomFrame)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
        // 방출은 1개 단위라 몇 프레임 돌려야 나온다(rate 50이면 60분의 1초에 0.83개).
        for _ in 0..<5 { system.update(deltaTime: 1.0 / 60) }
        let first = system.particles.filter(\.isAlive).map(\.frameSeed)
        XCTAssertFalse(first.isEmpty, "파티클이 나와야 한다")
        for _ in 0..<30 { system.update(deltaTime: 1.0 / 60) }
        let later = system.particles.filter(\.isAlive).map(\.frameSeed)
        XCTAssertEqual(Array(first.prefix(later.count)), Array(later.prefix(first.count)))
    }

    /// 씨앗이 파티클마다 달라야 방울 모양이 섞인다. 전부 같으면 한 장만 나온다.
    func testFrameSeedsDifferBetweenParticles() {
        let preset = ParticlePreset(
            maxCount: 16, startTime: 0, materialPath: "m",
            emitters: [.boxRandom(rate: 200, origin: Vec3(x: 0, y: 0, z: 0),
                                  directions: Vec3(x: 1, y: 1, z: 1),
                                  distanceMin: Vec3(x: 0, y: 0, z: 0),
                                  distanceMax: Vec3(x: 1, y: 1, z: 1))],
            initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], unsupportedNames: [], animationMode: .randomFrame)
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 3))
        for _ in 0..<10 { system.update(deltaTime: 1.0 / 60) }
        let seeds = Set(system.particles.filter(\.isAlive).map { Int($0.frameSeed * 16) })
        XCTAssertGreaterThan(seeds.count, 1, "방울이 전부 같은 칸을 쓴다")
    }
}
