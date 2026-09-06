import XCTest
@testable import WallflowKit

/// 창작마당 스크립트가 있다고 가정하는 전역들. 없으면 스크립트 **본문 평가가
/// 통째로 실패해** 레이어가 저장된 값으로 굳는다 — 흰 상자가 남는 경로다.
/// 실물 145개 스크립트에서 `new Vec3` 120회, `engine.*` 80회를 세었다.
final class SceneScriptRuntimeTests: XCTestCase {
    private func value(_ body: String, modules: [String: String] = [:]) -> String? {
        // 모듈을 주면 import 줄도 같이 넣는다. import가 없으면 바인딩이 생기지 않아,
        // 테스트가 모듈 해석이 아니라 "안 쓰면 안 깨진다"를 재게 된다.
        let imports = modules.keys.sorted().map { "import * as \($0) from '\($0)';\n" }.joined()
        return ScriptEngine(source: imports + "export function update(v) { \(body) }",
                            modules: modules).update(value: "")
    }

    func testVec3ConstructorForms() {
        XCTAssertEqual(value("return new Vec3().toString();"), "0 0 0")
        XCTAssertEqual(value("return new Vec3(2).toString();"), "2 2 2")
        XCTAssertEqual(value("return new Vec3(1, 2).toString();"), "1 2 0")
        XCTAssertEqual(value("return new Vec3(1, 2, 3).toString();"), "1 2 3")
        XCTAssertEqual(value("return new Vec3('4 5 6').toString();"), "4 5 6")
    }

    /// 문서가 못박은 동작이다: "returns result as a new object".
    /// 제자리에서 바꾸면 `let b = a.add(v)` 뒤에 `a`까지 조용히 바뀐다.
    func testVec3MethodsDoNotMutateTheOriginal() {
        XCTAssertEqual(
            value("""
            let a = new Vec3(1, 2, 3);
            let b = a.add(new Vec3(1, 1, 1)).multiply(2);
            return a.toString() + ' | ' + b.toString();
            """),
            "1 2 3 | 4 6 8")
    }

    func testVec3Geometry() {
        XCTAssertEqual(value("return String(new Vec3(3, 4, 0).length());"), "5")
        XCTAssertEqual(value("return new Vec3(0, 0, 5).normalize().toString();"), "0 0 1")
        XCTAssertEqual(
            value("return new Vec3(1, 0, 0).cross(new Vec3(0, 1, 0)).toString();"), "0 0 1")
        XCTAssertEqual(value("return String(new Vec3(1, 2, 3).dot(new Vec3(4, 5, 6)));"), "32")
    }

    /// 길이 0을 정규화하면 0으로 나눠 NaN이 된다. NaN 좌표가 셰이더까지 흘러가면
    /// 레이어가 통째로 사라진다.
    func testNormalizingZeroDoesNotProduceNaN() {
        XCTAssertEqual(value("return new Vec3(0, 0, 0).normalize().toString();"), "0 0 0")
    }

    func testEngineMembersExist() {
        XCTAssertEqual(value("return typeof engine.frametime;"), "number")
        XCTAssertEqual(value("return typeof engine.runtime;"), "number")
        XCTAssertEqual(value("return typeof engine.isWallpaper();"), "boolean")
        XCTAssertEqual(value("return String(engine.isRunningInEditor());"), "false")
        XCTAssertEqual(value("return typeof engine.screenResolution.x;"), "number")
        XCTAssertEqual(value("return typeof engine.canvasSize.y;"), "number")
        XCTAssertEqual(value("return typeof engine.setTimeout(function () {});"), "function")
    }

    /// 화면 크기를 물어보면 실제 값이 와야 한다. 상수를 돌려주면 스크립트가
    /// 엉뚱한 자리에 레이어를 놓는다.
    func testEnvironmentValuesReachTheScript() {
        let engine = ScriptEngine(
            source: "export function update(v) { return engine.screenResolution.toString(); }",
            environment: .init(screenWidth: 3456, screenHeight: 2234,
                               canvasWidth: 4000, canvasHeight: 3000))
        XCTAssertEqual(engine.update(value: ""), "3456 2234")
    }

    /// 못 주는 것은 null로 둔다. 가짜 스펙트럼을 주면 비주얼라이저가 실제 소리와
    /// 무관하게 움직이는, 더 나쁜 거짓말이 된다.
    func testAudioBuffersAreHonestlyUnavailable() {
        XCTAssertEqual(value("return String(engine.registerAudioBuffers(16));"), "null")
    }

    /// `shared`가 없어 실물 스크립트 4개가 통째로 죽었다.
    func testSharedGlobalExists() {
        XCTAssertEqual(value("return typeof shared;"), "object")
    }

    /// `import` 줄이 남으면 구문 오류로 스크립트 전체가 버려진다.
    /// 모듈을 주면 실제로 불러오고, 없으면 줄만 지운다.
    func testImportedModuleIsBound() {
        let module = """
        'use strict';
        export let deg2rad = Math.PI / 180;
        export function twice(v) { return v * 2; }
        """
        XCTAssertEqual(
            value("return String(WEMath.twice(21));", modules: ["WEMath": module]), "42")
    }

    func testUnknownImportDoesNotBreakTheScript() {
        XCTAssertEqual(
            ScriptEngine(source: """
            import * as Nope from 'Nope';
            export function update(v) { return 'ok'; }
            """).update(value: ""), "ok")
    }

    /// `"\\r\\n"`은 Swift에서 한 Character라 `split(separator: "\\n")`으로 안 나뉜다.
    /// 그러면 파일 전체가 한 줄이 되어 `export` 제거가 통째로 무력화된다 —
    /// assets의 `wemath.js`가 CRLF라 실제로 이 일이 났다.
    func testCRLFModuleStillParses() {
        let module = "'use strict';\r\nexport function twice(v) { return v * 2; }\r\n"
        XCTAssertEqual(ScriptEngine.exportedNames(in: module), ["twice"])
        XCTAssertEqual(
            value("return String(WEMath.twice(4));", modules: ["WEMath": module]), "8")
    }

    /// 빌더 이름을 열거하면 하나 빠질 때마다 스크립트가 죽는다.
    /// 실물에 `addColor`가 있었는데 목록에 없어서 실제로 죽었다.
    func testAnyBuilderMethodNameWorksAndChains() {
        let engine = ScriptEngine(source: """
        export var scriptProperties = createScriptProperties()
            .addColor({ name: 'tint', value: 1 })
            .addSomethingWeHaveNeverSeen({ name: 'x', value: 2 })
            .finish();
        export function update(v) {
            return scriptProperties.tint + ',' + scriptProperties.x;
        }
        """)
        XCTAssertNil(engine.failure, "\(String(describing: engine.failure))")
        XCTAssertEqual(engine.update(value: ""), "1,2")
    }
}
