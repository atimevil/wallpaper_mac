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
        // `effects/`(이펙트 체인)와 `shaders/`(메시 재질 — `generic3.vert` 같은
        // 스키닝 셰이더가 여기 있다) 둘 다 잰다. `shaders/`는 예전엔 이 탐침이
        // 보지 않던 118개짜리 사각지대였다 — `effects/` 346개만 세고 "452개
        // 전부"라고 잘못 말한 원인이다. `shaders/HLSL/`은 GLSL이 아니라 진짜
        // HLSL(DirectX 11 폴백)이라 뺀다 — 우리 번역기의 대상이 아니다.
        for sub in ["effects", "shaders"] {
            let subRoot = root.appendingPathComponent(sub)
            guard let walker = FileManager.default.enumerator(atPath: subRoot.path) else { continue }
            for case let path as String in walker {
                guard path.hasSuffix(".frag") || path.hasSuffix(".vert"),
                      !path.hasPrefix("HLSL/") else { continue }
                guard let source = try? String(
                    contentsOf: subRoot.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                let stage: GLSLTranslator.Stage = path.hasSuffix(".vert") ? .vertex : .fragment
                do {
                    let result = try GLSLTranslator.translate(
                        source, stage: stage,
                        entryPoint: stage == .vertex ? "vertexMain" : "fragmentMain",
                        includes: includes)
                    try result.source.write(
                        to: outURL.appendingPathComponent(
                            "\(sub)_" + path.replacingOccurrences(of: "/", with: "_") + ".metal"),
                        atomically: true, encoding: .utf8)
                    translated += 1
                } catch {
                    failed += 1
                    print("TRANSLATE_FAIL \(sub)/\(path)\t\(error)")
                }
            }
        }
        print("TRANSLATED \(translated) FAILED \(failed)")
        // 번역 자체가 실패하는 셰이더는 없어야 한다. 컴파일 여부는 스크립트가 잰다.
        XCTAssertEqual(failed, 0)
        XCTAssertGreaterThan(translated, 400, "실물 셰이더를 못 찾았다")
    }
}
