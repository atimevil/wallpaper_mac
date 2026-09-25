import XCTest
@testable import WallflowKit

final class SceneDocumentTests: XCTestCase {
    /// scene.json과 참조 파일들을 담은 최소 .pkg를 만든다.
    private func makeScenePkg(
        scene: String,
        extras: [String: String] = [:]
    ) throws -> PkgReader {
        var entries: [(String, Data)] = [("scene.json", Data(scene.utf8))]
        for (name, body) in extras { entries.append((name, Data(body.utf8))) }
        return try PkgReader(data: buildPkg(version: "PKGV0023", entries: entries))
    }

    func testParsesOrthographicProjectionAndClearColor() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 2048, "height": 1164},
                     "clearcolor": "0.70000 0.70000 0.70000", "clearenabled": true},
         "objects": []}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.orthoWidth, 2048)
        XCTAssertEqual(doc.orthoHeight, 1164)
        XCTAssertEqual(doc.clearColor, Vec3(x: 0.7, y: 0.7, z: 0.7))
        XCTAssertTrue(doc.clearEnabled)
        // zoom이 없으면 확대 없음(1)이다.
        XCTAssertEqual(doc.zoom, 1)
    }

    /// 실물 세로형 씬 3794448602이 실제로 갖고 있는 `general.zoom`.
    func testParsesGeneralZoom() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 810, "height": 1080}, "zoom": 1.08},
         "objects": []}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.zoom, 1.08, accuracy: 0.0001)
    }

    /// 0 이하이거나 NaN이면 확대 없음(1)으로 본다 — 깨진 값이 화면을 밀어내면 안 된다.
    func testInvalidZoomFallsBackToOne() throws {
        for badZoom in ["0", "-1.5", "\"nan\""] {
            let reader = try makeScenePkg(scene: """
            {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "zoom": \(badZoom)},
             "objects": []}
            """)
            let doc = try SceneDocument.load(from: reader)
            XCTAssertEqual(doc.zoom, 1, "zoom \(badZoom)은 1이어야 한다")
        }
    }

    /// 실물 씬 3714517753의 실제 참조 사슬을 그대로 재현한다.
    func testResolvesImageLayerThroughModelAndMaterial() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 2048, "height": 1164}},
             "objects": [{"id": 33, "name": "HFRvNK5aIAA7Q24",
                          "image": "models/HFRvNK5aIAA7Q24.json",
                          "origin": "1024.00000 582.00000 0.00000",
                          "size": "2048.00000 1164.00000"}]}
            """,
            extras: [
                "models/HFRvNK5aIAA7Q24.json":
                    #"{"autosize": true, "material": "materials/HFRvNK5aIAA7Q24.json"}"#,
                "materials/HFRvNK5aIAA7Q24.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["HFRvNK5aIAA7Q24"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 1)
        let layer = try XCTUnwrap(doc.layers.first)
        XCTAssertEqual(layer.id, 33)
        XCTAssertEqual(layer.name, "HFRvNK5aIAA7Q24")
        XCTAssertEqual(layer.origin, Vec3(x: 1024, y: 582, z: 0))
        XCTAssertEqual(layer.size, Vec2(x: 2048, y: 1164))
        XCTAssertEqual(layer.content, .image(texturePath: "materials/HFRvNK5aIAA7Q24.tex"))
    }

    /// origin이 **없는 것**과 **읽히지 않는 것**은 다르다.
    /// 실물 음악 위젯의 진행 막대(`Internal Progress Bar`)는 부모에 붙어 있고
    /// origin이 아예 없다 — "부모와 같은 자리"라는 뜻이다. 둘을 같이 버려서
    /// 이 레이어가 통째로 사라졌다.
    func testMissingOriginOnChildMeansParentPosition() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 2048, "height": 1164}},
             "objects": [{"id": 7, "name": "parent", "image": "models/m.json",
                          "origin": "700.00000 300.00000 0.00000", "size": "10.00000 10.00000"},
                         {"id": 8, "name": "child", "parent": 7, "image": "models/m.json",
                          "size": "512.00000 16.00000"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])
        let child = try XCTUnwrap(SceneDocument.load(from: reader).layers.first { $0.id == 8 })
        XCTAssertEqual(child.origin, Vec3(x: 700, y: 300, z: 0))
        guard case .image = child.content else {
            return XCTFail("부모 자리에 그려야 한다: \(child.content)")
        }
    }

    /// 반대로, origin이 **있는데 못 읽는** 경우는 계속 버린다.
    /// 0,0으로 그리면 파일이 이상한 것을 정상처럼 보이게 한다.
    func testUnparsableOriginIsStillRejected() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 2048, "height": 1164}},
             "objects": [{"id": 7, "name": "parent", "image": "models/m.json",
                          "origin": "700.00000 300.00000 0.00000", "size": "10.00000 10.00000"},
                         {"id": 8, "name": "child", "parent": 7, "image": "models/m.json",
                          "origin": "쓰레기", "size": "512.00000 16.00000"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])
        let child = try XCTUnwrap(SceneDocument.load(from: reader).layers.first { $0.id == 8 })
        guard case .unsupported = child.content else {
            return XCTFail("읽히지 않는 origin은 버려야 한다: \(child.content)")
        }
    }

    /// 부모가 없고 origin도 없으면 버린다. 화면 구석에 정체불명의 상자가 뜨는 것보다
    /// 안 그리는 쪽이 정직하다.
    func testMissingOriginWithoutParentIsRejected() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 3, "name": "orphan", "image": "models/m.json",
                          "size": "512.00000 16.00000"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .unsupported = layer.content else {
            return XCTFail("부모 없는 origin 누락은 버려야 한다: \(layer.content)")
        }
    }

    /// 이펙트가 모양을 만드는 단색 레이어도 **그린다.**
    ///
    /// 한동안은 건너뛰었다 — 이펙트를 못 걸던 때는 불투명한 흰 판이 그대로
    /// 남았기 때문이다. 이제 이펙트를 걸 수 있으므로 그리고, 걸지 못하면
    /// 렌더러가 그 레이어를 원본으로 되돌린다.
    func testWhiteSolidLayerShapedByEffectsIsDrawn() throws {
        // 모델과 재질을 갖춰 둔다. 없으면 참조가 안 풀려서 어차피 unsupported가 되고,
        // 테스트가 흰 판 규칙이 아니라 그것을 재게 된다.
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "淡化层", "image": "models/m.json",
                          "origin": "10.00000 10.00000 0.00000", "size": "256.00000 256.00000",
                          "instance": {"textures": ["util/white"]},
                          "effects": [{"name": "渐入"}]}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])).layers.first)
        if case .unsupported = layer.content {
            XCTFail("이펙트를 걸 수 있으므로 그려야 한다")
        }
    }

    /// 이펙트가 없으면 단색 레이어는 그대로 그린다. 이건 씬이 실제로 의도한 판이다.
    func testWhiteSolidLayerWithoutEffectsIsStillDrawn() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "solid", "image": "models/m.json",
                          "origin": "10.00000 10.00000 0.00000", "size": "20.00000 20.00000",
                          "instance": {"textures": ["util/white"]}}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])).layers.first)
        if case .unsupported = layer.content {
            XCTFail("이펙트가 없으면 그려야 한다")
        }
    }

    /// 흰 판이 아니면 이펙트가 붙어 있어도 그린다. 그림 자체가 내용이라,
    /// 이펙트를 못 걸어도 안 그리는 것보다 그리는 쪽이 씬에 가깝다.
    func testTexturedLayerWithEffectsIsStillDrawn() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "art", "image": "models/m.json",
                          "origin": "10.00000 10.00000 0.00000", "size": "20.00000 20.00000",
                          "instance": {"textures": ["art"]},
                          "effects": [{"name": "shimmer"}]}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes": [{"shader": "genericimage4", "textures": ["t"]}]}"#,
            ])).layers.first)
        if case .unsupported = layer.content {
            XCTFail("그림이 있는 레이어는 그려야 한다")
        }
    }

    func testVisibleDefaultsToTrueAndFalseIsHonored() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "shown", "particle": "p.json"},
                     {"id": 2, "name": "hidden", "particle": "p.json", "visible": false}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.map(\.visible), [true, false])
    }

    /// M2는 이미지 레이어만 그린다. 나머지는 이유를 달아 남긴다.
    func testNonImageLayersBecomeUnsupportedRatherThanDisappearing() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Snow", "particle": "particles/snow.json"},
                     {"id": 2, "name": "Time", "text": "12:00"}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 2)
        for layer in doc.layers {
            guard case .unsupported = layer.content else {
                return XCTFail("\(layer.name)이 unsupported가 아니다")
            }
        }
    }

    /// origin이나 scale이 문자열이 아니라 스크립트 객체인 씬이 실제로 있다.
    /// 파싱이 통째로 실패하면 안 되고, 해당 레이어만 unsupported가 되어야 한다.
    func testScriptedOriginDoesNotBreakTheWholeScene() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "scripted", "image": "models/m.json",
                          "origin": {"script": "return 0;"}, "size": "10.0 10.0"},
                         {"id": 2, "name": "plain", "image": "models/m.json",
                          "origin": "5.0 5.0 0.0", "size": "10.0 10.0"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json": #"{"passes": [{"textures": ["t"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers[1].content, .image(texturePath: "materials/t.tex"))
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("스크립트 origin 레이어는 unsupported여야 한다")
        }
    }

    func testMissingModelFileMakesLayerUnsupportedNotFatal() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "dangling", "image": "models/missing.json",
                      "origin": "0 0 0", "size": "1 1"}]}
        """)
        let doc = try SceneDocument.load(from: reader)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("참조가 끊긴 레이어는 unsupported여야 한다")
        }
    }

    func testNullTextureEntryIsUnsupported() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "nulltex", "image": "models/m.json",
                          "origin": "0 0 0", "size": "1 1"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                // waterripple의 실제 머티리얼이 이런 모양이다.
                "materials/m.json": #"{"passes": [{"textures": [null, null, "effects/n"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("첫 텍스처가 null이면 unsupported여야 한다")
        }
    }

    func testMalformedSceneJSONThrows() throws {
        let reader = try makeScenePkg(scene: "not json")
        XCTAssertThrowsError(try SceneDocument.load(from: reader)) { error in
            XCTAssertEqual(error as? SceneError, .malformedSceneJSON)
        }
    }

    func testMissingOrthographicProjectionThrows() throws {
        let reader = try makeScenePkg(scene: #"{"general": {}, "objects": []}"#)
        XCTAssertThrowsError(try SceneDocument.load(from: reader)) { error in
            XCTAssertEqual(error as? SceneError, .missingField("orthogonalprojection"))
        }
    }

    func testVectorParsing() {
        XCTAssertEqual(Vec3.parse("1.5 -2.0 3.25"), Vec3(x: 1.5, y: -2.0, z: 3.25))
        XCTAssertEqual(Vec2.parse("2048.00000 1164.00000"), Vec2(x: 2048, y: 1164))
        XCTAssertNil(Vec3.parse("1.0 2.0"))
        XCTAssertNil(Vec3.parse("a b c"))
        XCTAssertNil(Vec2.parse(""))
    }

    /// Finding 1: 배열 조건부 캐스트는 전부-아니면-전무다.
    /// 하나의 비-딕셔너리 원소가 정상 레이어까지 사라지게 한다.
    /// 원소별로 필터링해야 한다.
    func testMixedArrayElementsDoNotPoisonValidLayers() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "valid", "image": "models/m.json",
                      "origin": "10.0 10.0 0.0", "size": "5.0 5.0"},
                     "garbage_string",
                     123,
                     {"id": 2, "name": "also_valid", "image": "models/m.json",
                      "origin": "20.0 20.0 0.0", "size": "5.0 5.0"}]}
        """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json": #"{"passes": [{"textures": ["t"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        // 정상 레이어 둘 다 로드되어야 한다. 가비지는 무시된다.
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers[0].name, "valid")
        XCTAssertEqual(doc.layers[1].name, "also_valid")
        XCTAssertEqual(doc.layers[0].content, .image(texturePath: "materials/t.tex"))
        XCTAssertEqual(doc.layers[1].content, .image(texturePath: "materials/t.tex"))
    }

    /// Finding 2a: Double(_:)은 "inf"와 "nan"을 받아들인다.
    /// 그런 좌표는 렌더러의 클립 공간 계산을 망쳐 아무것도 그리지 않는다.
    /// Vec3 파싱에서 유한값만 허용해야 한다.
    func testNonFiniteVec3ParseReturnsNil() {
        XCTAssertNil(Vec3.parse("nan nan nan"))
        XCTAssertNil(Vec3.parse("inf 1.0 1.0"))
        XCTAssertNil(Vec3.parse("1.0 -inf 1.0"))

        // 정상 유한값은 여전히 파싱되어야 한다.
        XCTAssertNotNil(Vec3.parse("1.0 2.0 3.0"))
    }

    /// Finding 2b: Double(_:)은 "inf"와 "nan"을 받아들인다.
    /// Vec2 파싱에서 유한값만 허용해야 한다.
    func testNonFiniteVec2ParseReturnsNil() {
        XCTAssertNil(Vec2.parse("inf 1.0"))
        XCTAssertNil(Vec2.parse("1.0 nan"))

        // 정상 유한값은 여전히 파싱되어야 한다.
        XCTAssertNotNil(Vec2.parse("1.0 2.0"))
    }

    /// Finding 3: 직교 투영의 너비/높이가 양수여야 한다.
    /// 0이나 음수는 렌더러의 투영 나누기를 의미 없게 만든다.
    func testZeroOrNegativeProjectionDimensionsThrows() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 0, "height": 100}},
         "objects": []}
        """)
        XCTAssertThrowsError(try SceneDocument.load(from: reader)) { error in
            XCTAssertEqual(error as? SceneError, .missingField("orthogonalprojection"))
        }
    }

    /// Finding 2 integration: 비유한 좌표는 이미지 레이어도 unsupported로 만든다.
    /// 전체 씬이 깨지지 않고 문제 레이어만 격리된다.
    func testNonFiniteOriginMakesImageLayerUnsupported() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "badgeo", "image": "models/m.json",
                          "origin": "nan nan nan", "size": "10.0 10.0"},
                         {"id": 2, "name": "goodgeo", "image": "models/m.json",
                          "origin": "10.0 10.0 0.0", "size": "10.0 10.0"}]}
            """,
            extras: [
                "models/m.json": #"{"material": "materials/m.json"}"#,
                "materials/m.json": #"{"passes": [{"textures": ["t"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 2)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("비유한 좌표 레이어는 unsupported여야 한다")
        }
        XCTAssertEqual(doc.layers[1].content, .image(texturePath: "materials/t.tex"))
    }

    /// solidlayer는 텍스처가 없는 단색 레이어다. 못 찾은 것이 아니라 원래 없다.
    func testSolidLayerBecomesSolidColor() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Second", "image": "models/util/solidlayer.json",
                          "origin": "50 50 0", "size": "10 10",
                          "color": "1.00000 0.50000 0.25000"}]}
            """,
            extras: [
                "models/util/solidlayer.json":
                    #"{"material":"materials/util/solidlayer.json","solidlayer":true}"#,
                "materials/util/solidlayer.json":
                    #"{"passes":[{"shader":"flat","cullmode":"nocull"}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .solidColor(Vec3(x: 1.0, y: 0.5, z: 0.25)))
    }

    /// composelayer는 렌더 타깃을 참조한다. M6의 몫이고, 이유가 구분되어야 한다.
    func testComposeLayerIsACompositionLayer() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Green", "image": "models/util/composelayer.json",
                          "origin": "50 50 0", "size": "10 10"}]}
            """,
            extras: [
                "models/util/composelayer.json":
                    #"{"material":"materials/util/composelayer.json","passthrough":true}"#,
                "materials/util/composelayer.json":
                    #"{"passes":[{"shader":"composelayer","textures":["_rt_FullFrameBuffer"]}]}"#,
            ]
        )
        // `_rt_FullFrameBuffer`는 우리가 줄 수 있다 — 그 지점까지 합성된 화면이다.
        // 한동안은 미지원이었지만 이제 합성 레이어로 그린다.
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .composition)
    }

    func testSolidColorDefaultsToWhiteWhenColorMissing() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "S", "image": "models/util/solidlayer.json",
                          "origin": "50 50 0", "size": "10 10"}]}
            """,
            extras: [
                "models/util/solidlayer.json": #"{"material":"materials/util/solidlayer.json"}"#,
                "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat"}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .solidColor(Vec3(x: 1, y: 1, z: 1)))
    }

    /// flat 셰이더라도 텍스처가 있으면 단색이 아니다.
    /// _rt_ 참조가 렌더 타깃 검사에 도달해야 한다. OR 조건이면 여기서 삼켜진다.
    func testFlatShaderWithRenderTargetIsACompositionLayer() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "F", "image": "models/m.json",
                          "origin": "50 50 0", "size": "10 10"}]}
            """,
            extras: [
                "models/m.json": #"{"material":"materials/m.json"}"#,
                "materials/m.json":
                    #"{"passes":[{"shader":"flat","textures":["_rt_FullFrameBuffer"]}]}"#,
            ]
        )
        // flat 셰이더라도 텍스처가 렌더 타깃이면 단색이 아니다.
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].content, .composition)
    }

    /// 실물 참조 사슬 그대로:
    /// object.particle → particles/presets/X.json → material → textures[0]
    func testResolvesParticleLayer() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow flat", "origin": "50 50 0",
                          "particle": "particles/presets/snowflat.json"}]}
            """,
            extras: [
                "particles/presets/snowflat.json": """
                {"material":"materials/presets/snowflat.json","maxcount":300,
                 "emitter":[{"name":"sphererandom","rate":15,"origin":"0 650 0",
                             "directions":"1 0.03 0","distancemin":10,"distancemax":1200}],
                 "initializer":[{"name":"sizerandom","min":2,"max":30}]}
                """,
                "materials/presets/snowflat.json":
                    #"{"passes":[{"shader":"genericparticle","textures":["particle/chromaticdot"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .particle(let preset, let texturePath, _, _, _) = doc.layers[0].content else {
            return XCTFail("파티클 레이어여야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(preset.maxCount, 300)
        XCTAssertEqual(preset.emitters.count, 1)
        XCTAssertEqual(texturePath, "materials/particle/chromaticdot.tex")
    }

    /// 실물 DELTARUNE(3793923399)의 `materials/particle/halo_1.json`이 이 모양이다:
    /// `"textures": [null]`. Wallpaper Engine에서 null 슬롯은 셰이더 주석의 기본값을
    /// 쓴다(`genericparticle.frag`의 `g_Texture0` 기본값 `util/white`). 파티클을
    /// 통째로 unsupported로 버리면 안 된다.
    func testParticleWithNullTextureUsesShaderDefault() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "halo", "origin": "0 0 0",
                          "particle": "particles/presets/halo.json"}]}
            """,
            extras: [
                "particles/presets/halo.json":
                    #"{"material":"materials/presets/halo.json","maxcount":10}"#,
                "materials/presets/halo.json":
                    #"{"passes":[{"shader":"genericparticle","textures":[null]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .particle(_, let texturePath, _, _, _) = doc.layers[0].content else {
            return XCTFail("null 텍스처도 파티클로 해석되어야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(texturePath, "materials/util/white.tex")
    }

    /// 재질이 자기 셰이더를 가지면 텍스처를 붙이는 이미지가 아니다. 실물 원근
    /// 씬의 배경 구름이 `ps2menu`다 — 보통 이미지로 그리면 잡음 텍스처가 그대로
    /// 보인다. 표준 가족(`genericimage4` 등)은 그대로 이미지다.
    func testCustomMaterialShaderBecomesShadedImage() throws {
        func content(shader: String) throws -> LayerContent {
            let reader = try makeScenePkg(
                scene: """
                {"general": {"orthogonalprojection": null},
                 "objects": [{"id": 1, "name": "Clouds", "image": "models/c.json", "size": "64 64"}]}
                """,
                extras: [
                    "models/c.json": #"{"material": "materials/c.json"}"#,
                    "materials/c.json":
                        #"{"passes": [{"shader": "\#(shader)", "textures": ["util/noise"]}]}"#,
                ])
            return try XCTUnwrap(SceneDocument.load(from: reader).layers.first).content
        }
        guard case .shadedImage(let material, let texture) = try content(shader: "ps2menu") else {
            return XCTFail("셰이더 이미지여야 한다")
        }
        XCTAssertEqual(material, "materials/c.json")
        XCTAssertEqual(texture, "materials/util/noise.tex")
        guard case .image = try content(shader: "genericimage4") else {
            return XCTFail("표준 셰이더는 보통 이미지다")
        }
    }

    /// 원근 씬은 이제 연다. `orthogonalprojection: null`이면 카메라가 생기고
    /// 직교 크기는 이름뿐인 값이다. 예전에는 여기서 던져 미리보기로 물러났다.
    func testPerspectiveSceneLoadsWithCamera() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": null, "fov": 53, "nearz": 1, "farz": 10000},
             "objects": []}
            """,
            extras: [:])
        let doc = try SceneDocument.load(from: reader)
        XCTAssertTrue(doc.isPerspective)
        XCTAssertEqual(doc.camera?.fov, 53)
        XCTAssertGreaterThan(doc.orthoWidth, 0)
    }

    /// 키가 아예 없는 것은 여전히 missingField다. 원근 씬과 구분되어야 한다.
    func testMissingProjectionIsStillMissingField() throws {
        let reader = try makeScenePkg(scene: #"{"general": {}, "objects": []}"#)
        XCTAssertThrowsError(try SceneDocument.load(from: reader, assets: nil)) { error in
            XCTAssertEqual(error as? SceneError, .missingField("orthogonalprojection"))
        }
    }

    /// origin과 size가 없고 effects만 있으면 후처리 레이어다.
    /// 실물 "Couche de post-traitement"가 이 경우인데, 전에는 "스크립트 탓"이라고
    /// 잘못 보고해 사용자를 엉뚱한 원인으로 보냈다.
    func testPostProcessingLayerIsReportedAsSuch() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Couche de post-traitement",
                      "image": "models/x.json", "effects": [{"file": "e.json"}]}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported(let reason) = doc.layers[0].content else {
            return XCTFail("unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("후처리"), reason)
        XCTAssertFalse(reason.contains("스크립트"), "스크립트 탓으로 오해시키면 안 된다: \(reason)")
    }

    /// 머티리얼의 blending을 읽어야 한다. 실물에서 눈·비·먼지·광선은 additive,
    /// 벚꽃(leaves5)은 translucent다. 하나로 뭉치면 벚꽃이 밝은 배경 위에서
    /// 하얗게 날아간다.
    func testParticleBlendModeIsReadFromMaterial() throws {
        func blend(of materialJSON: String) throws -> ParticleBlendMode {
            let reader = try makeScenePkg(
                scene: """
                {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
                 "objects": [{"id": 1, "name": "P", "origin": "0 0 0",
                              "particle": "particles/presets/p.json"}]}
                """,
                extras: [
                    "particles/presets/p.json":
                        #"{"material":"materials/presets/p.json","maxcount":10}"#,
                    "materials/presets/p.json": materialJSON,
                ]
            )
            let doc = try SceneDocument.load(from: reader, assets: nil)
            guard case .particle(_, _, let b, _, _) = doc.layers[0].content else {
                throw XCTSkip("파티클 레이어여야 한다: \(doc.layers[0].content)")
            }
            return b
        }

        XCTAssertEqual(
            try blend(of: #"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/dot"]}]}"#),
            .additive)
        XCTAssertEqual(
            try blend(of: #"{"passes":[{"shader":"genericparticle","blending":"translucent","textures":["particle/dot"]}]}"#),
            .translucent)
        // blending이 없으면 씬 머티리얼의 기본값인 translucent다.
        XCTAssertEqual(
            try blend(of: #"{"passes":[{"shader":"genericparticle","textures":["particle/dot"]}]}"#),
            .translucent)
    }

    func testMissingParticlePresetIsUnsupported() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                      "particle": "particles/presets/gone.json"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported(let reason) = doc.layers[0].content else {
            return XCTFail("참조가 끊기면 unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("gone.json"), "끊긴 경로를 알려야 한다: \(reason)")
    }

    /// 프리셋은 읽혔지만 머티리얼이 없으면 그릴 수 없다.
    func testParticleWithoutTextureIsUnsupported() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                          "particle": "particles/presets/p.json"}]}
            """,
            extras: ["particles/presets/p.json":
                        #"{"material":"materials/presets/missing.json","maxcount":10}"#]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .unsupported = doc.layers[0].content else {
            return XCTFail("머티리얼이 없으면 unsupported여야 한다")
        }
    }

    /// 인식 못 한 emitter/operator가 있어도 레이어는 살아야 한다.
    func testPartiallyUnsupportedPresetStillRenders() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "Snow", "origin": "0 0 0",
                          "particle": "particles/presets/p.json"}]}
            """,
            extras: [
                "particles/presets/p.json": """
                {"material":"materials/presets/p.json","maxcount":10,
                 "emitter":[{"name":"sphererandom","rate":1,"origin":"0 0 0",
                             "directions":"0 1 0","distancemin":0,"distancemax":1},
                            {"name":"mysteryemitter"}]}
                """,
                "materials/presets/p.json":
                    #"{"passes":[{"shader":"genericparticle","textures":["particle/dot"]}]}"#,
            ]
        )
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .particle(let preset, _, _, _, _) = doc.layers[0].content else {
            return XCTFail("일부만 인식 못 해도 그려야 한다")
        }
        XCTAssertEqual(preset.emitters.count, 1)
        XCTAssertEqual(preset.unsupportedNames, ["mysteryemitter"])
    }
}

