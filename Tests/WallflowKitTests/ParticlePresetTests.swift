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

        guard case .sphereRandom(let rate, let origin, _, let dmin, let dmax, _) = p.emitters[0] else {
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
                     {"name":"angularmovement","force":"0 0 0","drag":0.0},
                     {"name":"oscillateposition","mask":"1 0.5 0","scalemin":20,"scalemax":35,
                      "frequencymin":0.8,"frequencymax":1.0,"phasemin":0,"phasemax":1},
                     {"name":"oscillatealpha","frequencymin":0.5,"frequencymax":1.5,
                      "scalemin":0.2,"scalemax":0.8},
                     {"name":"controlpointattract","controlpoint":2,"origin":"0 0 0","scale":1.0,"threshold":100}]}
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

        guard case .angularMovement(let force, let drag) = p.operators[2] else {
            return XCTFail("angularmovement이어야 한다")
        }
        XCTAssertEqual(force, Vec3(x: 0, y: 0, z: 0))
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

        guard case .oscillateAlpha(let freqMin, let freqMax, let scaleMin, let scaleMax) = p.operators[4] else {
            return XCTFail("oscillatealpha이어야 한다")
        }
        XCTAssertEqual(freqMin, 0.5)
        XCTAssertEqual(freqMax, 1.5)
        XCTAssertEqual(scaleMin, 0.2)
        XCTAssertEqual(scaleMax, 0.8)

        guard case .controlPointAttract(let controlPoint, let origin, let scale, let threshold) = p.operators[5] else {
            return XCTFail("controlpointattract이어야 한다")
        }
        XCTAssertEqual(controlPoint, 2)
        XCTAssertEqual(origin, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(scale, 1.0)
        XCTAssertEqual(threshold, 100)
    }

    func testBoxRandomEmitter() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"boxrandom","rate":5,"origin":"1 2 3",
                     "directions":"0 -1 0","distancemin":"-100 -10 0","distancemax":"100 10 50"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .boxRandom(let rate, let origin, let directions, let distanceMin, let distanceMax, _) = p.emitters[0] else {
            return XCTFail("boxrandom이어야 한다")
        }
        XCTAssertEqual(rate, 5)
        XCTAssertEqual(origin, Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(directions, Vec3(x: 0, y: -1, z: 0))
        XCTAssertEqual(distanceMin, Vec3(x: -100, y: -10, z: 0))
        XCTAssertEqual(distanceMax, Vec3(x: 100, y: 10, z: 50))
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

    /// name 키가 없는 emitter 엔트리는 조용히 사라지지 않고 진단에 남는다.
    func testEmitterWithoutNameIsRecordedNotSilentlyDropped() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "emitter": [
                ["rate": 1]  // name 키 없음
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.emitters.isEmpty, "필드가 깨진 엔트리는 버린다")
        XCTAssertTrue(p.malformedNames.contains("(이름 없는 엔트리)"),
                     "name을 읽지 못한 엔트리는 sentinel 라벨로 malformedNames에 남아야 한다")
    }

    /// name 키가 없는 initializer 엔트리는 조용히 사라지지 않고 진단에 남는다.
    func testInitializerWithoutNameIsRecordedNotSilentlyDropped() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "initializer": [
                ["min": 1, "max": 2]  // name 키 없음
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.initializers.isEmpty, "필드가 깨진 엔트리는 버린다")
        XCTAssertTrue(p.malformedNames.contains("(이름 없는 엔트리)"),
                     "name을 읽지 못한 엔트리는 sentinel 라벨로 malformedNames에 남아야 한다")
    }

    /// name 키가 없는 operator 엔트리는 조용히 사라지지 않고 진단에 남는다.
    func testOperatorWithoutNameIsRecordedNotSilentlyDropped() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "operator": [
                ["gravity": "0 -9 0"]  // name 키 없음
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.operators.isEmpty, "필드가 깨진 엔트리는 버린다")
        XCTAssertTrue(p.malformedNames.contains("(이름 없는 엔트리)"),
                     "name을 읽지 못한 엔트리는 sentinel 라벨로 malformedNames에 남아야 한다")
    }

    /// name이 String이 아닌 엔트리는 조용히 사라지지 않고 진단에 남는다.
    func testEntryWithNonStringNameIsRecorded() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "initializer": [
                ["name": 3, "min": 1, "max": 2]  // name이 Int
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.initializers.isEmpty, "필드가 깨진 엔트리는 버린다")
        XCTAssertTrue(p.malformedNames.contains("(이름 없는 엔트리)"),
                     "name이 String이 아니면 sentinel 라벨로 malformedNames에 남아야 한다")
    }

    /// 같은 이름의 엔트리가 여러 개인데 일부만 깨진 경우, 정상 엔트리는 파싱되고 동시에
    /// 그 이름이 malformedNames에도 들어간다. 이건 의도된 동작이다. malformedNames는
    /// 이름 단위라서 "이 이름의 엔트리 중 하나 이상을 버렸다"고 읽어야 한다.
    func testDuplicateNameWithOneBrokenReportsBothOutcomes() throws {
        let json: [String: Any] = [
            "material": "m.json",
            "maxcount": 10,
            "initializer": [
                ["name": "velocityrandom", "min": "-10 -50 0", "max": "-37 -90 0"],  // 정상
                ["name": "velocityrandom", "min": "garbage", "max": "0 0 0"]  // 깨짐
            ]
        ]
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        // 정상 엔트리는 파싱되어야 한다.
        XCTAssertEqual(p.initializers.count, 1, "정상 엔트리는 파싱되어야 한다")
        guard case .velocityRandom(let min, let max) = p.initializers[0] else {
            return XCTFail("velocityrandom이어야 한다")
        }
        XCTAssertEqual(min, Vec3(x: -10, y: -50, z: 0))
        XCTAssertEqual(max, Vec3(x: -37, y: -90, z: 0))

        // 동시에 깨진 엔트리 때문에 그 이름이 malformedNames에 들어간다.
        // 이건 의도된 동작 — 일부라도 버린 엔트리가 있으면 그 사실을 사용자에게 알려야 한다.
        XCTAssertTrue(p.malformedNames.contains("velocityrandom"),
                     "같은 이름의 일부만 깨져도 그 이름이 malformedNames에 들어가야 한다")

        // unsupportedNames에는 들어가지 않아야 한다.
        XCTAssertFalse(p.unsupportedNames.contains("velocityrandom"),
                      "알려진 이름은 unsupportedNames가 아니라 malformedNames에만 들어가야 한다")
    }

    // Task 4b: 실물 필드 모양에 맞춘 새로운 테스트들

    /// 1. `{"name":"boxrandom","rate":200}` — 필드가 이것뿐이어도 파싱되고 malformed가 아니다.
    func testBoxRandomWithMinimalFields() throws {
        let json = try XCTUnwrap(preset(#"{"material":"m.json","maxcount":10,"emitter":[{"name":"boxrandom","rate":200}]}"#))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertEqual(p.emitters.count, 1, "필드가 최소일 때도 파싱되어야 한다")
        guard case .boxRandom(let rate, _, _, _, _, _) = p.emitters[0] else {
            return XCTFail("boxrandom이어야 한다")
        }
        XCTAssertEqual(rate, 200)
        XCTAssertTrue(p.malformedNames.isEmpty, "필드가 이것뿐이어도 malformed가 아니다")
    }

    /// 2. `{"name":"boxrandom","distancemax":"1024 512 0"}` — rate 없이 파싱되고 rate가 `defaultEmitRate`다.
    func testBoxRandomWithDefaultRate() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "emitter":[{"name":"boxrandom","distancemax":"1024 512 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .boxRandom(let rate, _, _, _, let distanceMax, _) = p.emitters[0] else {
            return XCTFail("boxrandom이어야 한다")
        }
        XCTAssertEqual(rate, ParticlePreset.defaultEmitRate, "rate가 없으면 defaultEmitRate를 쓴다")
        XCTAssertEqual(distanceMax, Vec3(x: 1024, y: 512, z: 0))
    }

    /// 3. `{"name":"angularmovement","force":"0 0 0"}` — malformed가 아니다.
    func testAngularMovementWithForce() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"name":"angularmovement","force":"0 0 0"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .angularMovement(let force, _) = p.operators[0] else {
            return XCTFail("angularmovement이어야 한다")
        }
        XCTAssertEqual(force, Vec3(x: 0, y: 0, z: 0))
        XCTAssertTrue(p.malformedNames.isEmpty, "force 필드로 파싱되어야 한다")
    }

    /// 4. `{"name":"turbulentvelocityrandom","offset":3,"scale":0.5,"speedmin":35,"speedmax":100}` — 네 값이 모델에 들어간다.
    func testTurbulentVelocityRandomAllFields() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"turbulentvelocityrandom","offset":3,"scale":0.5,"speedmin":35,"speedmax":100}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .turbulentVelocityRandom(let offset, let scale, let speedMin, let speedMax) = p.initializers[0] else {
            return XCTFail("turbulentvelocityrandom이어야 한다")
        }
        XCTAssertEqual(offset, 3)
        XCTAssertEqual(scale, 0.5)
        XCTAssertEqual(speedMin, 35)
        XCTAssertEqual(speedMax, 100)
    }

    /// 5. `{"name":"controlpointattract","controlpoint":1,"origin":"0 0 0","scale":-1024,"threshold":32}` — malformed가 아니고 threshold가 들어간다.
    func testControlPointAttractWithThreshold() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"name":"controlpointattract","controlpoint":1,"origin":"0 0 0","scale":-1024,"threshold":32}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .controlPointAttract(let cp, let origin, let scale, let threshold) = p.operators[0] else {
            return XCTFail("controlpointattract이어야 한다")
        }
        XCTAssertEqual(cp, 1)
        XCTAssertEqual(origin, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(scale, -1024)
        XCTAssertEqual(threshold, 32)
        XCTAssertTrue(p.malformedNames.isEmpty, "threshold 필드로 파싱되어야 한다")
    }

    /// 6. `{"name":"oscillatealpha","frequencymin":3,"frequencymax":7,"scalemin":0.5,"scalemax":0.8}` — scale 두 값이 모델에 들어간다.
    func testOscillateAlphaWithScale() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "operator":[{"name":"oscillatealpha","frequencymin":3,"frequencymax":7,"scalemin":0.5,"scalemax":0.8}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .oscillateAlpha(let freqMin, let freqMax, let scaleMin, let scaleMax) = p.operators[0] else {
            return XCTFail("oscillatealpha이어야 한다")
        }
        XCTAssertEqual(freqMin, 3)
        XCTAssertEqual(freqMax, 7)
        XCTAssertEqual(scaleMin, 0.5)
        XCTAssertEqual(scaleMax, 0.8)
    }

    /// 7. `{"name":"velocityrandom","min":"1 2 3"}` — max가 없으면 min과 같아진다.
    /// 한쪽 경계가 없으면 **그 속성의 기본값**을 쓴다. 있는 쪽을 복사하지 않는다.
    ///
    /// 처음엔 복사하도록 만들었는데 실물이 그걸 반박했다. Sakura의 leaves5.json에
    /// `{"name":"rotationrandom","max":"6.283 6.283 6.283"}`가 있고 6.283은 2π다.
    /// 즉 꽃잎마다 0~2π 무작위 각도를 뜻하는데, 복사하면 200장이 전부 같은 각도로
    /// 굳어 회전이 사라진다. boxrandom의 distancemin도 마찬가지로 0이어야
    /// 상자 안이 채워진다 — 복사하면 표면 한 겹에만 생긴다.
    func testMissingBoundUsesPropertyDefaultNotTheOtherBound() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"1 2 3"},
                        {"name":"rotationrandom","max":"6.283 6.283 6.283"},
                        {"name":"sizerandom","max":30}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.malformedNames.isEmpty, "malformed: \(p.malformedNames)")

        guard case .velocityRandom(let vMin, let vMax) = p.initializers[0] else {
            return XCTFail("velocityrandom이어야 한다")
        }
        XCTAssertEqual(vMin, Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(vMax, Vec3(x: 0, y: 0, z: 0), "속도의 기본값은 0이다")

        guard case .rotationRandom(let rMin, let rMax) = p.initializers[1] else {
            return XCTFail("rotationrandom이어야 한다")
        }
        XCTAssertEqual(rMin, Vec3(x: 0, y: 0, z: 0), "회전의 기본값은 0이라 0~2π가 된다")
        XCTAssertEqual(rMax, Vec3(x: 6.283, y: 6.283, z: 6.283))

        guard case .sizeRandom(let sMin, let sMax) = p.initializers[2] else {
            return XCTFail("sizerandom이어야 한다")
        }
        XCTAssertEqual(sMin, 1, "크기의 기본값은 1이다. 0이면 안 보인다")
        XCTAssertEqual(sMax, 30)
    }

    /// 색은 실물에서 0~255다. WE 자체 예제도 흰색을 "255 255 255"로 적는다.
    /// 셰이더가 텍스처에 곱하므로 그대로 넘기면 전부 흰색으로 포화된다 —
    /// 눈은 원래 희어서 티가 안 나지만 벚꽃은 분홍이 날아간다.
    func testColorIsNormalizedTo01() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"colorrandom","min":"255 255 255","max":"255 192 248"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        guard case .colorRandom(let lo, let hi) = p.initializers[0] else {
            return XCTFail("colorrandom이어야 한다")
        }
        XCTAssertEqual(lo.x, 1, accuracy: 0.001)
        XCTAssertEqual(hi.x, 1, accuracy: 0.001)
        XCTAssertEqual(hi.y, 192.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(hi.z, 248.0 / 255.0, accuracy: 0.001)
    }

    /// 8. `{"name":"velocityrandom","min":"쓰레기"}` — 여전히 malformed다.
    func testVelocityRandomWithGarbageIsStillMalformed() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom","min":"쓰레기"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.initializers.isEmpty, "파싱되지 않는 필드는 엔트리를 버린다")
        XCTAssertTrue(p.malformedNames.contains("velocityrandom"), "있는데 해석 안 되는 것은 malformed다")
    }

    /// 필드가 없는 초기화자는 아무 효과도 내면 안 된다. 그래서 기본값은 0이 아니라
    /// 파티클의 기본값과 같다. 크기 0은 안 보이고 알파 0은 투명하다.
    func testInitializerWithNoFieldsUsesPropertyDefaults() throws {
        // lifetimerandom: 기본값 1
        let jsonLifetime = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"lifetimerandom"}]}
        """))
        let pLifetime = try XCTUnwrap(ParticlePreset.parse(jsonLifetime))
        XCTAssertEqual(pLifetime.initializers.count, 1, "lifetimerandom이 필드 없이도 파싱되어야 한다")
        guard case .lifetimeRandom(let min, let max) = pLifetime.initializers[0] else {
            return XCTFail("lifetimerandom이어야 한다")
        }
        XCTAssertEqual(min, 1, "lifetimerandom의 기본값은 1이어야 한다")
        XCTAssertEqual(max, 1, "lifetimerandom의 기본값은 1이어야 한다")
        XCTAssertTrue(pLifetime.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // sizerandom: 기본값 1
        let jsonSize = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"sizerandom"}]}
        """))
        let pSize = try XCTUnwrap(ParticlePreset.parse(jsonSize))
        XCTAssertEqual(pSize.initializers.count, 1, "sizerandom이 필드 없이도 파싱되어야 한다")
        guard case .sizeRandom(let min, let max) = pSize.initializers[0] else {
            return XCTFail("sizerandom이어야 한다")
        }
        XCTAssertEqual(min, 1, "sizerandom의 기본값은 1이어야 한다")
        XCTAssertEqual(max, 1, "sizerandom의 기본값은 1이어야 한다")
        XCTAssertTrue(pSize.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // alpharandom: 기본값 1
        let jsonAlpha = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"alpharandom"}]}
        """))
        let pAlpha = try XCTUnwrap(ParticlePreset.parse(jsonAlpha))
        XCTAssertEqual(pAlpha.initializers.count, 1, "alpharandom이 필드 없이도 파싱되어야 한다")
        guard case .alphaRandom(let min, let max) = pAlpha.initializers[0] else {
            return XCTFail("alpharandom이어야 한다")
        }
        XCTAssertEqual(min, 1, "alpharandom의 기본값은 1이어야 한다")
        XCTAssertEqual(max, 1, "alpharandom의 기본값은 1이어야 한다")
        XCTAssertTrue(pAlpha.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // velocityrandom: 기본값 (0, 0, 0)
        let jsonVelocity = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"velocityrandom"}]}
        """))
        let pVelocity = try XCTUnwrap(ParticlePreset.parse(jsonVelocity))
        XCTAssertEqual(pVelocity.initializers.count, 1, "velocityrandom이 필드 없이도 파싱되어야 한다")
        guard case .velocityRandom(let min, let max) = pVelocity.initializers[0] else {
            return XCTFail("velocityrandom이어야 한다")
        }
        XCTAssertEqual(min, Vec3(x: 0, y: 0, z: 0), "velocityrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertEqual(max, Vec3(x: 0, y: 0, z: 0), "velocityrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertTrue(pVelocity.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // colorrandom: 기본값 (1, 1, 1)
        let jsonColor = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"colorrandom"}]}
        """))
        let pColor = try XCTUnwrap(ParticlePreset.parse(jsonColor))
        XCTAssertEqual(pColor.initializers.count, 1, "colorrandom이 필드 없이도 파싱되어야 한다")
        guard case .colorRandom(let min, let max) = pColor.initializers[0] else {
            return XCTFail("colorrandom이어야 한다")
        }
        XCTAssertEqual(min, Vec3(x: 1, y: 1, z: 1), "colorrandom의 기본값은 (1, 1, 1)이어야 한다")
        XCTAssertEqual(max, Vec3(x: 1, y: 1, z: 1), "colorrandom의 기본값은 (1, 1, 1)이어야 한다")
        XCTAssertTrue(pColor.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // rotationrandom: 기본값 (0, 0, 0)
        let jsonRotation = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"rotationrandom"}]}
        """))
        let pRotation = try XCTUnwrap(ParticlePreset.parse(jsonRotation))
        XCTAssertEqual(pRotation.initializers.count, 1, "rotationrandom이 필드 없이도 파싱되어야 한다")
        guard case .rotationRandom(let min, let max) = pRotation.initializers[0] else {
            return XCTFail("rotationrandom이어야 한다")
        }
        XCTAssertEqual(min, Vec3(x: 0, y: 0, z: 0), "rotationrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertEqual(max, Vec3(x: 0, y: 0, z: 0), "rotationrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertTrue(pRotation.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")

        // angularvelocityrandom: 기본값 (0, 0, 0)
        let jsonAngularVelocity = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"angularvelocityrandom"}]}
        """))
        let pAngularVelocity = try XCTUnwrap(ParticlePreset.parse(jsonAngularVelocity))
        XCTAssertEqual(pAngularVelocity.initializers.count, 1, "angularvelocityrandom이 필드 없이도 파싱되어야 한다")
        guard case .angularVelocityRandom(let min, let max) = pAngularVelocity.initializers[0] else {
            return XCTFail("angularvelocityrandom이어야 한다")
        }
        XCTAssertEqual(min, Vec3(x: 0, y: 0, z: 0), "angularvelocityrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertEqual(max, Vec3(x: 0, y: 0, z: 0), "angularvelocityrandom의 기본값은 (0, 0, 0)이어야 한다")
        XCTAssertTrue(pAngularVelocity.malformedNames.isEmpty, "필드가 없어도 malformed가 아니다")
    }

    /// 필드가 있는데 해석이 안 되는 경우는 지금처럼 계속 엔트리를 버려야 한다.
    /// 이 구분을 깨지 마라. 공들여 만든 것이다.
    func testInitializerWithUnparseableFieldIsStillMalformed() throws {
        let json = try XCTUnwrap(preset("""
        {"material":"m.json","maxcount":10,
         "initializer":[{"name":"rotationrandom","min":"쓰레기"}]}
        """))
        let p = try XCTUnwrap(ParticlePreset.parse(json))
        XCTAssertTrue(p.initializers.isEmpty, "파싱되지 않는 필드는 엔트리를 버린다")
        XCTAssertTrue(p.malformedNames.contains("rotationrandom"), "있는데 해석 안 되는 것은 malformed다")
    }
}
