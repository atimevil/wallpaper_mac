import XCTest
@testable import WallflowKit

/// 보유한 씬 전부를 읽어 **무엇을 아직 못 그리는지** 센다.
///
/// 남의 기능표를 베껴 할 일을 정하면 우리 씬에 하나도 안 쓰이는 것을 먼저 만들게
/// 된다. 여기서 나오는 순위는 우리가 실제로 켜는 배경화면에서 온다.
/// 세는 것이지 판정하는 것이 아니라, 통과/실패를 매기지 않고 목록만 찍는다.
final class CorpusCoverageProbe: XCTestCase {
    func testCountUnsupportedThingsInCorpus() throws {
        var roots: [URL] = []
        if let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] {
            roots.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }
        // 앱이 창작마당에서 받아 둔 자리. 여기가 실제로 쓰는 씬이다.
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960"))
        guard let assetsPath = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let assets = AssetsStore(
            root: URL(fileURLWithPath: NSString(string: assetsPath).expandingTildeInPath))

        var scenes = 0, layers = 0
        var notScenes: [String] = []
        var unreadable: [String] = []
        var unopened: [String] = []
        var kinds: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        var operators: [String: Int] = [:]
        var presetGaps: [String: Int] = [:]
        var rawKeys: [String: Int] = [:]
        var blendModes: [Int: Int] = [:]

        for root in roots {
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let pkg = root.appendingPathComponent(dir).appendingPathComponent("scene.pkg")
                guard let data = try? Data(contentsOf: pkg),
                      let reader = try? PkgReader(data: data) else {
                    // 씬이 아닌 폴더(비디오·웹·딸린 프리셋)와 못 읽는 것을 나눠 센다.
                    // 뭉뚱그리면 "몇 개를 봤는지"가 늘 그럴듯해 보인다.
                    if FileManager.default.fileExists(atPath: pkg.path) {
                        unreadable.append(dir)
                    } else {
                        notScenes.append(dir)
                    }
                    continue
                }
                guard let document = try? SceneDocument.load(from: reader, assets: assets) else {
                    unopened.append(dir)
                    continue
                }
                scenes += 1

                // 원본 JSON도 함께 본다. 우리가 아예 안 읽는 키는 모델에 안 남는다.
                let entry = SceneDocument.sceneEntryName(in: reader)
                if let body = try? reader.data(for: entry),
                   let scene = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let objects = scene["objects"] as? [Any] {
                    for case let object as [String: Any] in objects {
                        for key in object.keys { rawKeys[key, default: 0] += 1 }
                        if let mode = (object["colorBlendMode"] as? NSNumber)?.intValue, mode != 0 {
                            blendModes[mode, default: 0] += 1
                        }
                    }
                }

                for layer in document.layers {
                    layers += 1
                    switch layer.content {
                    case .image: kinds["image", default: 0] += 1
                    case .model: kinds["model", default: 0] += 1
                    case .shadedImage: kinds["shadedImage", default: 0] += 1
                    case .video: kinds["video", default: 0] += 1
                    case .solidColor: kinds["solid", default: 0] += 1
                    case .text: kinds["text", default: 0] += 1
                    case .sound: kinds["sound", default: 0] += 1
                    case .postProcess: kinds["postProcess", default: 0] += 1
                    case .composition: kinds["composition", default: 0] += 1
                    case .particle(let preset, _, _, _, _):
                        kinds["particle", default: 0] += 1
                        let system = ParticleSystem(preset: preset, random: SeededRandom(seed: 1))
                        for name in system.unimplementedOperators {
                            operators[name, default: 0] += 1
                        }
                        for name in preset.unsupportedNames {
                            presetGaps[name, default: 0] += 1
                        }
                    case .unsupported(let reason):
                        kinds["unsupported", default: 0] += 1
                        // 경로가 붙은 이유는 씬마다 달라 뭉쳐지지 않는다. 콜론 앞만 센다.
                        reasons[String(reason.split(separator: ":").first ?? ""), default: 0] += 1
                    }
                }
            }
        }

        func report(_ title: String, _ counts: [some Hashable: Int]) {
            print("— \(title)")
            for (key, count) in counts.sorted(by: { $0.value > $1.value }) {
                print(String(format: "   %4d  %@", count, String(describing: key)))
            }
        }
        print("씬 \(scenes)개 · 레이어 \(layers)개")
        if !notScenes.isEmpty {
            print("— 씬이 아닌 폴더 \(notScenes.count)개(비디오·웹·딸린 프리셋): "
                + notScenes.sorted().joined(separator: ", "))
        }
        if !unreadable.isEmpty {
            print("— pkg를 못 읽은 폴더: " + unreadable.sorted().joined(separator: ", "))
        }
        if !unopened.isEmpty {
            print("— 열지 못한 씬(원근 투영 등): " + unopened.sorted().joined(separator: ", "))
        }
        report("레이어 종류", kinds)
        report("못 그리는 이유", reasons)
        report("아직 없는 파티클 연산자", operators)
        report("아직 모르는 프리셋 항목", presetGaps)
        report("colorBlendMode 값", blendModes)
        report("씬 JSON의 레이어 키", rawKeys)
        XCTAssertGreaterThan(scenes, 0, "씬을 하나도 못 읽었다")
    }
}