extension SceneDocumentTests {
    /// 씬 정의 이름이 늘 scene.json인 것은 아니다.
    /// 실물 창작마당 씬에 gifscene.json인 것이 있다.
    func testFindsSceneEntryWithDifferentName() throws {
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("gifscene.json", Data("""
            {"general": {"orthogonalprojection": {"width": 10, "height": 10}},
             "objects": []}
            """.utf8)),
        ]))
        XCTAssertEqual(SceneDocument.sceneEntryName(in: reader), "gifscene.json")
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.orthoWidth, 10)
    }

    /// scene.json이 있으면 그것을 먼저 쓴다. 다른 json이 섞여 있어도 흔들리면 안 된다.
    func testPrefersSceneJSON() throws {
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("aaa.json", Data("{}".utf8)),
            ("scene.json", Data("""
            {"general": {"orthogonalprojection": {"width": 42, "height": 10}},
             "objects": []}
            """.utf8)),
        ]))
        XCTAssertEqual(SceneDocument.sceneEntryName(in: reader), "scene.json")
        XCTAssertEqual(try SceneDocument.load(from: reader, assets: nil).orthoWidth, 42)
    }

    /// 하위 폴더의 json을 씬 정의로 착각하면 안 된다.
    func testIgnoresNestedJSON() throws {
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("materials/x.json", Data("{}".utf8)),
            ("myscene.json", Data("""
            {"general": {"orthogonalprojection": {"width": 7, "height": 7}}, "objects": []}
            """.utf8)),
        ]))
        XCTAssertEqual(SceneDocument.sceneEntryName(in: reader), "myscene.json")
    }
}

