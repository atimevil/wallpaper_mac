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
                     {"name":"controlpointattract","controlpoint":2,"scale":1.0,"radius":100}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators.count, 6, "여섯 종류가 전부 인식되어야 한다")

        // 각 operator의 associated value를 검사
        guard case .movement(let gravity, let drag) = p.operators[0] else {
            return XCTFail("movement이어야 한다")
        }
        XCTAssertEqual(gravity, Vec3(x: 0, y: -9, z: 0))
        XCTAssertEqual(drag, 0.1)

        guard case .alphaFade(let fadeInTime, let fadeOutTime) = p.operators[1] else {
            return XCTFail("alphafade이어야 한다")
        }
        XCTAssertEqual(fadeInTime, 0.1)
        XCTAssertEqual(fadeOutTime, 0.2)

        guard case .angularMovement(let gravity, let drag) = p.operators[2] else {
            return XCTFail("angularmovement이어야 한다")
        }
        XCTAssertEqual(gravity, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(drag, 0.0)

        guard case .oscillatePosition(let mask, let scaleMin, let scaleMax,
                                      let freqMin, let freqMax, let phaseMin, let phaseMax) = p.operators[3] else {
            return XCTFail("oscillateposition이어야 한다")
        }
        XCTAssertEqual(mask, Vec3(x: 1, y: 0.5, z: 0))
        XCTAssertEqual(scaleMin, 20)
        XCTAssertEqual(scaleMax, 35)
        XCTAssertEqual(freqMin, 0.8)
        XCTAssertEqual(freqMax, 1.0)
        XCTAssertEqual(phaseMin, 0)
        XCTAssertEqual(phaseMax, 1)

        guard case .oscillateAlpha(let freqMin, let freqMax, let phaseMin, let phaseMax) = p.operators[4] else {
            return XCTFail("oscillatealpha이어야 한다")
        }
        XCTAssertEqual(freqMin, 0.5)
        XCTAssertEqual(freqMax, 1.5)
        XCTAssertEqual(phaseMin, 0)
        XCTAssertEqual(phaseMax, 1)

        guard case .controlPointAttract(let controlPoint, let scale, let radius) = p.operators[5] else {
            return XCTFail("controlpointattract이어야 한다")
        }
        XCTAssertEqual(controlPoint, 2)
        XCTAssertEqual(scale, 1.0)
        XCTAssertEqual(radius, 100)
    }

    func testBoxRandomEmitter() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"boxrandom","rate":5,"origin":"1 2 3",
                     "directions":"0 -1 0","min":"-100 -10 0","max":"100 10 50"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .boxRandom(let rate, let origin, let directions, let min, let max) = p.emitters[0] else {
            return XCTFail("boxrandom이어야 한다")
        }
        XCTAssertEqual(rate, 5)
        XCTAssertEqual(origin, Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(directions, Vec3(x: 0, y: -1, z: 0))
        XCTAssertEqual(min, Vec3(x: -100, y: -10, z: 0))
        XCTAssertEqual(max, Vec3(x: 100, y: 10, z: 50))
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
        XCTAssertTrue(p.malformedNames.isEmpty,
                     "모르는 이름들은 malformedNames가 아니라 unsupportedNames에 들어가야 한다")
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

    /// 이름은 아는데 필드가 깨진 엔트리는 malformedNames에 들어가고 unsupportedNames에는 아니다.
    func testMalformedKnownTypeIsMalformedNotUnsupported() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"garbage","max":"0 0 0"},
                        {"name":"sizerandom","min":1,"max":2}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.malformedNames.contains("velocityrandom"),
                     "알려진 이름이지만 깨진 필드는 malformedNames에 들어가야 한다")
        XCTAssertFalse(p.unsupportedNames.contains("velocityrandom"),
                      "malformedNames에 들어간 이름은 unsupportedNames에 없어야 한다")
    }

    /// 큰 지수 표기 실수가 들어와도 크래시하지 않고 클램프된다.
    func testHugeFloatMaxCountDoesNotTrap() throws {
        let json: [String: Any] = ["material": "m.json", "maxcount": 1e20]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.maxCount, ParticlePreset.maxAllowedCount,
                      "지수 표기는 포화 변환해서 클램프해야 한다")
    }

    /// 음의 지수 표기도 안전하게 처리된다.
    func testNegativeHugeFloatMaxCountBecomesZero() throws {
        let json: [String: Any] = ["material": "m.json", "maxcount": -1e20]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.maxCount, 0, "음의 지수 표기는 0으로 된다")
    }

    /// NaN maxcount는 안전하게 0으로 된다.
    func testNaNMaxCountBecomesZero() throws {
        let json: [String: Any] = ["material": "m.json", "maxcount": Double.nan]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.maxCount, 0, "NaN은 값 없음으로 취급한다")
    }

    /// 범위 밖 controlpoint는 그 operator를 버린다.
    func testOutOfRangeControlPointDropsEntry() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "operator": [
                ["name": "controlpointattract", "controlpoint": 1e20, "scale": 1.0, "radius": 100]
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.operators.count, 0, "범위 밖 controlpoint는 엔트리를 버린다")
    }
}
