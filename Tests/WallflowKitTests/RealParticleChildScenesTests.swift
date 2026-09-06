import XCTest
@testable import WallflowKit

/// 실물 씬의 자식 파티클을 끝에서 끝까지 확인한다.
///
/// 단위 시험은 "자식이 생긴다"를 보지만, 실물이 걸리는 곳은 그 앞이다 —
/// 프리셋 경로, 자식의 재질, 굴절 자식 건너뛰기. 그래서 설치된 씬을 그대로 읽는다.
/// 씬이 없으면 건너뛴다(다른 기계에서는 라이브러리가 없다).
final class RealParticleChildScenesTests: XCTestCase {
    /// 앱이 창작마당 씬을 두는 자리. 라이브러리가 없으면 이 시험은 건너뛴다.
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

    /// 불꽃놀이 씬. 부모는 `maxcount: 4`에 순간 방출 하나뿐이고, 터지는 것
    /// **전부**가 죽는 순간 나오는 자식이다. 자식을 못 그리면 점 몇 개만 뜬다.
    func testFireworksSceneSpawnsChildrenOnDeath() throws {
        let reader = try workshopScene("3793241848")
        let document = try SceneDocument.load(from: reader, assets: try assets())

        var systems: [ParticleSystem] = []
        var withChildren = 0
        for layer in document.layers {
            guard case .particle(let preset, _, _, _, _) = layer.content else { continue }
            if !preset.children.isEmpty { withChildren += 1 }
            systems.append(ParticleSystem(preset: preset, random: SeededRandom(seed: 1)))
        }
        XCTAssertFalse(systems.isEmpty, "파티클 레이어가 하나는 있어야 한다")
        XCTAssertGreaterThan(withChildren, 0, "자식을 단 레이어가 하나는 있어야 한다")

        // 30초를 돌린다. 부모 방출이 초당 0.7이라 이 안에 반드시 몇 번 터진다.
        var maxGroups = 0
        var childParticles = 0
        for _ in 0..<(30 * 60) {
            for system in systems {
                system.update(deltaTime: 1.0 / 60)
                let groups = system.renderableGroups()
                maxGroups = Swift.max(maxGroups, groups.count)
                childParticles += groups.dropFirst().reduce(0) { $0 + $1.particles.count }
            }
        }
        XCTAssertGreaterThan(maxGroups, 1, "자식 그룹이 한 번도 생기지 않았다")
        XCTAssertGreaterThan(childParticles, 0, "자식 파티클이 하나도 안 나왔다")
    }

    /// 자식 프리셋이 커도 화면을 다 덮으면 안 된다. 실물 섬광은 크기가
    /// 1000~1200이지만 `sizechange`로 0에서 부풀었다 꺼진다 — 그 연산자가
    /// 빠지면 원반이 수명 내내 그대로 떠서 화면이 하얗게 날아간다.
    func testFlareGrowsAndShrinksInsteadOfStayingFull() throws {
        let resolver = ReferenceResolver(
            pkg: try workshopScene("3793241848"), assets: try assets())
        guard let json = resolver.json(
                for: "presets/fireworks/particles/presets/fireworks2flare.json"),
              let preset = ParticlePreset.parse(json) else {
            throw XCTSkip("불꽃 섬광 프리셋을 찾을 수 없다")
        }
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
        var sizes: [Double] = []
        // 수명이 0.1~0.15초다. 60fps로 열 프레임이면 태어나서 꺼질 때까지다.
        for _ in 0..<10 {
            system.update(deltaTime: 1.0 / 60)
            if let particle = system.particles.first { sizes.append(particle.size) }
        }
        let peak = try XCTUnwrap(sizes.max())
        XCTAssertGreaterThan(peak, 100, "가운데에서는 크게 부풀어야 한다")
        XCTAssertLessThan(try XCTUnwrap(sizes.first), peak * 0.5,
                          "태어날 때는 작아야 한다")
        XCTAssertLessThan(try XCTUnwrap(sizes.last), peak * 0.5,
                          "꺼질 때도 작아야 한다")
    }
}
