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
        XCTAssertEqual(t.scriptProperties["use24hFormat"], 1)
        XCTAssertEqual(t.scriptProperties["showSeconds"], 0)
        // 텍스트의 color는 이미 0~1이다. 파티클(0~255)처럼 나누면 안 된다.
        XCTAssertEqual(t.color.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(t.color.y, 0.15294, accuracy: 0.001)
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
