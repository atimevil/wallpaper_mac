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

    private func makeScenePkg(scene: String) throws -> PkgReader {
        try PkgReader(data: buildPkg(version: "PKGV0023", entries: [("scene.json", Data(scene.utf8))]))
    }
}
