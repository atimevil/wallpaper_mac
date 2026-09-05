import XCTest
@testable import WallflowKit

final class ParticlePresetTests: XCTestCase {
    private func preset(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// 실물 snowflat.json 그대로. M4 목표 씬이 쓰는 프리셋이다.
    func testParsesRealSnowflatPreset() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"materials/presets/snowflat.json","maxcount":300,"starttime":15,
         "emitter":[{"name":"sphererandom","rate":15,"origin":"0 650 0",
                     "directions":"1 0.03 0","distancemin":10,"distancemax":1200}],
         "initializer":[{"name":"lifetimerandom","min":15,"max":23},
                        {"name":"sizerandom","min":2,"max":30},
                        {"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"},
                        {"name":"colorrandom","min":"255 255 255","max":"95 98 100"}],
         "operator":[{"name":"movement","gravity":"0 0 0"},
                     {"name":"alphafade","fadeintime":0.1}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.maxCount, 300)
        XCTAssertEqual(p.startTime, 15)
        XCTAssertEqual(p.materialPath, "materials/presets/snowflat.json")
        XCTAssertEqual(p.emitters.count, 1)
        XCTAssertEqual(p.initializers.count, 4)
        XCTAssertEqual(p.operators.count, 2)

        guard case .sphereRandom(let rate, let origin, _, let dmin, let dmax) = p.emitters[0] else {
            return XCTFail("sphererandom이어야 한다")
        }
        XCTAssertEqual(rate, 15)
        XCTAssertEqual(origin, Vec3(x: 0, y: 650, z: 0))
        XCTAssertEqual(dmin, 10)
        XCTAssertEqual(dmax, 1200)
    }

    func testParsesScalarInitializers() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"lifetimerandom","min":15,"max":23},
                        {"name":"sizerandom","min":2,"max":30},
                        {"name":"alpharandom","min":0.2,"max":0.9},
                        {"name":"angularvelocityrandom","min":"-1 0 0","max":"1 0 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 4)
        guard case .lifetimeRandom(let lo, let hi) = p.initializers[0] else {
            return XCTFail("lifetimerandom")
        }
        XCTAssertEqual(lo, 15); XCTAssertEqual(hi, 23)
    }

    func testParsesVectorInitializers() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"},
                        {"name":"colorrandom","min":"255 255 255","max":"95 98 100"},
                        {"name":"rotationrandom","min":"0 0 0","max":"0 0 6.28"},
                        {"name":"turbulentvelocityrandom","min":"0 0 0","max":"5 5 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 4)
        guard case .velocityRandom(let lo, let hi) = p.initializers[0] else {
            return XCTFail("velocityrandom")
        }
        XCTAssertEqual(lo, Vec3(x: -10, y: -50, z: 0))
        XCTAssertEqual(hi, Vec3(x: -37, y: -90, z: 0))
    }

    func testParsesAllSixOperators() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"name":"movement","gravity":"0 -9 0","drag":0.1},
                     {"name":"alphafade","fadeintime":0.1,"fadeouttime":0.2},
                     {"name":"angularmovement","gravity":"0 0 0","drag":0.0},
                     {"name":"oscillateposition","mask":"1 0.5 0","scalemin":20,"scalemax":35,
                      "frequencymin":0.8,"frequencymax":1.0,"phasemin":0,"phasemax":1},
                     {"name":"oscillatealpha","frequencymin":0.5,"frequencymax":1.5,
                      "phasemin":0,"phasemax":1},
                     {"name":"controlpointattract","controlpoint":0,"scale":1.0,"radius":100}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators.count, 6, "여섯 종류가 전부 인식되어야 한다")
    }

    func testBoxRandomEmitter() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"boxrandom","rate":5,"origin":"0 0 0",
                     "directions":"0 -1 0","min":"-100 -10 0","max":"100 10 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .boxRandom = p.emitters[0] else { return XCTFail("boxrandom") }
    }

    /// 모르는 이름은 씬 전체를 버리지 않고 그것만 빠진다.
    func testUnknownNamesAreDroppedNotFatal() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"neveheardofthis","rate":1}],
         "initializer":[{"name":"sizerandom","min":1,"max":2},
                        {"name":"alsounknown","min":0,"max":1}],
         "operator":[{"name":"unknownop"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.emitters.isEmpty)
        XCTAssertEqual(p.initializers.count, 1, "아는 것만 남는다")
        XCTAssertTrue(p.operators.isEmpty)
        XCTAssertEqual(p.unsupportedNames.sorted(),
                       ["alsounknown", "neveheardofthis", "unknownop"],
                       "무엇이 빠졌는지 보고할 수 있어야 한다")
    }

    /// maxcount는 파일에서 온 값이고 시뮬레이션 버퍼 크기를 정한다.
    func testAbsurdMaxCountIsClamped() throws {
        let json = try XCTUnwrap(preset(#"{"material":"m.json","maxcount":2000000000}"#))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertLessThanOrEqual(p.maxCount, ParticlePreset.maxAllowedCount)
    }

    func testNegativeMaxCountBecomesZero() throws {
        let json = try XCTUnwrap(preset(#"{"material":"m.json","maxcount":-5}"#))
        XCTAssertEqual(try XCTUnwrap(ParticlePreset.parse(json)).maxCount, 0)
    }

    func testMissingMaterialYieldsNil() throws {
        let json = try XCTUnwrap(preset(#"{"maxcount":10}"#))
        XCTAssertNil(ParticlePreset.parse(json), "머티리얼 없이는 그릴 수 없다")
    }

    /// 벡터 문자열이 깨져 있으면 그 항목만 빠진다.
    func testMalformedVectorDropsOnlyThatEntry() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"garbage","max":"0 0 0"},
                        {"name":"sizerandom","min":1,"max":2}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.initializers.count, 1)
    }
}
