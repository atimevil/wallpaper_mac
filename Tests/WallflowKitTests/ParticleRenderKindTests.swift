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

    /// 실물 exampleturbolence.json은 minlength가 없다 — 1로 본다. `up = velocity정규화
    /// * max(minlength, min(speed*length, maxlength))`(common_particles.h)라
    /// minlength가 0이면 length도 없는 프리셋(바로 아래 테스트)에서 up이
    /// 완전히 0벡터가 되어 트레일이 그 축으로 찌그러져 안 보인다 — 1은
    /// 회전 기반 스프라이트의 기본 up 벡터 크기(단위 벡터)와 같아 "아무것도
    /// 안 적으면 최소 스프라이트만큼은 보인다"는 뜻이다. length·maxlength가
    /// 큰 이 프리셋에서는 속도가 조금만 있어도 clamp 위쪽이 1을 넘어서므로
    /// 영향이 없다.
    func testSpriteTrailMissingMinLengthDefaultsToOne() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"length":0.02,"maxlength":5,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(_, _, let minLength) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(minLength, 1)
    }

    /// 실물 WE 번들 fireworks1hit.json/fireworks2hit.json/magic_vortex_1.json
    /// 그대로 — length/maxlength/minlength 셋 다 안 적는다. malformed가
    /// 아니다: length가 없으면 속도로 안 늘어난다는 뜻(0)이지만, minlength
    /// 기본값이 1이라 up이 0벡터로 찌그러지지 않고 스프라이트만큼은 보인다
    /// — fireworks1hit은 속도가 최대 1500까지 나오는데(emitter speedmax),
    /// minlength가 0이면 폭죽이 터지는 순간 파티클이 투명해진다.
    func testSpriteTrailMissingAllLengthFieldsStaysVisible() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(let length, let maxLength, let minLength) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(length, 0)
        XCTAssertEqual(maxLength, .infinity, "안 적으면 위쪽 clamp가 없다는 뜻")
        XCTAssertEqual(minLength, 1, "0이면 빠른 폭죽 파티클이 투명해진다")
        XCTAssertTrue(p.malformedNames.isEmpty)
    }

    /// 실물 `dripping_water_droplets.json`은 minlength가 `null`이다 — 없는
    /// 것과 같게 본다(malformed가 아니다).
    func testSpriteTrailNullMinLengthDefaultsToOne() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":13,"length":0.1,"maxlength":3,"minlength":null,
                      "name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(_, _, let minLength) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(minLength, 1)
        XCTAssertTrue(p.malformedNames.isEmpty)
    }

    /// length가 숫자로 못 읽는 쓰레기 값이면(실물에는 없지만 방어적으로) 없는
    /// 것과 다르게 malformed로 남긴다 — 파일이 있는데 깨진 것과 아예 안 적은
    /// 것을 같은 취급으로 뭉개면 진짜 오류를 놓친다.
    func testSpriteTrailGarbageLengthIsMalformed() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"length":"not a number","name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.renderKind, .sprite)
        XCTAssertTrue(p.malformedNames.contains("spritetrail"))
    }

    /// 실물 `ember.json`/`ember_small.json` 그대로 — length만 있고 maxlength가
    /// 없다. clamp 상한이 없다는 뜻(무한대)으로 본다 — length가 0.007처럼
    /// 작아 실제로는 안 막혀도 티가 안 난다.
    func testSpriteTrailMissingMaxLengthDefaultsToUnbounded() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"length":0.007000000074505806,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(let length, let maxLength, _) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(length, 0.007000000074505806, accuracy: 1e-9)
        XCTAssertEqual(maxLength, .infinity)
        XCTAssertTrue(p.malformedNames.isEmpty)
    }

    /// 실물 `rain_on_the_glass_copy1.json` 그대로 — maxlength만 있고 length가
    /// 없다. 안 늘어난다는 뜻(0)으로 본다.
    func testSpriteTrailMissingLengthDefaultsToZero() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "renderer":[{"id":1,"maxlength":6,"name":"spritetrail"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .spriteTrail(let length, let maxLength, _) = p.renderKind else {
            return XCTFail("spritetrail이어야 한다")
        }
        XCTAssertEqual(length, 0)
        XCTAssertEqual(maxLength, 6)
        XCTAssertTrue(p.malformedNames.isEmpty)
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
