import XCTest
@testable import WallflowKit

/// WE 자체 미리보기 씬 `previewdrippingwater`로 제어점 덮어쓰기와 이미터
/// 제어점을 끝에서 끝까지 확인한다. 씬이 없으면 건너뛴다(다른 기계에는 없다).
final class RealControlPointSceneTests: XCTestCase {
    /// 미리보기 씬은 자기 폴더 안에 프리셋·재질 사본을 함께 들고 있다
    /// (`particles/presets/dripping_water.json`이 scene.json 옆에 있다) — 그
    /// 폴더 자체를 에셋 루트로 삼아야 상대 경로가 풀린다. scene.json은 .pkg가
    /// 아니라 낱장 파일이라, 그것 하나만 담은 합성 .pkg로 감싼다.
    private func previewRoot() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Wallflow/Assets/presets/water/previewdrippingwater")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("scene.json").path)
        else { throw XCTSkip("previewdrippingwater 미리보기 씬이 설치되어 있지 않다") }
        return root
    }

    /// 실물 인스턴스 덮어쓰기 그대로: `controlpoint1 "22 0 0"`, `controlpoint2 "-22 0 0"`,
    /// `controlpointangle1/2`(안 읽는다). 프리셋의 두 점은 `flags 16`(편집기 전용)이라
    /// 월드 변환은 안 받는다 — 그대로 로컬 좌표다. 두 낙수 자리가 정확히
    /// x=+22, x=-22에 와야 하고, 이미터(rate 6·8)가 그 자리 근처에서 뿌려야 한다.
    func testDrippingWaterControlPointsResolveToOverriddenPositions() throws {
        let root = try previewRoot()
        let sceneData = try Data(contentsOf: root.appendingPathComponent("scene.json"))
        let reader = try PkgReader(
            data: buildPkg(version: "PKGV0023", entries: [("scene.json", sceneData)]))
        let document = try SceneDocument.load(from: reader, assets: AssetsStore(root: root))

        let layer = try XCTUnwrap(document.layers.first)
        guard case .particle(let preset, _, _, _, _) = layer.content else {
            return XCTFail("파티클 레이어여야 한다: \(layer.content)")
        }

        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        system.layerOrigin = layer.origin
        system.layerScale = layer.scale

        XCTAssertEqual(system.controlPointPosition(1), Vec3(x: 22, y: 0, z: 0))
        XCTAssertEqual(system.controlPointPosition(2), Vec3(x: -22, y: 0, z: 0))
        XCTAssertTrue(system.unimplementedOperators.isEmpty,
                      "제어점 1·2 모두 풀려야 한다: \(system.unimplementedOperators)")

        for _ in 0..<60 { system.update(deltaTime: 1.0 / 60) }
        let xs = system.particles.map(\.position.x)
        XCTAssertFalse(xs.isEmpty, "물방울이 하나는 나와야 한다")
        XCTAssertTrue(xs.contains { $0 > 18 && $0 < 26 }, "22 근처 방울이 있어야 한다: \(xs)")
        XCTAssertTrue(xs.contains { $0 < -18 && $0 > -26 }, "-22 근처 방울이 있어야 한다: \(xs)")
    }
}