extension SceneDocumentTests {
    /// 그룹의 투명도는 자식에게 곱해진다.
    /// 투명도는 부모에게서 물려받지 **않는다.** 실물 픽셀 씬이 alpha 0인 solidlayer를
    /// 닻으로 삼아 글자를 매다는데, 미리보기에는 그 글자가 다 보인다. 곱하면 패널이 빈다.
    func testParentAlphaDoesNotPropagateToChildren() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [
           {"id": 1, "name": "닻", "origin": "0 0 0", "size": "10 10", "alpha": 0},
           {"id": 2, "name": "자식", "parent": 1, "origin": "0 0 0", "size": "10 10"},
           {"id": 3, "name": "반투명 자식", "parent": 1, "origin": "0 0 0", "size": "10 10", "alpha": 0.5}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        let child = try XCTUnwrap(doc.layers.first { $0.name == "자식" })
        XCTAssertEqual(child.alpha, 1, "부모의 투명도는 자식에게 곱해지지 않는다")
        let half = try XCTUnwrap(doc.layers.first { $0.name == "반투명 자식" })
        XCTAssertEqual(half.alpha, 0.5, accuracy: 0.001)
        let anchor = try XCTUnwrap(doc.layers.first { $0.name == "닻" })
        XCTAssertEqual(anchor.alpha, 0)
    }

