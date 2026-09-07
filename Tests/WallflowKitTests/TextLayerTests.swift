import XCTest
@testable import WallflowKit

final class TextLayerTests: XCTestCase {
    /// 실물 Hiyuki 씬의 Time 레이어를 그대로 옮긴 모양.
    func testParsesScriptedTextLayer() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Time", "origin": "50 50 0", "size": "500 204",
                      "font": "fonts/workshop/3692599672/Monocraft.otf",
                      "color": "0.80000 0.15294 0.31765",
                      "text": {"value": "Time",
                               "script": "export function update(v) { return v; }",
                               "scriptproperties": {"use24hFormat": 1, "showSeconds": 0}}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else {
            return XCTFail("텍스트 레이어여야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(t.value, "Time")
        XCTAssertEqual(t.fontPath, "fonts/workshop/3692599672/Monocraft.otf")
        XCTAssertNotNil(t.script)
        XCTAssertEqual(t.scriptProperties["use24hFormat"], .number(1))
        XCTAssertEqual(t.scriptProperties["showSeconds"], .number(0))
        // 텍스트의 color는 이미 0~1이다. 파티클(0~255)처럼 나누면 안 된다.
        XCTAssertEqual(t.color.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(t.color.y, 0.15294, accuracy: 0.001)
    }

    /// scriptproperties에 문자열이 온다. 수만 담으면 시계가 `00undefined22`로 나온다.
    /// 실물 Hiyuki 씬의 delimiter가 ":"이고, 실제로 이 버그를 화면에서 봤다.
    func testStringScriptPropertyIsKept() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Time", "origin": "0 0 0", "size": "10 10",
                      "font": "f.ttf",
                      "text": {"value": "T", "script": "export function update(v){return v;}",
                               "scriptproperties": {"delimiter": ":", "showSeconds": false,
                                                    "use24hFormat": true, "count": 3}}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
        XCTAssertEqual(t.scriptProperties["delimiter"], .text(":"))
        // JSON의 true/false는 수로 담는다. 자바스크립트에서 0/1과 같게 동작하고,
        // NSNumber 브리징 때문에 정수 0/1과 구분할 수도 없다.
        XCTAssertEqual(t.scriptProperties["showSeconds"], .number(0))
        XCTAssertEqual(t.scriptProperties["use24hFormat"], .number(1))
        XCTAssertEqual(t.scriptProperties["count"], .number(3))
    }

    /// 실물 시계 스크립트를 실물 설정값으로 돌렸을 때 undefined가 섞이면 안 된다.
    /// 이게 화면에서 실제로 났던 버그다.
    func testRealClockScriptProducesNoUndefined() throws {
        let engine = ScriptEngine(
            source: """
            export function update(value) {
                let t = new Date();
                let h = ("00" + t.getHours()).slice(-2);
                let m = ("00" + t.getMinutes()).slice(-2);
                return h + scriptProperties.delimiter + m;
            }
            """,
            properties: ["delimiter": ScriptPropertyValue.text(":").jsValue])
        let result = try XCTUnwrap(engine.update(value: ""))
        XCTAssertFalse(result.contains("undefined"), "구분자가 전달되지 않았다: \(result)")
        XCTAssertTrue(result.contains(":"), result)
    }

    /// 스크립트 없는 고정 텍스트도 있다(실물 "Audio visualizer").
    func testParsesPlainTextLayer() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                      "font": "systemfont_arial", "text": {"value": "____"}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
        XCTAssertNil(t.script)
        XCTAssertEqual(t.value, "____")
        XCTAssertTrue(t.usesSystemFont, "systemfont_*는 파일이 아니라 이름이다")
    }

    /// text가 객체가 아니라 그냥 문자열인 레이어가 있다(실물 "Audio visualizer").
    func testPlainStringTextIsAccepted() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "V", "origin": "0 0 0", "size": "10 10",
                      "font": "systemfont_arial", "text": "______"}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else {
            return XCTFail("텍스트여야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(t.value, "______")
        XCTAssertNil(t.script)
    }

    private func makeScenePkg(scene: String) throws -> PkgReader {
        try PkgReader(data: buildPkg(version: "PKGV0023", entries: [("scene.json", Data(scene.utf8))]))
    }
}

