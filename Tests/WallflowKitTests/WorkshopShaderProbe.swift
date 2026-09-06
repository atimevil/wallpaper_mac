import XCTest
@testable import WallflowKit

/// 씬 pkg 안에 들어 있는 창작마당 이펙트의 셰이더까지 번역한다.
/// 우리가 가장 많이 쓰는 `shimmer`(8회)와 `gradientopacity`(4회)가 여기 있다.
final class WorkshopShaderProbe: XCTestCase {
    func testTranslateWorkshopEffectShaders() throws {
        guard let scenes = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"],
              let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"],
              let out = ProcessInfo.processInfo.environment["WALLFLOW_MSL_DIR"]
        else { throw XCTSkip("환경변수 없음") }
        let root = URL(fileURLWithPath: NSString(string: scenes).expandingTildeInPath)
        let assets = AssetsStore(
            root: URL(fileURLWithPath: NSString(string: assetsPath).expandingTildeInPath))
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        // 헤더는 assets에도 pkg에도 있다. 실제 파이프라인이 둘 다 보므로 여기서도 합친다.
        // 안 합치면 `ApplyBlending` 같은 공용 함수를 못 찾아, 번역기가 아니라
        // 탐침 탓으로 실패한다.
        var includes: [String: String] = [:]
        let assetsShaders = URL(
            fileURLWithPath: NSString(string: assetsPath).expandingTildeInPath)
            .appendingPathComponent("shaders")
        if let walker = FileManager.default.enumerator(atPath: assetsShaders.path) {
            for case let path as String in walker where path.hasSuffix(".h") {
                guard let body = try? String(
                    contentsOf: assetsShaders.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                includes[(path as NSString).lastPathComponent] = body
                includes[path] = body
            }
        }
        var translated = 0, failed = 0
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let pkg = root.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
            guard let data = try? Data(contentsOf: pkg),
                  let reader = try? PkgReader(data: data) else { continue }
            let resolver = ReferenceResolver(pkg: reader, assets: assets)
            // 헤더는 pkg에도 assets에도 있을 수 있다.
            for name in reader.names where name.hasSuffix(".h") {
                if let body = try? reader.data(for: name),
                   let text = String(data: body, encoding: .utf8) {
                    includes[(name as NSString).lastPathComponent] = text
                }
            }
            for name in reader.names where name.hasSuffix(".frag") || name.hasSuffix(".vert") {
                guard let body = try? reader.data(for: name),
                      let source = String(data: body, encoding: .utf8) else { continue }
                _ = resolver
                let stage: GLSLTranslator.Stage = name.hasSuffix(".vert") ? .vertex : .fragment
                do {
                    let result = try GLSLTranslator.translate(
                        source, stage: stage,
                        entryPoint: stage == .vertex ? "vertexMain" : "fragmentMain",
                        includes: includes)
                    try result.source.write(
                        to: outURL.appendingPathComponent(
                            "ws_\(dir)_" + name.replacingOccurrences(of: "/", with: "_")
                                + ".metal"),
                        atomically: true, encoding: .utf8)
                    translated += 1
                } catch {
                    failed += 1
                    print("WS_FAIL \(dir)/\(name)\t\(error)")
                }
            }
        }
        print("WS_TRANSLATED \(translated) FAILED \(failed)")
    }
}
