import XCTest
@testable import WallflowKit

/// 자식 파티클 시스템 — 파티클이 다른 파티클을 낳는 것.
///
/// 실물 51개 프리셋 중 10개가 이걸 쓴다. 불꽃 폭발(`eventdeath`), 반딧불 꼬리와
/// 빗줄기(`eventfollow`), 마법 효과가 전부 여기 걸려 있다. **부모만 그리면
/// 불꽃놀이는 점 몇 개로만 보인다** — 터지는 것 전부가 자식에 들어 있다.
final class ParticleChildTests: XCTestCase {
    private func resolver(_ entries: [String: String]) throws -> ReferenceResolver {
        let pkg = try PkgReader(data: buildPkg(
            version: "PKGV0023",
            entries: entries.map { ($0.key, Data($0.value.utf8)) }))
        return ReferenceResolver(pkg: pkg, assets: nil)
    }

    /// 실물 `fireworks2` 모양 — 부모는 `rate: 0`에 한꺼번에 하나,
    /// 폭발은 전부 `eventdeath` 자식이다.
    private let parentJSON = """
    {"maxcount": 4, "material": "materials/parent.json",
     "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1,
                  "distancemin": 0, "distancemax": 0}],
     "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05},
                     {"name": "sizerandom", "min": 10, "max": 10}],
     "children": [{"name": "particles/spark.json", "type": "eventdeath",
                   "maxcount": 3, "origin": "0 0 0"}]}
    """
    private let childJSON = """
    {"maxcount": 20, "material": "materials/spark.json",
     "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 20,
                  "distancemin": 0, "distancemax": 4, "speedmax": 100}],
     "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2},
                     {"name": "sizerandom", "min": 5, "max": 5}]}
    """
    private var materials: [String: String] {
        ["materials/parent.json":
            #"{"passes": [{"shader": "s", "textures": ["p"]}]}"#,
         "materials/spark.json":
            #"{"passes": [{"shader": "s", "textures": ["c"], "blending": "additive"}]}"#]
    }

    // MARK: 읽기

    func testParsesChildReference() throws {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(parentJSON.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
        XCTAssertEqual(preset.childReferences.count, 1)
        let reference = try XCTUnwrap(preset.childReferences.first)
        XCTAssertEqual(reference.name, "particles/spark.json")
        XCTAssertEqual(reference.trigger, .onDeath)
        XCTAssertEqual(reference.maxCount, 3)
    }

    /// `type`이 없으면 "시작할 때 한 번"이다. 실물 자식 23개 중 14개가 이 경우다.
    func testMissingTypeMeansOnce() {
        XCTAssertEqual(ParticleChildTrigger.parse(nil), .once)
        XCTAssertEqual(ParticleChildTrigger.parse("eventfollow"), .follow)
        XCTAssertEqual(ParticleChildTrigger.parse("eventspawn"), .onSpawn)
    }

    // MARK: 씬에서 읽기

    /// 씬을 읽을 때 자식 프리셋과 **자식의 재질**까지 따라가야 한다.
    /// 자식은 부모와 다른 텍스처와 다른 혼합을 쓴다(불꽃 잔해는 가산이다).
    func testSceneResolvesChildPresetAndMaterial() throws {
        let resolver = try resolver(materials.merging(
            ["particles/parent.json": parentJSON,
             "particles/spark.json": childJSON]) { a, _ in a })
        let content = SceneDocument.resolveParticleContent(
            presetPath: "particles/parent.json", resolver: resolver,
            override: ParticleOverride())
        guard case .particle(let preset, _, _) = content else {
            return XCTFail("파티클로 풀리지 않았다: \(content)")
        }
        XCTAssertEqual(preset.children.count, 1)
        let child = try XCTUnwrap(preset.children.first)
        XCTAssertEqual(child.texturePath, "materials/c.tex")
        XCTAssertEqual(child.blend, .additive)
        XCTAssertEqual(child.preset.maxCount, 20)
    }

    /// 자식 프리셋 파일이 없으면 **부모는 그대로 그린다.** 자식 하나 때문에
    /// 레이어 전체를 버리면 화면에서 눈이 통째로 사라진다.
    func testMissingChildLeavesParentDrawable() throws {
        let resolver = try resolver(materials.merging(
            ["particles/parent.json": parentJSON]) { a, _ in a })
        let content = SceneDocument.resolveParticleContent(
            presetPath: "particles/parent.json", resolver: resolver,
            override: ParticleOverride())
        guard case .particle(let preset, let texturePath, _) = content else {
            return XCTFail("파티클로 풀리지 않았다: \(content)")
        }
        XCTAssertEqual(texturePath, "materials/p.tex")
        XCTAssertTrue(preset.children.isEmpty)
    }

    /// 서로를 가리키는 프리셋이 와도 멈춰야 한다. .pkg는 신뢰할 수 없는 입력이다.
    func testCycleStopsAtDepthCap() throws {
        let looping = """
        {"maxcount": 4, "material": "materials/parent.json",
         "children": [{"name": "particles/parent.json"}]}
        """
        let resolver = try resolver(materials.merging(
            ["particles/parent.json": looping]) { a, _ in a })
        let content = SceneDocument.resolveParticleContent(
            presetPath: "particles/parent.json", resolver: resolver,
            override: ParticleOverride())
        guard case .particle(let preset, _, _) = content else {
            return XCTFail("파티클로 풀리지 않았다: \(content)")
        }
        // 두 단계까지만 편다: 자식 하나, 그 자식의 자식 하나, 거기서 끝.
        let first = try XCTUnwrap(preset.children.first)
        let second = try XCTUnwrap(first.preset.children.first)
        XCTAssertEqual(preset.children.count, 1)
        XCTAssertEqual(first.preset.children.count, 1)
        XCTAssertTrue(second.preset.children.isEmpty)
    }

    // MARK: 굴리기

    private func system(children: [ParticleChild]) throws -> ParticleSystem {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(parentJSON.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object)).withChildren(children)
        return ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
    }

    private func sparkChild(
        trigger: ParticleChildTrigger, maxCount: Int = 3
    ) throws -> ParticleChild {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(childJSON.utf8)) as? [String: Any])
        return ParticleChild(
            reference: ParticleChildReference(
                name: "particles/spark.json", trigger: trigger,
                maxCount: maxCount, origin: Vec3(x: 0, y: 0, z: 0)),
            preset: try XCTUnwrap(ParticlePreset.parse(object)),
            texturePath: "materials/c.tex", blend: .additive)
    }

    /// 부모가 죽어야 자식이 터진다. 살아 있는 동안에는 하나도 없어야 한다.
    func testDeathSpawnsChild() throws {
        let system = try system(children: [sparkChild(trigger: .onDeath)])
        system.update(deltaTime: 1.0 / 60)
        XCTAssertEqual(system.renderableGroups().count, 1, "아직 부모만 있어야 한다")
        // 부모 수명이 0.05초다. 그 뒤에 자식이 생긴다.
        for _ in 0..<10 { system.update(deltaTime: 1.0 / 60) }
        let groups = system.renderableGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1].key, "0.0")
        XCTAssertEqual(groups[1].particles.count, 20, "자식 한 벌이 20개를 뿌린다")
    }

    /// 같은 정의에서 나온 여러 벌은 **한 그룹으로 합쳐진다.** 렌더러를 벌마다
    /// 만들면 불꽃이 터질 때마다 파이프라인이 새로 잡힌다.
    func testInstancesMergeIntoOneGroup() throws {
        // 부모를 4개 터뜨린다: instantaneous를 늘린 프리셋으로 다시 만든다.
        let json = parentJSON.replacingOccurrences(
            of: "\"instantaneous\": 1", with: "\"instantaneous\": 3")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
            .withChildren([try sparkChild(trigger: .onDeath)])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
        for _ in 0..<12 { system.update(deltaTime: 1.0 / 60) }
        let groups = system.renderableGroups()
        XCTAssertEqual(groups.count, 2, "벌이 셋이어도 그룹은 하나다")
        XCTAssertEqual(groups[1].particles.count, 60, "세 벌 × 20개")
    }

    /// `maxcount`를 넘겨 벌을 만들면 안 된다. 자식이 자식을 낳는 프리셋에서
    /// 이 한도가 유일한 제동이다.
    func testInstanceCountIsCapped() throws {
        let json = parentJSON.replacingOccurrences(
            of: "\"instantaneous\": 1", with: "\"instantaneous\": 4")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        let preset = try XCTUnwrap(ParticlePreset.parse(object))
            .withChildren([try sparkChild(trigger: .onDeath, maxCount: 2)])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
        for _ in 0..<12 { system.update(deltaTime: 1.0 / 60) }
        let groups = system.renderableGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1].particles.count, 40, "두 벌까지만 — 네 벌이 아니다")
    }

    /// `eventfollow`는 부모를 따라간다. 부모가 움직이면 자식의 원점도 옮겨간다.
    func testFollowChildTracksParent() throws {
        let json = """
        {"maxcount": 2, "material": "materials/parent.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1,
                      "distancemin": 16, "distancemax": 16, "speedmin": 100,
                      "speedmax": 100, "directions": "1 0 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "sizerandom", "min": 5, "max": 5}],
         "operator": [{"name": "movement", "gravity": "0 0 0", "drag": 0}]}
        """
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        // 꼬리 자식은 **제자리에** 꾸준히 뿌린다(속력 0, 퍼짐 0). 그래야 파티클이
        // 놓인 자리가 곧 부모가 지나온 자리다 — 따라가기가 깨지면 전부 원점에 뭉친다.
        let trailJSON = """
        {"maxcount": 60, "material": "materials/spark.json",
         "emitter": [{"name": "sphererandom", "rate": 30,
                      "distancemin": 0, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "sizerandom", "min": 5, "max": 5}]}
        """
        let trailObject = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(trailJSON.utf8)) as? [String: Any])
        let trail = ParticleChild(
            reference: ParticleChildReference(
                name: "particles/trail.json", trigger: .follow,
                maxCount: 1, origin: Vec3(x: 0, y: 0, z: 0)),
            preset: try XCTUnwrap(ParticlePreset.parse(trailObject)),
            texturePath: "materials/c.tex", blend: .additive)
        let preset = try XCTUnwrap(ParticlePreset.parse(object)).withChildren([trail])
        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 7))
        for _ in 0..<30 { system.update(deltaTime: 1.0 / 60) }
        let groups = system.renderableGroups()
        XCTAssertEqual(groups.count, 2)
        let parent = try XCTUnwrap(groups[0].particles.first(where: \.isAlive))
        // 자식 파티클들은 부모가 지나온 자리 근처에 있어야 한다. 원점을 안 옮기면
        // 전부 (0,0) 언저리에 뭉쳐 꼬리가 아니라 점이 된다.
        let spread = groups[1].particles.filter(\.isAlive).map(\.position.x)
        XCTAssertFalse(spread.isEmpty)
        // 부모는 x축으로 달아난다(부호는 난수가 정한다). 꼬리는 그 자취를 따라
        // **퍼져** 있어야 한다 — 원점을 안 옮기면 폭이 0이다.
        let width = try XCTUnwrap(spread.max()) - (try XCTUnwrap(spread.min()))
        XCTAssertGreaterThan(width, abs(parent.position.x) * 0.5)
    }

    /// 그룹 키는 `"0"`, `"0.<차례>"` 규칙이다. 렌더러 쪽이 같은 규칙으로
    /// 짝을 찾으므로, 여기가 바뀌면 자식이 조용히 안 그려진다.
    func testGroupKeysFollowIndexRule() throws {
        let system = try system(children: [
            sparkChild(trigger: .once), sparkChild(trigger: .once),
        ])
        system.update(deltaTime: 1.0 / 60)
        XCTAssertEqual(system.renderableGroups().map(\.key), ["0", "0.0", "0.1"])
    }
}
