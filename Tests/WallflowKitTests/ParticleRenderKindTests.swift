import XCTest
@testable import WallflowKit

/// 프리셋의 `renderer` 해석. `spritetrail`/`rope`/`ropetrail`이 점으로만 나오는
/// 결함(오브 꼬리·소용돌이 궤적·빗줄기)의 원인 — 지금까지 이 필드를 통째로
/// 무시했다.
final class ParticleRenderKindTests: XCTestCase {
    private func preset(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// `renderer`가 없으면 기본이 sprite다.
    func testMissingRendererDefaultsToSprite() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
    }

    func testParsesExplicitSprite() throws {
        // 실물 examplecursoravoid.json 그대로.
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"sprite"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
    }

    /// 실물 rain_screen_4k.json 그대로 — length/maxlength/minlength 세 필드가
    /// 다 있는 유일한 실물 spritetrail이다(다른 예제들은 minlength가 없다).
    func testParsesRealRainSpriteTrail() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":11,"length":0.0099999998,"maxlength":1.5,
                      "minlength":1,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(let length, let maxLength, let minLength) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(length, 0.0099999998, accuracy: 1e-9)
        XCTAssertEqual(maxLength, 1.5)
        XCTAssertEqual(minLength, 1)
    }

    /// 실물 exampleturbolence.json은 minlength가 없다 — 0으로 본다(clamp
    /// 아래쪽이 없으면 속도 0에 가까울 때 트레일이 그냥 사라지는 쪽이,
    /// 안 적힌 값을 지어내는 것보다 낫다).
    func testSpriteTrailMissingMinLengthDefaultsToZero() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"length":0.02,"maxlength":5,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(_, _, let minLength) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(minLength, 0)
    }

    /// length/maxlength 둘 다 없으면 그릴 수 없다 — 알려진 이름인데 필드가
    /// 깨졌으니 malformed로 남기고 sprite로 떨어진다(기존 emitter/initializer/
    /// operator 파싱과 같은 규칙).
    func testSpriteTrailMissingRequiredFieldsIsMalformed() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
        XCTAssertTrue(p.malformedNames.contains("spritetrail"))
    }

    /// 실물 orbTrail.json 그대로 — subdivision만 있다.
    func testParsesRealOrbTrailRope() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"rope","subdivision":2}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .rope(let subdivision, let uvScale, let uvScrolling) = p.renderKind else {
            return XCTFail("rope여야 한다")
        }
        XCTAssertEqual(subdivision, 2)
        XCTAssertEqual(uvScale, 1, "안 적으면 배율 없음(1)")
        XCTAssertFalse(uvScrolling, "안 적으면 꺼짐")
    }

    /// 실물 water_faucet.json 그대로 — uvscale/uvscrolling까지 다 있다.
    func testParsesRealWaterFaucetRope() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":12,"name":"rope","uvscale":0.5,"uvscrolling":true,
                      "uvsmoothing":false}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .rope(let subdivision, let uvScale, let uvScrolling) = p.renderKind else {
            return XCTFail("rope여야 한다")
        }
        XCTAssertEqual(subdivision, 0, "안 적으면 세분화 없음(0) — 실물 dischargearc.json도 명시적으로 0")
        XCTAssertEqual(uvScale, 0.5)
        XCTAssertTrue(uvScrolling)
    }

    /// 실물 magic_vortex_0.json 그대로 — length만 있다. subdivision/segments/
    /// fadeAlpha/uvScale/uvScrolling은 실물에 한 번도 안 나와 rope와 같은
    /// 기본값(0/1/false)을 쓴다.
    func testParsesRealMagicVortexRopeTrail() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"length":0.2,"name":"ropetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .ropeTrail(let subdivision, let length, let segments, let fadeAlpha,
                              let uvScale, let uvScrolling) = p.renderKind
        else { return XCTFail("ropetrail이어야 한다") }
        XCTAssertEqual(subdivision, 0)
        XCTAssertEqual(length, 0.2)
        XCTAssertEqual(segments, 1, "안 적으면 최소값(1) — 실물에 한 번도 안 나온 필드")
        XCTAssertFalse(fadeAlpha)
        XCTAssertEqual(uvScale, 1)
        XCTAssertFalse(uvScrolling)
    }

    /// ropetrail의 length가 없으면 malformed로 남기고 sprite로 떨어진다.
    func testRopeTrailMissingLengthIsMalformed() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"ropetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
        XCTAssertTrue(p.malformedNames.contains("ropetrail"))
    }

    /// 모르는 이름은 unsupported로 남기고 sprite로 떨어진다.
    func testUnknownRendererNameIsUnsupported() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"beam"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
        XCTAssertTrue(p.unsupportedNames.contains("beam"))
    }
}
