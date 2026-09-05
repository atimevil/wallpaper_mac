import XCTest
@testable import WallflowKit

final class SoundLayerTests: XCTestCase {
    private func pkg(_ scene: String) throws -> PkgReader {
        try PkgReader(data: buildPkg(version: "PKGV0023",
                                     entries: [("scene.json", Data(scene.utf8))]))
    }

    /// 실물 모양 그대로: sound는 배열이고 volume·playbackmode가 따라온다.
    func testParsesSoundLayer() throws {
        let doc = try SceneDocument.load(from: pkg("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "비", "sound": ["sounds/rain.mp3"],
                      "volume": 0.68, "playbackmode": "loop", "startsilent": false}]}
        """), assets: nil)
        guard case .sound(let s) = doc.layers[0].content else {
            return XCTFail("소리 레이어여야 한다: \(doc.layers[0].content)")
        }
        XCTAssertEqual(s.paths, ["sounds/rain.mp3"])
        XCTAssertEqual(s.volume, 0.68, accuracy: 0.001)
        XCTAssertTrue(s.loops)
        XCTAssertFalse(s.startsSilent)
    }

    /// playbackmode가 loop가 아니면 반복하지 않는다. 실물에 single이 있다.
    func testSinglePlaybackDoesNotLoop() throws {
        let doc = try SceneDocument.load(from: pkg("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "s", "sound": ["a.mp3"], "playbackmode": "single"}]}
        """), assets: nil)
        guard case .sound(let s) = doc.layers[0].content else { return XCTFail("소리여야 한다") }
        XCTAssertFalse(s.loops)
        XCTAssertEqual(s.volume, 1, "volume이 없으면 최대다")
    }

    /// volume도 {"script": ..., "value": ...} 객체로 온다. 실물에서 확인했다.
    func testScriptedVolumeUsesSavedValue() throws {
        let doc = try SceneDocument.load(from: pkg("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "s", "sound": ["a.mp3"],
                      "volume": {"script": "x", "value": 0.25}}]}
        """), assets: nil)
        guard case .sound(let s) = doc.layers[0].content else { return XCTFail("소리여야 한다") }
        XCTAssertEqual(s.volume, 0.25, accuracy: 0.001)
    }

    /// 파일에서 온 값이라 범위를 벗어날 수 있다. 0~1로 죄어야 한다.
    func testVolumeIsClamped() throws {
        for (raw, want) in [("-5", 0.0), ("99", 1.0)] {
            let doc = try SceneDocument.load(from: pkg("""
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "s", "sound": ["a.mp3"], "volume": \(raw)}]}
            """), assets: nil)
            guard case .sound(let s) = doc.layers[0].content else { return XCTFail("소리여야 한다") }
            XCTAssertEqual(s.volume, want, accuracy: 0.001, "volume \(raw)")
        }
    }

    /// 목록이 비었거나 모양이 다르면 소리 레이어로 만들지 않는다.
    func testEmptyOrMalformedSoundIsUnsupported() throws {
        for raw in ["[]", "123"] {
            let doc = try SceneDocument.load(from: pkg("""
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
             "objects": [{"id": 1, "name": "s", "sound": \(raw)}]}
            """), assets: nil)
            guard case .unsupported = doc.layers[0].content else {
                return XCTFail("\(raw)는 소리로 만들면 안 된다")
            }
        }
    }
}
