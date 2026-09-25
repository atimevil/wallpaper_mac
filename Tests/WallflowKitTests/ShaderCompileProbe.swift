import Metal
import XCTest
@testable import WallflowKit

/// 번역이 아니라 **Metal이 실제로 컴파일하는가**를 잰다. `ShaderTranslationProbe`·
/// `WorkshopShaderProbe`는 번역(텍스트 변환)만 보고, 그것만으로는 MSL 자체가
/// 유효한지 모른다 — `WallflowKit`은 Metal을 못 걸어(순수 로직 규칙) 이 탐침만
/// 테스트 타깃에 따로 둔다.
///
/// `Assets/effects`·`Assets/shaders`(HLSL 폴백 제외)와 창작마당 56개의 이펙트·
/// 재질 셰이더 전부를 컴파일한다. 실패 집합을 **이름으로** 고정해 둔다 — 새로
/// 뭔가 깨지면 이 목록에 없는 이름이 나와 실패한다. 넷 다 실물 어디서도 안
/// 쓰인다(확인함): `fur4.vert`(INSTANCECOUNT, 엔진이 링크 시점에 주는 상수라
/// 값을 모른다)·`genericropeparticle.vert`(`void main()`이 파일에 두 번 있다 —
/// 우리 번역기는 하나만 다룬다)·`volumetricsfront.frag`(`texSample2DBackBuffer`·
/// `texLoad2D`, 정의가 자산 어디에도 없다)·`pulse.frag`(g_PulsePhase 등 자체가
/// 선언 없이 쓰인, 창작마당 셰이더 자체의 버그 — `#ifndef AUDIOPROCESSING`가
/// 늘 참이라 죽은 코드가 아니라 살아서 떨어진다).
final class ShaderCompileProbe: XCTestCase {
    /// `sub/path` 꼴로 실패가 예상되는 목록. 여기 없는 이름이 실패하면 회귀다.
    static let knownFailures: Set<String> = [
        "assets/shaders/fur4.vert",
        "assets/shaders/genericropeparticle.vert",
        "assets/shaders/volumetricsfront.frag",
        "ws/3113287126/shaders/effects/pulse.frag",
    ]

    func testAllRealShadersCompileExceptKnownGaps() throws {
        guard let scenes = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"],
              let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"]
        else { throw XCTSkip("WALLFLOW_TEST_SCENES / WALLFLOW_TEST_ASSETS 미설정") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal 장치 없음") }

        let assetsRoot = URL(fileURLWithPath: NSString(string: assetsPath).expandingTildeInPath)
        let scenesRoot = URL(fileURLWithPath: NSString(string: scenes).expandingTildeInPath)

        var includes: [String: String] = [:]
        let shadersRoot = assetsRoot.appendingPathComponent("shaders")
        if let walker = FileManager.default.enumerator(atPath: shadersRoot.path) {
            for case let path as String in walker where path.hasSuffix(".h") {
                guard let body = try? String(
                    contentsOf: shadersRoot.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                includes[(path as NSString).lastPathComponent] = body
                includes[path] = body
            }
        }

        var failures: Set<String> = []

        func check(_ label: String, _ source: String, isVertex: Bool, includes: [String: String]) {
            let stage: GLSLTranslator.Stage = isVertex ? .vertex : .fragment
            guard let result = try? GLSLTranslator.translate(
                source, stage: stage, entryPoint: isVertex ? "vertexMain" : "fragmentMain",
                includes: includes)
            else { failures.insert(label); return }
            if (try? device.makeLibrary(source: result.source, options: nil)) == nil {
                failures.insert(label)
            }
        }

        for sub in ["effects", "shaders"] {
            let subRoot = assetsRoot.appendingPathComponent(sub)
            guard let walker = FileManager.default.enumerator(atPath: subRoot.path) else { continue }
            for case let path as String in walker {
                guard path.hasSuffix(".vert") || path.hasSuffix(".frag"),
                      !path.hasPrefix("HLSL/") else { continue }
                guard let source = try? String(
                    contentsOf: subRoot.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                check("assets/\(sub)/\(path)", source, isVertex: path.hasSuffix(".vert"),
                      includes: includes)
            }
        }

        for dir in (try? FileManager.default.contentsOfDirectory(atPath: scenesRoot.path)) ?? [] {
            let pkg = scenesRoot.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
            guard let data = try? Data(contentsOf: pkg), let reader = try? PkgReader(data: data)
            else { continue }
            var localIncludes = includes
            for name in reader.names where name.hasSuffix(".h") {
                if let body = try? reader.data(for: name), let text = String(data: body, encoding: .utf8) {
                    localIncludes[(name as NSString).lastPathComponent] = text
                }
            }
            for name in reader.names where name.hasSuffix(".vert") || name.hasSuffix(".frag") {
                guard let body = try? reader.data(for: name),
                      let source = String(data: body, encoding: .utf8) else { continue }
                check("ws/\(dir)/\(name)", source, isVertex: name.hasSuffix(".vert"),
                      includes: localIncludes)
            }
        }

        let unexpected = failures.subtracting(Self.knownFailures)
        let nowFixed = Self.knownFailures.subtracting(failures)
        XCTAssertTrue(unexpected.isEmpty, "새로 컴파일이 깨졌다: \(unexpected.sorted())")
        XCTAssertTrue(
            nowFixed.isEmpty,
            "다음은 이제 컴파일된다 — knownFailures 목록을 줄여라: \(nowFixed.sorted())")
    }
}
