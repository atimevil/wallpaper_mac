import XCTest
@testable import WallflowKit

final class ParticleOverrideTests: XCTestCase {
    private func preset(maxCount: Int = 200) -> ParticlePreset {
        ParticlePreset(
            maxCount: maxCount, startTime: 0, materialPath: "m.json",
            emitters: [.sphereRandom(rate: 20, origin: Vec3(x: 0, y: 0, z: 0),
                                     directions: Vec3(x: 1, y: 0, z: 0),
                                     distanceMin: 10, distanceMax: 100)],
            initializers: [.lifetimeRandom(min: 5, max: 10),
                           .sizeRandom(min: 20, max: 50),
                           .velocityRandom(min: Vec3(x: -100, y: -100, z: 0),
                                           max: Vec3(x: -50, y: -15, z: 0)),
                           .colorRandom(min: Vec3(x: 1, y: 1, z: 1),
                                        max: Vec3(x: 1, y: 0.5, z: 0.5))],
            operators: [], unsupportedNames: [], malformedNames: [])
    }

    /// 실물 Hiyuki의 벚꽃은 count가 0.05다. 프리셋 200장 중 10장만 원한다.
    /// 무시하면 스무 배로 뿌린다.
    func testCountMultiplierReducesParticles() {
        var o = ParticleOverride()
        o.count = 0.05
        XCTAssertEqual(preset().applying(o).maxCount, 10)
    }

    /// 배율이 아주 작아도 하나는 남긴다. 0이 되면 씬이 의도한 "드물게"가
    /// 아니라 "없음"이 된다.
    func testTinyCountKeepsAtLeastOne() {
        var o = ParticleOverride()
        o.count = 0.0001
        XCTAssertEqual(preset(maxCount: 10).applying(o).maxCount, 1)
    }

    /// 개수 배율이 커도 시뮬레이션 상한을 넘지 않는다. 파일에서 온 값이다.
    func testCountRespectsSimulationCap() {
        var o = ParticleOverride()
        o.count = 100
        XCTAssertLessThanOrEqual(
            preset(maxCount: 8000).applying(o).maxCount, ParticlePreset.maxAllowedCount)
    }

    func testRateSizeSpeedLifetimeMultiply() throws {
        var o = ParticleOverride()
        o.rate = 0.5; o.size = 2; o.speed = 3; o.lifetime = 0.5
        let p = preset().applying(o)
        guard case .sphereRandom(let rate, _, _, let lo, let hi) = p.emitters[0] else {
            return XCTFail("sphererandom이어야 한다")
        }
        XCTAssertEqual(rate, 10, accuracy: 0.001)
        // **뿌리는 범위는 배율을 따르지 않는다.** 공식 문서가 못박고 있다 —
        // "All factors are multiplied with the initializers and operators of your
        // particle system"(IParticleSystemInstance). 이미터는 그 목록에 없다.
        //
        // 한동안 크기 배율을 범위에까지 곱했는데, 그러면 비가 화면 일부에만 내린다
        // (실물에서 반경 1024가 0.65배로 줄어 가로 3분의 2에만 왔다).
        XCTAssertEqual(lo, 10, accuracy: 0.001)
        XCTAssertEqual(hi, 100, accuracy: 0.001)
        guard case .lifetimeRandom(let la, let lb) = p.initializers[0],
              case .sizeRandom(let sa, let sb) = p.initializers[1],
              case .velocityRandom(let va, _) = p.initializers[2] else {
            return XCTFail("초기화자 순서가 유지되어야 한다")
        }
        XCTAssertEqual(la, 2.5, accuracy: 0.001)
        XCTAssertEqual(lb, 5, accuracy: 0.001)
        XCTAssertEqual(sa, 40, accuracy: 0.001)
        XCTAssertEqual(sb, 100, accuracy: 0.001)
        XCTAssertEqual(va.x, -300, accuracy: 0.001)
    }

    /// colorn이 있으면 프리셋의 색 범위를 버리고 그 색으로 고정한다.
    func testColorOverrideReplacesRange() throws {
        var o = ParticleOverride()
        o.color = Vec3(x: 0.2, y: 0.4, z: 0.6)
        guard case .colorRandom(let a, let b) = preset().applying(o).initializers[3] else {
            return XCTFail("colorrandom이어야 한다")
        }
        XCTAssertEqual(a, Vec3(x: 0.2, y: 0.4, z: 0.6))
        XCTAssertEqual(b, Vec3(x: 0.2, y: 0.4, z: 0.6))
    }

    /// 아무것도 안 바꾸면 프리셋을 그대로 쓴다.
    func testIdentityLeavesPresetAlone() {
        let p = preset()
        XCTAssertEqual(p.applying(ParticleOverride()), p)
    }

    /// 실물 모양 그대로 읽는다. alpha는 스크립트 객체로 오기도 한다.
    func testParsesRealShape() {
        let o = ParticleOverride.parse([
            "id": 49, "count": 0.46, "rate": 0.75, "size": 1.17, "speed": 1.66,
            "lifetime": 0.9, "alpha": ["user": "newproperty3", "value": 0.84],
            "colorn": "1.00000 0.70980 0.00784",
        ])
        XCTAssertEqual(o.count, 0.46, accuracy: 0.001)
        XCTAssertEqual(o.speed, 1.66, accuracy: 0.001)
        XCTAssertEqual(o.alpha, 0.84, accuracy: 0.001, "스크립트 객체의 value를 써야 한다")
        XCTAssertEqual(o.color?.y ?? 0, 0.7098, accuracy: 0.001)
    }

    /// 파일에서 온 값이라 이상한 배율은 버리고 1로 둔다.
    func testAbsurdFactorsAreIgnored() {
        let o = ParticleOverride.parse([
            "count": Double.nan, "rate": -5, "size": 1e9, "speed": "쓰레기",
        ])
        XCTAssertEqual(o.count, 1)
        XCTAssertEqual(o.rate, 1)
        XCTAssertEqual(o.size, 1)
        XCTAssertEqual(o.speed, 1)
    }
}