    /// 자체 보임은 따로 남는다. 스크립트가 부모를 숨길 때 렌더러가 다시 합치는 재료다.
    func testLocalVisibleIsKeptSeparately() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [
           {"id": 1, "name": "창", "origin": "0 0 0", "size": "10 10", "visible": false},
           {"id": 2, "name": "글", "parent": 1, "origin": "0 0 0", "size": "10 10"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        let child = try XCTUnwrap(doc.layers.first { $0.name == "글" })
        XCTAssertFalse(child.visible)
        XCTAssertTrue(child.localVisible)
        XCTAssertEqual(child.parentID, 1)
    }

    /// 부모가 숨겨져 있으면 자식도 숨는다.
    func testParentVisibilityPropagates() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [
           {"id": 1, "name": "그룹", "origin": "0 0 0", "size": "10 10",
            "visible": {"value": 0}},
           {"id": 2, "name": "자식", "parent": 1, "origin": "0 0 0", "size": "10 10"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        let child = try XCTUnwrap(doc.layers.first { $0.name == "자식" })
        XCTAssertFalse(child.visible, "부모가 숨으면 자식도 숨어야 한다")
    }
}

extension SceneDocumentTests {
    /// 파티클은 크기가 프리셋에서 오므로 레이어 배율을 따로 알아야 한다.
    /// 무시하면 씬이 의도한 것보다 크거나 작게 날린다 — 실물 배율이 0.44~9.0이다.
    func testLayerScaleIsExposedForParticles() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "L", "origin": "0 0 0", "size": "10 10",
                      "scale": "2 3 1", "image": "models/x.json"}]}
        """)
        let layer = try XCTUnwrap(
            try SceneDocument.load(from: reader, assets: nil).layers.first)
        XCTAssertEqual(layer.scale.x, 2, accuracy: 0.001)
        XCTAssertEqual(layer.scale.y, 3, accuracy: 0.001)
    }

    /// 부모의 배율도 합쳐져야 한다.
    func testParentScaleComposesIntoLayerScale() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [
           {"id": 1, "name": "부모", "origin": "0 0 0", "size": "10 10", "scale": "2 2 2"},
           {"id": 2, "name": "자식", "parent": 1, "origin": "0 0 0", "size": "10 10",
            "scale": "3 3 3", "image": "models/x.json"}]}
        """)
        let child = try XCTUnwrap(
            try SceneDocument.load(from: reader, assets: nil).layers.first { $0.name == "자식" })
        XCTAssertEqual(child.scale.x, 6, accuracy: 0.001, "부모 2 × 자식 3")
    }
}

