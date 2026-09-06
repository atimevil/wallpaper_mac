import XCTest
@testable import WallflowKit

/// 원근 씬. 직교 크기 대신 카메라가 있고, 3D 메시 레이어가 있다.
/// 예전에는 `orthogonalprojection: null`을 보자마자 던져서 이 씬들이 통째로
/// 미리보기 그림으로 물러났다.
final class SceneCameraTests: XCTestCase {
    private func load(_ general: String, objects: String = "[]") throws -> SceneDocument {
        let json = #"{"general": "# + general + #", "objects": "# + objects + "}"
        let pkg = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [
            ("scene.json", Data(json.utf8)),
            ("materials/a.json", Data(#"{"passes": [{"shader": "s", "textures": ["t"]}]}"#.utf8)),
        ]))
        return try SceneDocument.load(from: pkg)
    }

    func testPerspectiveSceneLoadsWithCamera() throws {
        // 실물 그대로: fov는 사용자 속성 객체, 카메라 블록은 문자열 셋.
        let doc = try load("""
        {"orthogonalprojection": null, "fov": {"user": "fov", "value": 53.0},
         "nearz": 1.0, "farz": 10000.0,
         "camera": {"eye": "0 0 38", "center": "0 0 0", "up": "0 1 0"}}
        """)
        let camera = try XCTUnwrap(doc.camera)
        XCTAssertTrue(doc.isPerspective)
        XCTAssertEqual(camera.fov, 53)
        XCTAssertEqual(camera.nearZ, 1)
        XCTAssertEqual(camera.farZ, 10000)
        XCTAssertEqual(camera.eye, Vec3(x: 0, y: 0, z: 38))
        XCTAssertEqual(camera.up, Vec3(x: 0, y: 1, z: 0))
        // 직교 크기는 이름뿐이지만 0이면 안 된다 — 글자·파티클이 나눗셈에 쓴다.
        XCTAssertEqual(doc.orthoWidth, 1920)
        XCTAssertEqual(doc.orthoHeight, 1080)
    }

    /// 카메라 블록이 없으면(실물 전부 null) 기본값이다. 근거가 약한 값이라
    /// 스크립트가 덮어쓰기 전까지만 쓰이지만, 0이나 NaN이면 안 된다.
    func testMissingCameraFallsBackToDefaults() throws {
        let doc = try load(#"{"orthogonalprojection": null, "camera": null, "fov": null}"#)
        let camera = try XCTUnwrap(doc.camera)
        XCTAssertEqual(camera.fov, 50)
        XCTAssertEqual(camera.nearZ, 0.1)
        XCTAssertGreaterThan(camera.farZ, camera.nearZ)
        XCTAssertNotEqual(camera.eye, camera.center, "눈이 보는 점과 겹치면 뷰 행렬이 무너진다")
    }

    /// 파일이 준 값이 미쳤어도 nearz < farz는 지켜야 투영이 성립한다.
    func testClampsAbsurdValues() throws {
        let doc = try load(#"{"orthogonalprojection": null, "fov": 720, "nearz": 500, "farz": 1}"#)
        let camera = try XCTUnwrap(doc.camera)
        XCTAssertLessThanOrEqual(camera.fov, 179)
        XCTAssertGreaterThan(camera.farZ, camera.nearZ)
    }

    func testOrthographicSceneHasNoCamera() throws {
        let doc = try load(#"{"orthogonalprojection": {"width": 100, "height": 100}}"#)
        XCTAssertNil(doc.camera)
        XCTAssertFalse(doc.isPerspective)
        XCTAssertEqual(doc.orthoWidth, 100)
    }

    func testModelLayerIsParsedWithSkin() throws {
        let doc = try load(
            #"{"orthogonalprojection": null}"#,
            objects: #"[{"id": 1, "name": "mainPrism", "model": "models/prism/prism.mdl", "skin": 1, "origin": "0 0 0"}]"#)
        guard case .model(let path, let skin) = try XCTUnwrap(doc.layers.first).content else {
            return XCTFail("model 레이어여야 한다: \(doc.layers.first?.content as Any)")
        }
        XCTAssertEqual(path, "models/prism/prism.mdl")
        XCTAssertEqual(skin, 1)
    }

    /// 실물 원근 씬 — 프리즘 넷과 fov 53. 설치돼 있을 때만.
    func testRealPerspectiveSceneLoads() throws {
        let pkg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960/1979606285/scene.pkg")
        guard let data = try? Data(contentsOf: pkg) else { throw XCTSkip("원근 씬이 설치되어 있지 않다") }
        let doc = try SceneDocument.load(from: try PkgReader(data: data))
        XCTAssertEqual(doc.camera?.fov, 53)
        let models = doc.layers.filter { if case .model = $0.content { return true } else { return false } }
        XCTAssertEqual(models.count, 4, "프리즘 넷")
    }
}
