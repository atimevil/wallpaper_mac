import XCTest
@testable import WallflowKit

/// 씬이 레이어에 거는 이펙트를 패스로 편다.
/// 값은 두 군데서 온다 — 재질이 셰이더를, 씬이 콤보와 유니폼 값을 준다.
final class EffectDefinitionTests: XCTestCase {
    private func resolver(_ entries: [String: String]) throws -> ReferenceResolver {
        let pkg = try PkgReader(data: buildPkg(
            version: "PKGV0023",
            entries: entries.map { ($0.key, Data($0.value.utf8)) }))
        return ReferenceResolver(pkg: pkg, assets: nil)
    }

    private let blurEffect = """
    {"passes": [
      {"material": "materials/a.json", "target": "_rt_QuarterCompoBuffer1",
       "bind": [{"name": "previous", "index": 0}]},
      {"material": "materials/b.json",
       "bind": [{"name": "_rt_QuarterCompoBuffer1", "index": 0}]}]}
    """

    func testLoadsPassesInOrder() throws {
        let resolver = try resolver([
            "effects/blur/effect.json": blurEffect,
            "effects/blur/materials/a.json":
                #"{"passes": [{"shader": "effects/down", "blending": "normal"}]}"#,
            "effects/blur/materials/b.json":
                #"{"passes": [{"shader": "effects/combine", "blending": "add"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/blur/effect.json", scenePasses: [], resolver: resolver))
        XCTAssertEqual(effect.passes.map(\.shaderName), ["effects/down", "effects/combine"])
        XCTAssertEqual(effect.passes[0].target, "_rt_QuarterCompoBuffer1")
        XCTAssertNil(effect.passes[1].target, "마지막 패스의 결과가 이펙트의 결과다")
        XCTAssertEqual(effect.passes[1].bindings.first?.name, "_rt_QuarterCompoBuffer1")
        XCTAssertEqual(effect.passes[1].blending, "add")
    }

    /// 씬의 패스 값은 **순서대로** 짝지어진다. 어긋나면 엉뚱한 패스에 값이 들어가
    /// 그림이 조용히 달라진다.
    func testScenePassesPairByIndex() throws {
        let resolver = try resolver([
            "effects/blur/effect.json": blurEffect,
            "effects/blur/materials/a.json": #"{"passes": [{"shader": "effects/down"}]}"#,
            "effects/blur/materials/b.json": #"{"passes": [{"shader": "effects/combine"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/blur/effect.json",
            scenePasses: [
                ["combos": ["KERNEL": 1], "constantshadervalues": ["scale": "0.5 0.5"]],
                ["constantshadervalues": ["strength": 0.25]],
            ],
            resolver: resolver))
        XCTAssertEqual(effect.passes[0].combos, ["KERNEL": 1])
        XCTAssertEqual(effect.passes[0].constants["scale"], .vector([0.5, 0.5]))
        XCTAssertNil(effect.passes[0].constants["strength"])
        XCTAssertEqual(effect.passes[1].constants["strength"], .scalar(0.25))
    }

    /// 씬이 값을 덜 줘도 나머지 패스는 그대로 살아야 한다.
    func testFewerScenePassesStillLoadsEveryPass() throws {
        let resolver = try resolver([
            "effects/blur/effect.json": blurEffect,
            "effects/blur/materials/a.json": #"{"passes": [{"shader": "effects/down"}]}"#,
            "effects/blur/materials/b.json": #"{"passes": [{"shader": "effects/combine"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/blur/effect.json",
            scenePasses: [["combos": ["KERNEL": 2]]], resolver: resolver))
        XCTAssertEqual(effect.passes.count, 2)
        XCTAssertTrue(effect.passes[1].combos.isEmpty)
    }

    /// 바인딩을 안 적은 패스가 많다. 그때는 직전 결과를 0번에 묶는 것이 기본이다 —
    /// 비워 두면 그 패스가 아무것도 못 읽어 화면이 검게 나온다.
    func testMissingBindingDefaultsToPrevious() throws {
        let resolver = try resolver([
            "effects/iris/effect.json": #"{"passes": [{"material": "materials/i.json"}]}"#,
            "effects/iris/materials/i.json": #"{"passes": [{"shader": "effects/iris"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/iris/effect.json", scenePasses: [], resolver: resolver))
        XCTAssertEqual(effect.passes[0].bindings, [EffectBinding(name: "previous", index: 0)])
    }

    /// 재질 경로가 이펙트 폴더 기준일 수도, 루트 기준일 수도 있다.
    /// 한쪽만 보면 절반이 안 풀린다.
    func testMaterialPathResolvesFromRootToo() throws {
        let resolver = try resolver([
            "effects/x/effect.json": #"{"passes": [{"material": "materials/shared.json"}]}"#,
            "materials/shared.json": #"{"passes": [{"shader": "effects/shared"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/x/effect.json", scenePasses: [], resolver: resolver))
        XCTAssertEqual(effect.passes[0].shaderName, "effects/shared")
    }

    /// 재질을 못 읽는 패스는 빠진다. 하나도 안 남으면 이펙트 자체가 없는 것이다 —
    /// 반쪽만 적용한 그림은 원본보다 나쁘다.
    func testEffectWithNoUsablePassIsNil() throws {
        let resolver = try resolver([
            "effects/x/effect.json": #"{"passes": [{"material": "materials/없음.json"}]}"#,
        ])
        XCTAssertNil(EffectDefinition.load(
            path: "effects/x/effect.json", scenePasses: [], resolver: resolver))
    }

    /// 스크립트에 묶인 값은 `{"value": …}` 객체로 온다.
    func testScriptBoundConstantIsUnwrapped() throws {
        let resolver = try resolver([
            "effects/x/effect.json": #"{"passes": [{"material": "materials/m.json"}]}"#,
            "effects/x/materials/m.json": #"{"passes": [{"shader": "s"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/x/effect.json",
            scenePasses: [["constantshadervalues": [
                "speed": ["user": "prop1", "value": 0.75],
            ]]],
            resolver: resolver))
        XCTAssertEqual(effect.passes[0].constants["speed"], .scalar(0.75))
    }

    func testShaderPathsPreferTheEffectFolder() {
        let paths = EffectDefinition.shaderPaths(for: "effects/iris", base: "effects/iris")
        XCTAssertEqual(paths.fragment.first, "effects/iris/shaders/effects/iris.frag")
        XCTAssertEqual(paths.fragment.last, "shaders/effects/iris.frag")
        XCTAssertEqual(paths.vertex.first, "effects/iris/shaders/effects/iris.vert")
    }

    /// 씬은 패스마다 슬롯별 텍스처를 준다. 블러가 슬롯 1에 마스크를 주는데,
    /// 이걸 무시하면 흐림이 마스크 없이 **화면 전체**에 걸린다(실물에서 확인).
    func testScenePassTexturesAreCarried() throws {
        let resolver = try resolver([
            "effects/blur/effect.json": #"{"passes": [{"material": "materials/m.json"}]}"#,
            "effects/blur/materials/m.json": #"{"passes": [{"shader": "effects/combine"}]}"#,
        ])
        let effect = try XCTUnwrap(EffectDefinition.load(
            path: "effects/blur/effect.json",
            scenePasses: [["textures": [NSNull(), "masks/blur_mask", NSNull()]]],
            resolver: resolver))
        // 개수가 안 맞으면 여기서 멈춘다. 그냥 인덱스로 접근하면 실패가 보고되는
        // 대신 테스트가 죽어, 무엇이 왜 틀렸는지 알 수 없다.
        let textures = effect.passes[0].textures
        guard textures.count == 3 else {
            return XCTFail("슬롯 3개여야 한다: \(textures)")
        }
        XCTAssertNil(textures[0])
        XCTAssertEqual(textures[1], "masks/blur_mask")
        XCTAssertNil(textures[2])
    }
}