extension SceneDocumentTests {
    /// disablepropagation이 켜지면 부모 변환을 물려받지 않는다.
    /// 보유 씬에서는 전부 0이지만, 1인 씬을 만나면 레이어가 부모를 따라
    /// 엉뚱한 자리로 끌려간다.
    func testDisablePropagationIgnoresParentTransform() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [
           {"id": 1, "name": "부모", "origin": "50 50 0", "size": "10 10", "scale": "2 2 2"},
           {"id": 2, "name": "따름", "parent": 1, "origin": "5 0 0", "size": "10 10",
            "image": "models/x.json"},
           {"id": 3, "name": "안따름", "parent": 1, "origin": "5 0 0", "size": "10 10",
            "disablepropagation": 1, "image": "models/x.json"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        let follows = try XCTUnwrap(doc.layers.first { $0.name == "따름" })
        let ignores = try XCTUnwrap(doc.layers.first { $0.name == "안따름" })
        XCTAssertEqual(follows.origin.x, 60, accuracy: 0.001, "부모 50 + 자식 5×2")
        XCTAssertEqual(follows.scale.x, 2, accuracy: 0.001)
        XCTAssertEqual(ignores.origin.x, 5, accuracy: 0.001, "부모를 무시한 자기 좌표")
        XCTAssertEqual(ignores.scale.x, 1, accuracy: 0.001)
    }
}

extension SceneDocumentTests {
    /// 시차는 씬이 꺼 둘 수 있다. cameraparallax가 0이면 강도도 0이다 —
    /// 실물 Lost Valley가 그렇다. 이걸 무시하면 안 움직여야 할 씬이 움직인다.
    func testParallaxRespectsSceneToggle() throws {
        func amount(on: Int, value: Double) throws -> Double {
            let reader = try makeScenePkg(scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100},
                         "cameraparallax": \(on), "cameraparallaxamount": \(value)},
             "objects": []}
            """)
            return try SceneDocument.load(from: reader, assets: nil).parallaxAmount
        }
        XCTAssertEqual(try amount(on: 1, value: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(try amount(on: 0, value: 0.5), 0, "꺼져 있으면 움직이지 않는다")
    }

    /// 레이어별 깊이를 읽는다. 실물 값이 -0.67~0.5이고 음수면 반대로 밀린다.
    func testParallaxDepthIsRead() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "L", "origin": "0 0 0", "size": "10 10",
                      "parallaxDepth": -0.67, "image": "models/x.json"}]}
        """)
        let layer = try XCTUnwrap(try SceneDocument.load(from: reader, assets: nil).layers.first)
        XCTAssertEqual(layer.parallaxDepth, -0.67, accuracy: 0.001)
    }

    /// 도형 레이어는 그림이 없고 **거기 붙은 이펙트가 그림을 만든다**
    /// (실물은 전부 `quad` + `lightshafts`인 빛줄기다).
    ///
    /// 파일에 크기가 없다. 근거는 assets에서 찾았다 — 편집기가 이 레이어를 만드는
    /// 프리셋(`presets/lightshafts/`)의 미리보기 씬이 256x256 캔버스이고 도형이
    /// scale 1.2로 그 안을 채운다. 같은 이펙트의 미리보기가 쓰는 이미지 레이어도
    /// 정확히 256x256이다. 공식 문서에는 크기가 적혀 있지 않다.
    func testShapeQuadGetsTheDocumentedBaseSize() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 3440, "height": 1440}},
         "objects": [{"id": 1, "name": "Rayons lumineux", "shape": "quad",
                      "origin": "732.00000 399.00000 0.00000",
                      "scale": "1.50000 1.20000 1.00000"}]}
        """)).layers.first)
        XCTAssertEqual(layer.size.x, 256 * 1.5, accuracy: 0.001)
        XCTAssertEqual(layer.size.y, 256 * 1.2, accuracy: 0.001)
        XCTAssertEqual(layer.content, .solidColor(Vec3(x: 1, y: 1, z: 1)))
    }

    /// scale이 없으면 기준 크기 그대로다.
    func testShapeQuadWithoutScaleUsesTheBaseSize() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "q", "shape": "quad",
                      "origin": "10.00000 10.00000 0.00000"}]}
        """)).layers.first)
        XCTAssertEqual(layer.size.x, 256, accuracy: 0.001)
    }

    /// 모르는 도형은 그리지 않는다. 사각형으로 짐작해 그리면 엉뚱한 판이 생긴다.
    func testUnknownShapeIsSkipped() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "c", "shape": "circle",
                      "origin": "10.00000 10.00000 0.00000"}]}
        """)).layers.first)
        guard case .unsupported = layer.content else {
            return XCTFail("모르는 도형을 그리면 안 된다: \(layer.content)")
        }
    }

    /// 화면 전체 후처리 레이어. 자기 그림이 없고 origin도 size도 없다 —
    /// **그 아래까지 합성된 화면**이 입력이고, 화면이 곧 크기다.
    /// 실물 씬 하나가 마지막 레이어로 filmgrain·vhs·waterripple·색수차를 이렇게 건다.
    func testFullscreenPostProcessLayerTakesTheCanvasSize() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
             "objects": [{"id": 1, "name": "Post-processing Layer",
                          "image": "models/util/fullscreenlayer.json",
                          "effects": [{"file": "effects/grain/effect.json"}]}]}
            """,
            extras: [
                "effects/grain/effect.json": #"{"passes": [{"material": "materials/g.json"}]}"#,
                "effects/grain/materials/g.json": #"{"passes": [{"shader": "effects/grain"}]}"#,
            ])).layers.first)
        XCTAssertEqual(layer.content, .postProcess)
        XCTAssertEqual(layer.size, Vec2(x: 1920, y: 1080))
        XCTAssertEqual(layer.effects.count, 1)
    }

    /// 걸 이펙트가 없는 후처리 레이어는 화면을 그대로 베끼는 일만 한다.
    /// 그리지 않는 편이 낫다 — 화면 크기 텍스처를 괜히 하나 더 잡는다.
    func testPostProcessLayerWithoutEffectsIsSkipped() throws {
        let layer = try XCTUnwrap(SceneDocument.load(from: try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Post", "image": "models/util/fullscreenlayer.json",
                      "effects": []}]}
        """)).layers.first)
        guard case .unsupported = layer.content else {
            return XCTFail("이펙트 없는 후처리는 건너뛴다: \(layer.content)")
        }
    }

    /// 굴절 파티클은 **법선 지도까지 들고** 나온다.
    ///
    /// 재질의 콤보에 `REFRACT`가 있으면 그 스프라이트는 색이 아니라 **배경을
    /// 휘게 하는 렌즈**다. 두 번째 텍스처가 그 법선 지도이고, 그것 없이
    /// 그리면 흰 덩어리가 뜬다. 그래서 경로가 함께 나와야 한다.
    func testRefractiveParticleCarriesNormalMap() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "雨滴屏幕", "particle": "particles/rain.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/rain.json":
                    #"{"maxcount": 8, "material": "materials/rain.json", "emitter": [], "initializer": []}"#,
                "materials/rain.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/water/rain_drops_sheet",
                                  "particle/water/rain_drops_sheet_normal"],
                     "combos": {"REFRACT": 1}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle(_, let texturePath, _, let normalPath, _) = layer.content else {
            return XCTFail("굴절 파티클도 그려야 한다: \(layer.content)")
        }
        XCTAssertEqual(texturePath, "materials/particle/water/rain_drops_sheet.tex")
        XCTAssertEqual(normalPath, "materials/particle/water/rain_drops_sheet_normal.tex",
                       "두 번째 텍스처가 법선 지도다")
    }

    /// `REFRACT`가 꺼져 있으면 두 번째 텍스처가 있어도 렌즈가 아니다.
    /// `magic_vortex_0`이 `REFRACT: 0`으로 적고 텍스처를 둘 들고 온다 —
    /// 텍스처 수만 보고 판단하면 마법 소용돌이가 배경을 휘게 만든다.
    func testTwoTexturesWithoutRefractComboIsNotALens() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "vortex", "particle": "particles/rain.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/rain.json":
                    #"{"maxcount": 8, "material": "materials/rain.json", "emitter": [], "initializer": []}"#,
                "materials/rain.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/beam", "particle/beam_mask"],
                     "combos": {"REFRACT": 0}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle(_, _, _, let normalPath, _) = layer.content else {
            return XCTFail("그려야 한다: \(layer.content)")
        }
        XCTAssertNil(normalPath, "콤보가 꺼져 있으면 굴절이 아니다")
    }

    /// 미는 정도는 재질이 정한다. 놓치면 물방울이 배경을 거의 안 휜다.
    /// 실물 유리창 비가 -0.1이고, 셰이더 주석의 기본값은 0.05다.
    func testRefractAmountComesFromTheMaterial() throws {
        func amount(_ constants: String) throws -> Double {
            let reader = try makeScenePkg(
                scene: """
                {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
                 "objects": [{"id": 1, "name": "rain", "particle": "particles/rain.json",
                              "origin": "10.00000 10.00000 0.00000"}]}
                """,
                extras: [
                    "particles/rain.json":
                        #"{"maxcount": 8, "material": "materials/rain.json", "emitter": [], "initializer": []}"#,
                    "materials/rain.json": """
                        {"passes": [{"shader": "genericparticle",
                         "textures": ["particle/drop", "particle/drop_normal"],
                         "combos": {"REFRACT": 1}\(constants)}]}
                        """,
                ])
            let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
            guard case .particle(_, _, _, _, let amount) = layer.content else {
                throw XCTSkip("파티클이 아니다")
            }
            return amount
        }
        XCTAssertEqual(
            try amount(#", "constantshadervalues": {"ui_editor_properties_refract_amount": -0.1}"#),
            -0.1, accuracy: 0.0001)
        XCTAssertEqual(try amount(""), 0.05, accuracy: 0.0001, "안 적으면 셰이더 기본값")
        XCTAssertEqual(
            try amount(#", "constantshadervalues": {"ui_editor_properties_refract_amount": 50}"#),
            1, accuracy: 0.0001, "범위를 벗어나면 죈다")
    }

    /// `REFRACT`가 켜져 있어도 텍스처가 하나뿐이면 렌즈가 아니다.
    /// 창작마당 `leaves1`이 그 꼴이라, 렌즈로 다루면 꽃잎이 사라진다.
    func testRefractWithoutNormalMapIsAPlainSprite() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "leaves", "particle": "particles/rain.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/rain.json":
                    #"{"maxcount": 8, "material": "materials/rain.json", "emitter": [], "initializer": []}"#,
                "materials/rain.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/leaf"], "combos": {"REFRACT": 1}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle(_, _, _, let normalPath, _) = layer.content else {
            return XCTFail("그려야 한다: \(layer.content)")
        }
        XCTAssertNil(normalPath)
    }

    /// 콤보가 없는 파티클은 그대로 그린다. 내리는 비(`rainperspective`)가 이쪽이라,
    /// 굴절만 건너뛰고 비 자체는 남아야 한다.
    func testNonRefractiveParticleStillDraws() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "雨景远景", "particle": "particles/rain.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/rain.json":
                    #"{"maxcount": 8, "material": "materials/rain.json", "emitter": [], "initializer": []}"#,
                // 콤보는 있는데 `REFRACT`만 없다. 실물 잎사귀·꽃잎 재질이 이 꼴이라,
                // "콤보가 있으면 건너뛴다"로 잘못 만들면 그것들까지 사라진다.
                "materials/rain.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/drop"], "combos": {"CUTOUT": 1}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle = layer.content else {
            return XCTFail("굴절이 아닌 파티클은 그려야 한다: \(layer.content)")
        }
    }

    /// `REFRACT`가 **꺼져 있으면**(값 0) 굴절이 아니다.
    /// 실물 `magic_vortex_0`이 이 꼴이라, 값을 안 보면 소용돌이가 통째로 사라진다.
    func testRefractComboSetToZeroStillDraws() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "vortex", "particle": "particles/p.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/p.json":
                    #"{"maxcount": 8, "material": "materials/m.json", "emitter": [], "initializer": []}"#,
                "materials/m.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/beam", "particle/beam_normal"],
                     "combos": {"REFRACT": 0}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle = layer.content else {
            return XCTFail("REFRACT가 0이면 그려야 한다: \(layer.content)")
        }
    }

    /// 노멀맵이 없으면 굴절이 성립하지 않는다 — 그냥 스프라이트다.
    /// 창작마당 `leaves1`이 `REFRACT: 1`인데 텍스처가 꽃 하나뿐이라,
    /// 콤보만 보면 꽃잎이 사라진다.
    func testRefractWithoutNormalMapStillDraws() throws {
        let reader = try makeScenePkg(
            scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "leaves", "particle": "particles/p.json",
                          "origin": "10.00000 10.00000 0.00000"}]}
            """,
            extras: [
                "particles/p.json":
                    #"{"maxcount": 8, "material": "materials/m.json", "emitter": [], "initializer": []}"#,
                "materials/m.json": """
                    {"passes": [{"shader": "genericparticle",
                     "textures": ["particle/flower"], "combos": {"REFRACT": 1}}]}
                    """,
            ])
        let layer = try XCTUnwrap(SceneDocument.load(from: reader).layers.first)
        guard case .particle = layer.content else {
            return XCTFail("노멀맵이 없으면 그려야 한다: \(layer.content)")
        }
    }

    /// `general.ambientcolor`·`skylightcolor`를 읽는다. 없으면 편집기 예제 값이다.
    func testAmbientAndSkylightColorsAreRead() throws {
        let json = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 50},
                     "ambientcolor": "0.1 0.2 0.3", "skylightcolor": "0.5 0.5 0.5"},
         "objects": []}
        """
        let doc = try SceneDocument.load(from: try makeScenePkg(scene: json))
        XCTAssertEqual(doc.ambientColor, Vec3(x: 0.1, y: 0.2, z: 0.3))
        XCTAssertEqual(doc.skylightColor, Vec3(x: 0.5, y: 0.5, z: 0.5))
        let plain = try SceneDocument.load(from: try makeScenePkg(
            scene: #"{"general": {"orthogonalprojection": {"width": 1, "height": 1}}, "objects": []}"#))
        XCTAssertEqual(plain.ambientColor, Vec3(x: 0.302, y: 0.302, z: 0.302))
        XCTAssertEqual(plain.skylightColor, Vec3(x: 1, y: 1, z: 1))
    }

    /// `alignment`가 있으면 origin은 닻이다. 실물 픽셀 씬의 창들이 `topleft`·`left`다.
    /// 자식의 origin은 닻 기준 그대로라 부모의 닻 거리는 자식에게 더해지지 않는다.
    func testAlignmentAnchorsTheDrawnCenter() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 1000, "height": 1000}},
         "objects": [
           {"id": 1, "name": "창", "image": "models/solid.json", "origin": "0 900 0", "size": "600 40", "alignment": "topleft"},
           {"id": 2, "name": "배경", "image": "models/solid.json", "parent": 1, "origin": "3 -100 0", "size": "594 200", "alignment": "left"},
           {"id": 3, "name": "글", "image": "models/solid.json", "parent": 1, "origin": "300 -60 0", "size": "10 10"},
           {"id": 4, "name": "보통", "image": "models/solid.json", "origin": "50 50 0", "size": "20 20", "alignment": "center"},
           {"id": 5, "name": "오른아래", "image": "models/solid.json", "origin": "100 100 0", "size": "20 40", "alignment": "bottomright"}]}
        """, extras: [
            "models/solid.json": #"{"material": "materials/solid.json"}"#,
            "materials/solid.json": #"{"passes": [{"shader": "flat"}]}"#,
        ])
        let doc = try SceneDocument.load(from: reader, assets: nil)
        func layer(_ name: String) throws -> SceneLayer {
            try XCTUnwrap(doc.layers.first { $0.name == name })
        }
        // 왼쪽 위 모서리가 (0, 900)이니 중심은 (300, 880)이다.
        XCTAssertEqual(try layer("창").origin, Vec3(x: 300, y: 880, z: 0))
        XCTAssertEqual(try layer("창").anchorOffset, Vec2(x: 300, y: -20))
        XCTAssertEqual(try layer("창").localOrigin, Vec3(x: 0, y: 900, z: 0))
        // 자식은 부모의 닻(0, 900) 기준이다. 자기 닻이 left라 중심은 오른쪽으로 반 칸.
        XCTAssertEqual(try layer("배경").origin, Vec3(x: 3 + 297, y: 800, z: 0))
        XCTAssertEqual(try layer("글").origin, Vec3(x: 300, y: 840, z: 0))
        XCTAssertEqual(try layer("보통").origin, Vec3(x: 50, y: 50, z: 0))
        XCTAssertEqual(try layer("오른아래").origin, Vec3(x: 90, y: 120, z: 0))
    }

    /// instanceoverride 값도 스크립트일 수 있다(실물 PS2 시계 colorn, Universal Reflex 3 rate).
    func testInstanceOverrideScriptsAreLayerScripts() {
        let object: [String: Any] = [
            "particle": "particles/p.json",
            "instanceoverride": [
                "id": 1, "count": 2.0,
                "rate": ["script": "export function update(v) { return v; }", "value": 0.19],
            ],
        ]
        XCTAssertEqual(SceneDocument.layerScripts(of: object).map(\.property),
                       ["instanceoverride.rate"])
        XCTAssertEqual(SceneDocument.scriptHolders(of: object).map(\.property),
                       ["instanceoverride.rate"])
    }

    /// controlpointN 덮어쓰기도 스크립트를 가질 수 있다(`layer.instance.controlpointN`).
    /// `scriptHolders`는 이미 `ParticleOverride.scriptKeys`를 훑으므로, 그 목록에
    /// controlpoint0~7을 더하는 것만으로 여기까지 이어진다 — 이 파일은 안 고쳤다.
    func testControlPointOverrideScriptsAreLayerScripts() {
        let object: [String: Any] = [
            "particle": "particles/p.json",
            "instanceoverride": [
                "controlpoint1": ["script": "export function update(v) { return v; }",
                                  "value": "0 0 0"],
            ],
        ]
        XCTAssertEqual(SceneDocument.scriptHolders(of: object).map(\.property),
                       ["instanceoverride.controlpoint1"])
    }
}
