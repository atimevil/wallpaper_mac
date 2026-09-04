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
}
