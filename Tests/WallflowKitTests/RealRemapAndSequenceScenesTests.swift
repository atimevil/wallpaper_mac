import XCTest
@testable import WallflowKit

/// `remapvalue(output: speed)`와 `mapsequencearoundcontrolpoint`를 실물 씬에서 확인한다.
///
/// 둘 다 `ParticleSystem.unimplementedOperators`에 있던 항목이었다. 여기서는 실제
/// 창작마당 씬을 읽어 그 이름이 더 이상 안 뜨는지, 그리고 시뮬레이션이 유한한
/// 값으로 굴러가는지를 본다. 씬이 없으면 건너뛴다(다른 기계에는 라이브러리가 없다).
final class RealRemapAndSequenceScenesTests: XCTestCase {
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

    /// `rain_screen`을 쓰는 실물 비 씬. `particles/presets/rain_screen.json`이
    /// `output: velocity`와 `output: speed` 둘 다 쓴다 — speed 쪽은 이 작업 전에
    /// `unimplementedOperators`에 `remapvalue(speed)`로 남았었다.
    func testRainSceneNoLongerReportsSpeedRemapAsUnimplemented() throws {
        let reader = try workshopScene("3793322447")
        let document = try SceneDocument.load(from: reader, assets: try assets())

        var sawSpeedRemap = false
        var checked = 0
        for layer in document.layers {
            guard case .particle(let preset, _, _, _, _) = layer.content else { continue }
            if preset.operators.contains(where: {
                if case .remapValue(.speed, _, _, _, _) = $0 { return true }
                return false
            }) {
                sawSpeedRemap = true
            }
            let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
            XCTAssertFalse(system.unimplementedOperators.contains("remapvalue(speed)"),
                           "speed 출력을 이제 넣었으니 보고하면 안 된다")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "파티클 레이어가 하나는 있어야 한다")
        XCTAssertTrue(sawSpeedRemap, "이 씬에 output: speed 연산자가 있어야 시험이 의미가 있다")
    }

    /// `magic_trinity` 프리셋(`mapsequencearoundcontrolpoint`, 실물 유일 1곳)을
    /// 몇 초 굴려 파티클이 유한한 자리에서 살아 있는지 본다.
    func testMagicTrinitySceneRunsSequenceInitializerWithoutBlowingUp() throws {
        let reader = try workshopScene("3794775331")
        let document = try SceneDocument.load(from: reader, assets: try assets())

        var sawSequenceInitializer = false
        for layer in document.layers {
            guard case .particle(let preset, _, _, _, _) = layer.content else { continue }
            if preset.initializers.contains(where: {
                if case .mapSequenceAroundControlPoint = $0 { return true }
                return false
            }) {
                sawSequenceInitializer = true
            }
            let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
            XCTAssertFalse(
                system.unimplementedOperators.contains { $0.hasPrefix("mapsequencearoundcontrolpoint") },
                "제어점을 풀 수 있으면(0번) 보고하면 안 된다")
            for _ in 0..<(3 * 60) {
                system.update(deltaTime: 1.0 / 60)
            }
            for particle in system.particles {
                XCTAssertTrue(particle.position.x.isFinite && particle.position.y.isFinite
                    && particle.position.z.isFinite, "자리가 유한해야 한다")
                XCTAssertTrue(particle.velocity.x.isFinite && particle.velocity.y.isFinite
                    && particle.velocity.z.isFinite, "속도가 유한해야 한다")
            }
        }
        XCTAssertTrue(sawSequenceInitializer,
                      "이 씬에 mapsequencearoundcontrolpoint가 있어야 시험이 의미가 있다")
    }
}
