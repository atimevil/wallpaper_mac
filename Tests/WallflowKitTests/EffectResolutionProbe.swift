import XCTest
@testable import WallflowKit

/// 씬이 거는 이펙트가 실제로 풀리는지 전수로 잰다.
final class EffectResolutionProbe: XCTestCase {
    func testResolveAllEffects() throws {
        guard let scenes = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"],
              let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"]
        else { throw XCTSkip("환경변수 없음") }
        let root = URL(fileURLWithPath: NSString(string: scenes).expandingTildeInPath)
        let assets = AssetsStore(
            root: URL(fileURLWithPath: NSString(string: assetsPath).expandingTildeInPath))
        var applied = 0, resolved = 0, passes = 0
        var missing: Set<String> = []
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let pkg = root.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
            guard let data = try? Data(contentsOf: pkg),
                  let reader = try? PkgReader(data: data),
                  let body = try? reader.data(for: "scene.json"),
                  let scene = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let objects = scene["objects"] as? [Any] else { continue }
            let resolver = ReferenceResolver(pkg: reader, assets: assets)
            for case let object as [String: Any] in objects {
                for case let effect as [String: Any] in (object["effects"] as? [Any] ?? []) {
                    guard let file = effect["file"] as? String else { continue }
                    applied += 1
                    let scenePasses = (effect["passes"] as? [Any] ?? [])
                        .compactMap { $0 as? [String: Any] }
                    guard let definition = EffectDefinition.load(
                        path: file, scenePasses: scenePasses, resolver: resolver)
                    else { missing.insert(file); continue }
                    resolved += 1
                    passes += definition.passes.count
                }
            }
        }
        print("EFFECTS 적용 \(applied) 해석 \(resolved) 패스 \(passes)")
    }
        }
        for file in missing.sorted() { print("EFFECT_MISS \(file)") }
    }
}