extension TextLayerTests {
    /// 실물에 left·center·right가 모두 나온다. Chisa 씬의 시계가 우측 정렬이다.
    /// 무시하고 가운데로만 두면 글자 수가 바뀔 때마다 제자리에서 벗어난다.
    func testParsesHorizontalAlignment() throws {
        for (raw, want) in [("left", TextAlignment.left), ("right", .right),
                            ("center", .center)] {
            let reader = try makeScenePkg(scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                          "font": "f.ttf", "horizontalalign": "\(raw)",
                          "text": {"value": "x"}}]}
            """)
            let doc = try SceneDocument.load(from: reader, assets: nil)
            guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
            XCTAssertEqual(t.horizontalAlign, want, raw)
        }
    }

    /// 모르는 값이나 없는 경우는 가운데다.
    func testUnknownAlignmentDefaultsToCenter() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                      "font": "f.ttf", "horizontalalign": "justify",
                      "text": {"value": "x"}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
        XCTAssertEqual(t.horizontalAlign, .center)
    }

    /// 실물에 `padding`이 수(양쪽 공통)로도 오고 "x y" 문자열로도 온다.
    func testParsesPadding() throws {
        for (raw, want) in [("32", Vec2(x: 32, y: 32)),
                            ("\"37.00000 37.00000\"", Vec2(x: 37, y: 37)),
                            ("4", Vec2(x: 4, y: 4))] {
            let reader = try makeScenePkg(scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                          "font": "f.ttf", "padding": \(raw),
                          "text": {"value": "x"}}]}
            """)
            let doc = try SceneDocument.load(from: reader, assets: nil)
            guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
            XCTAssertEqual(t.padding, want, raw)
        }
    }

    /// 없으면 여백 0이다 — 옛 씬에도 안전해야 한다.
    func testMissingPaddingDefaultsToZero() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                      "font": "f.ttf", "text": {"value": "x"}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
        XCTAssertEqual(t.padding, Vec2(x: 0, y: 0))
    }

    /// 실물 115개가 전부 false다. 없거나 모르는 값도 false로 둔다.
    func testParsesBlockAlign() throws {
        for (raw, want) in [("true", true), ("false", false)] {
            let reader = try makeScenePkg(scene: """
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "T", "origin": "0 0 0", "size": "10 10",
                          "font": "f.ttf", "blockalign": \(raw),
                          "text": {"value": "x"}}]}
            """)
            let doc = try SceneDocument.load(from: reader, assets: nil)
            guard case .text(let t) = doc.layers[0].content else { return XCTFail("텍스트여야 한다") }
            XCTAssertEqual(t.blockAlign, want, raw)
        }
    }

    /// 텍스트 전용 `anchor`는 "화면(캔버스) 닻"이다. 부모가 없는 레이어에서
    /// 캔버스 가장자리를 기준으로 origin을 다시 잡는다.
    func testTopLevelTextAnchorShiftsOriginToCanvasEdge() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 200, "height": 100}},
         "objects": [{"id": 1, "name": "T", "origin": "10 5 0", "size": "10 10",
                      "font": "f.ttf", "anchor": "topleft",
                      "text": {"value": "x"}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        // 씬 좌표는 원점이 캔버스 왼쪽 아래다. topleft 닻은 (0, 100)이고
        // origin(10, 5)만큼 더한다.
        XCTAssertEqual(doc.layers[0].origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(doc.layers[0].origin.y, 105, accuracy: 0.001)
    }

    /// anchor가 "none"이면(실물 111/115) origin을 그대로 둔다 — 캔버스 중심
    /// 기준의 기존 동작과 같다.
    func testNoneAnchorLeavesOriginUnchanged() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 200, "height": 100}},
         "objects": [{"id": 1, "name": "T", "origin": "10 5 0", "size": "10 10",
                      "font": "f.ttf", "anchor": "none",
                      "text": {"value": "x"}}]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(doc.layers[0].origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(doc.layers[0].origin.y, 5, accuracy: 0.001)
    }

    /// 부모가 있으면 캔버스 닻을 다시 얹지 않는다 — origin이 이미 부모 안에서
    /// 자리를 잡은 값이다(실물 노트패드 하위 텍스트 셋: anchor는 "left"인데
    /// origin이 -319/0/319로 이미 각자 자리를 잡고 있다).
    func testAnchorIgnoredWhenLayerHasParent() throws {
        let reader = try makeScenePkg(scene: """
        {"general": {"orthogonalprojection": {"width": 200, "height": 100}},
         "objects": [
           {"id": 1, "name": "Group", "origin": "0 0 0", "size": "10 10"},
           {"id": 2, "name": "T", "parent": 1, "origin": "10 5 0", "size": "10 10",
            "font": "f.ttf", "anchor": "topleft", "text": {"value": "x"}}
         ]}
        """)
        let doc = try SceneDocument.load(from: reader, assets: nil)
        guard let text = doc.layers.first(where: {
            if case .text = $0.content { return true }; return false
        }) else { return XCTFail("텍스트 레이어를 찾지 못했다") }
        XCTAssertEqual(text.origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(text.origin.y, 5, accuracy: 0.001)
    }
}
