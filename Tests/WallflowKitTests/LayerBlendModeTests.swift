import XCTest
@testable import WallflowKit

/// 레이어를 아래 화면과 섞는 방식(`colorBlendMode`)과 밝기(`brightness`).
///
/// 이 둘은 **짝이다.** 실물 시계 레이어는 밝기가 5.56인데, 그 값은 오버레이로
/// 섞이는 것을 전제로 정해진 것이다 — 밝기만 읽으면 글자가 하얗게 타고,
/// 섞기만 읽으면 너무 옅어진다. 둘 다 없던 것이 오늘까지의 상태였다.
final class LayerBlendModeTests: XCTestCase {
    private func layer(_ body: String) throws -> SceneLayer {
        let json = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "L", "origin": "0 0 0", "size": "10 10",
                      "image": "materials/a.json", \(body)}]}
        """
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data(json.utf8)),
            ("materials/a.json",
             Data(#"{"passes": [{"shader": "s", "textures": ["t"]}]}"#.utf8)),
        ]))
        let document = try SceneDocument.load(from: pkg)
        return try XCTUnwrap(document.layers.first)
    }

    func testReadsBlendModeAndBrightness() throws {
        let layer = try layer(#""colorBlendMode": 11, "brightness": 5.56"#)
        XCTAssertEqual(layer.colorBlendMode, 11)
        XCTAssertEqual(layer.brightness, 5.56, accuracy: 0.0001)
    }

    /// 안 적으면 보통 합성에 밝기 1이다. 여기가 틀리면 **모든** 레이어가 바뀐다.
    func testDefaultsAreNormalAndUnchanged() throws {
        let layer = try layer(#""alpha": 1"#)
        XCTAssertEqual(layer.colorBlendMode, 0)
        XCTAssertEqual(layer.brightness, 1)
    }

    /// 비유한값이 셰이더까지 흘러가면 그 픽셀이 통째로 사라진다.
    func testClampsBrightness() throws {
        XCTAssertEqual(try layer(#""brightness": "nonsense""#).brightness, 1)
        XCTAssertEqual(try layer(#""brightness": -3"#).brightness, 0, "음수는 0으로 막는다")
        XCTAssertEqual(try layer(#""brightness": 1000"#).brightness, 64, "상한으로 막는다")
    }

    /// 모르는 번호는 버리지 않고 그대로 넘긴다. 셰이더가 보통으로 그린다 —
    /// 여기서 0으로 바꿔 버리면 나중에 그 번호를 구현해도 값이 이미 사라져 있다.
    func testKeepsUnknownModeAsIs() throws {
        XCTAssertEqual(try layer(#""colorBlendMode": 99"#).colorBlendMode, 99)
    }

    /// 실물 씬에서 쓰는 번호들. 하나라도 못 읽으면 그 씬의 시계가 잘못 뜬다.
    func testRealScenesUseTheseModes() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960")
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/431960")
        var found: Set<Int> = []
        var brightest = 1.0
        // 읽은 씬 수를 따로 센다. "설치 안 됨"과 "파서가 망가짐"을 구별하지 못하면
        // 파서가 죽어도 이 시험이 조용히 건너뛰어진다.
        var loaded = 0
        for base in [root, downloads] {
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
                let pkg = base.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
                guard let data = try? Data(contentsOf: pkg),
                      let reader = try? PkgReader(data: data),
                      let document = try? SceneDocument.load(from: reader) else { continue }
                loaded += 1
                for layer in document.layers where layer.colorBlendMode != 0 {
                    found.insert(layer.colorBlendMode)
                    brightest = Swift.max(brightest, layer.brightness)
                }
            }
        }
        try XCTSkipIf(loaded == 0, "창작마당 씬이 설치되어 있지 않다")
        // 측정해 둔 값이다. 파서가 조용히 망가지면 이 집합이 비거나 줄어든다.
        XCTAssertEqual(found, [6, 7, 11, 15, 22])
        XCTAssertGreaterThan(brightest, 5, "밝기가 큰 레이어를 못 읽었다")
    }
}
