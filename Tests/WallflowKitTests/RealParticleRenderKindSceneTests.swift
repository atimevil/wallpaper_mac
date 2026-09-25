import XCTest
@testable import WallflowKit

/// 실물 씬을 **실제 로딩 경로**(`SceneDocument.load`)로 읽어 `renderKind`가
/// 정말 `.spriteTrail`로 나오는지 확인한다.
///
/// `ParticleRenderKindTests`는 인라인 JSON 문자열을 직접 파싱해서, 실물 파일이
/// `SceneDocument`/`ReferenceResolver`를 거쳐 오는 길에서 값이 새는지는 안 본다.
/// 씬이 없으면 건너뛴다(다른 기계에는 라이브러리가 없다).
final class RealParticleRenderKindSceneTests: XCTestCase {
    private func workshopScene(_ id: String) throws -> PkgReader {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960")
        let url = root.appendingPathComponent(id).appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("창작마당 씬이 설치되어 있지 않다: \(id)")
        }
        return try PkgReader(data: try Data(contentsOf: url))
    }

    private func assets() throws -> AssetsStore {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wallflow/Assets")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw XCTSkip("Assets가 설치되어 있지 않다")
        }
        return AssetsStore(root: root)
    }

    /// "雨滴屏幕 4k" 레이어가 `particles/presets/rain_screen_4k.json`을 쓴다 —
    /// length 0.0099999998, maxlength 1.5, minlength 1. `applying`/`withChildren`/
    /// `scaledToBudget` 어느 한 곳이라도 `renderKind:`를 빼먹으면 여기서 조용히
    /// `.sprite`로 떨어진다.
    func testRainScreenSceneResolvesToSpriteTrail() throws {
        let reader = try workshopScene("3795022132")
        let document = try SceneDocument.load(from: reader, assets: try assets())

        var found: ParticleRenderKind?
        for layer in document.layers {
            guard case .particle(let preset, _, _, _, _) = layer.content else { continue }
            if case .spriteTrail = preset.renderKind { found = preset.renderKind }
        }
        guard case .spriteTrail(let length, let maxLength, let minLength) = try XCTUnwrap(found)
        else { return XCTFail("spritetrail이어야 한다") }
        XCTAssertEqual(length, 0.0099999998, accuracy: 1e-9)
        XCTAssertEqual(maxLength, 1.5)
        XCTAssertEqual(minLength, 1)
    }

    /// PS2 시계 씬의 오브 꼬리(`particles/orbTrail.json`) — `renderer: [{"name":
    /// "rope", "subdivision": 2}]`, 이미터 `flags: 2`(한 프레임에 하나만).
    /// `orb.json`이 이걸 `type` 없는(= "once") 자식으로 문다 — T8 전까지는
    /// `.sprite`로 떨어져 꼬리가 점으로만 나왔다.
    func testPS2OrbTrailResolvesToRopeWithOnePerFrameEmitter() throws {
        let reader = try workshopScene("1979606285")
        let document = try SceneDocument.load(from: reader, assets: try assets())

        var found: ParticlePreset?
        for layer in document.layers {
            guard case .particle(let preset, _, _, _, _) = layer.content else { continue }
            if case .rope = preset.renderKind { found = preset }
            for child in preset.children where child.reference.name.hasSuffix("orbTrail.json") {
                found = child.preset
            }
        }
        let orbTrail = try XCTUnwrap(found, "orbTrail 프리셋을 못 찾았다")
        guard case .rope(let subdivision, let uvScale, let uvScrolling) = orbTrail.renderKind
        else { return XCTFail("rope여야 한다: \(orbTrail.renderKind)") }
        XCTAssertEqual(subdivision, 2)
        XCTAssertEqual(uvScale, 1, "실물이 uvscale을 안 적었다 — 기본값")
        XCTAssertFalse(uvScrolling)
        let emitter = try XCTUnwrap(orbTrail.emitters.first)
        XCTAssertTrue(emitter.onePerFrame, "flags: 2 — 한 프레임에 하나만 뿌려야 한다")
    }
}
