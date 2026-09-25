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

    /// 배율은 프리셋에 굽지 않고 `instance`로 들고 간다. 초기화자는 그대로다.
    func testApplyingStoresInstanceAndKeepsInitializers() {
        var o = ParticleOverride()
        o.rate = 0.5; o.size = 2; o.speed = 3; o.lifetime = 0.5
        let p = preset().applying(o)
        XCTAssertEqual(p.instance, o)
        XCTAssertEqual(p.initializers, preset().initializers)
        guard case .sphereRandom(let rate, _, _, let lo, let hi, _, _, _) = p.emitters[0] else {
            return XCTFail("sphererandom이어야 한다")
        }
        // rate는 방출률이 아니다(시뮬레이션 속도). 이미터는 그대로다.
        XCTAssertEqual(rate, 20, accuracy: 0.001)
        // **뿌리는 범위는 배율을 따르지 않는다.** 한동안 크기 배율을 범위에까지
        // 곱했는데, 그러면 비가 화면 일부에만 내린다(실물에서 반경 1024가 0.65배로
        // 줄어 가로 3분의 2에만 왔다).
        XCTAssertEqual(lo, 10, accuracy: 0.001)
        XCTAssertEqual(hi, 100, accuracy: 0.001)
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
            "colorn": "1.00000 0.70980 0.00784", "brightness": 10.0,
        ])
        XCTAssertEqual(o.count, 0.46, accuracy: 0.001)
        XCTAssertEqual(o.speed, 1.66, accuracy: 0.001)
        XCTAssertEqual(o.alpha, 0.84, accuracy: 0.001, "스크립트 객체의 value를 써야 한다")
        XCTAssertEqual(o.color?.y ?? 0, 0.7098, accuracy: 0.001)
        XCTAssertEqual(o.brightness, 10, accuracy: 0.001)
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

    /// 실물 `previewdrippingwater`가 이 모양이다. `controlpointangleN`도 실물에
    /// 있지만 읽는 키가 아니니 자동으로 지나간다 — 깨지지 않는지만 확인한다.
    func testParsesControlPointOverrides() {
        let o = ParticleOverride.parse([
            "controlpoint1": "22.00000 0.00000 0.00000",
            "controlpoint2": "-22.00000 0.00000 0.00000",
            "controlpointangle1": "0.00000 0.00000 -0.52360",
        ])
        XCTAssertEqual(o.controlPoints[1], Vec3(x: 22, y: 0, z: 0))
        XCTAssertEqual(o.controlPoints[2], Vec3(x: -22, y: 0, z: 0))
        XCTAssertNil(o.controlPoints[0])
        XCTAssertFalse(o.isIdentity, "제어점 덮어쓰기가 있으면 identity가 아니다")
    }

    /// 스크립트가 쓴 벡터도 같은 길로 들어온다(`layer.instance.controlpointN`).
    /// 제어점은 자리라 배율의 0~100 규칙 밖이다 — 유한하기만 하면 받는다.
    func testApplyAcceptsControlPointVectors() {
        var o = ParticleOverride()
        o.apply(["controlpoint3": .vector([-500, 20, 30])])
        XCTAssertEqual(o.controlPoints[3], Vec3(x: -500, y: 20, z: 30))
    }

    /// 범위 밖 번호나 우리가 안 읽는 키(controlpointangleN)는 조용히 버린다.
    func testApplyIgnoresBadControlPointKeys() {
        var o = ParticleOverride()
        o.apply(["controlpoint9": .vector([1, 2, 3]), "controlpointangle1": .vector([1, 2, 3])])
        XCTAssertTrue(o.controlPoints.isEmpty)
    }

    /// 스크립트 시작값·발견 둘 다 이 목록을 훑는다(`SceneDocument.scriptHolders`).
    func testScriptKeysIncludeAllEightControlPoints() {
        for id in 0...7 {
            XCTAssertTrue(ParticleOverride.scriptKeys.contains("controlpoint\(id)"))
        }
    }
}
