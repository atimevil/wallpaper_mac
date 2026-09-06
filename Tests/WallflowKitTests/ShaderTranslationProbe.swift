import XCTest
@testable import WallflowKit

/// 실물 셰이더를 전부 번역해 파일로 떨군다. `Scripts/verify-shaders.sh`가 이걸 부르고,
/// 떨어진 MSL을 Metal로 컴파일해 진짜 통과율을 잰다 — 순수 텍스트 테스트로는
/// "컴파일되는가"를 알 수 없다.
///
/// 환경변수가 없으면 건너뛴다.
final class ShaderTranslationProbe: XCTestCase {
    func testTranslateRealEffectShaders() throws {
        guard let assets = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"],
              let out = ProcessInfo.processInfo.environment["WALLFLOW_MSL_DIR"]
        else { throw XCTSkip("WALLFLOW_TEST_ASSETS / WALLFLOW_MSL_DIR 미설정") }
        let root = URL(fileURLWithPath: NSString(string: assets).expandingTildeInPath)
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        // 공용 헤더를 모은다. `#include "common.h"`가 208곳에서 쓰인다.
        var includes: [String: String] = [:]
        let shadersRoot = root.appendingPathComponent("shaders")
        if let walker = FileManager.default.enumerator(atPath: shadersRoot.path) {
            for case let path as String in walker where path.hasSuffix(".h") {
                guard let body = try? String(
                    contentsOf: shadersRoot.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                includes[(path as NSString).lastPathComponent] = body
                includes[path] = body
            }
        }

        var translated = 0, failed = 0
        let effectsRoot = root.appendingPathComponent("effects")
        guard let walker = FileManager.default.enumerator(atPath: effectsRoot.path)
        else { throw XCTSkip("effects 디렉터리 없음") }
        for case let path as String in walker {
            guard path.hasSuffix(".frag") || path.hasSuffix(".vert") else { continue }
            guard let source = try? String(
                contentsOf: effectsRoot.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            let stage: GLSLTranslator.Stage = path.hasSuffix(".vert") ? .vertex : .fragment
            do {
                let result = try GLSLTranslator.translate(
                    source, stage: stage,
                    entryPoint: stage == .vertex ? "vertexMain" : "fragmentMain",
                    includes: includes)
                try result.source.write(
                    to: outURL.appendingPathComponent(
                        path.replacingOccurrences(of: "/", with: "_") + ".metal"),
                    atomically: true, encoding: .utf8)
                translated += 1
            } catch {
                failed += 1
                print("TRANSLATE_FAIL \(path)\t\(error)")
            }
        }
        print("TRANSLATED \(translated) FAILED \(failed)")
        // 번역 자체가 실패하는 셰이더는 없어야 한다. 컴파일 여부는 스크립트가 잰다.
        XCTAssertEqual(failed, 0)
        XCTAssertGreaterThan(translated, 300, "실물 셰이더를 못 찾았다")
    }
}
