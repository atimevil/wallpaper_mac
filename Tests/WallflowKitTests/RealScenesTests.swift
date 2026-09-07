import XCTest
@testable import WallflowKit

/// 보유한 실물 창작마당 씬을 그대로 파싱한다.
/// 용량이 커서 저장소에 넣지 않는다. 경로는 환경변수로 주입한다:
///   WALLFLOW_TEST_SCENES=~/Downloads/431960 swift test
/// 미설정이면 전부 건너뛴다.
final class RealScenesTests: XCTestCase {
    private var root: URL?
    private var badPath: String?

    override func setUp() {
        super.setUp()
        if let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_SCENES"] {
            let expandedPath = NSString(string: path).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                root = URL(fileURLWithPath: expandedPath)
            } else {
                badPath = expandedPath
            }
        } else {
            // 환경변수가 없으면 앱이 받아 두는 자리를 본다. 씬을 다운로드
            // 폴더에서 그쪽으로 옮겼는데(맥이 보호하는 자리라 접근을 매번
            // 묻는다) 시험이 환경변수만 보면 그날부터 조용히 건너뛴다.
            let installed = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Wallflow/workshop/steamapps/workshop/content/431960")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: installed.path, isDirectory: &isDir),
               isDir.boolValue {
                root = installed
            }
        }
    }

    private func assetsStore() throws -> AssetsStore? {
        guard let path = ProcessInfo.processInfo.environment["WALLFLOW_TEST_ASSETS"] else {
            return nil
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            XCTFail("WALLFLOW_TEST_ASSETS가 가리키는 경로가 없다: \(url.path)")
            throw MissingSceneError()
        }
        return AssetsStore(root: url)
    }

    private func scenePkg(_ id: String) throws -> PkgReader? {
        if let badPath = badPath {
            XCTFail("WALLFLOW_TEST_SCENES가 설정되었지만 디렉토리가 아니거나 존재하지 않음: \(badPath)")
            return nil
        }
        guard let root else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let url = root.appendingPathComponent(id).appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // ROOT는 설정되고 유효한데 이 씬만 없다. 여기서 nil을 반환하면 호출부의
            // `guard let ... else { throw XCTSkip(...) }`로 빠져 "환경변수 미설정"으로
            // 오인 보고된다. 사용자가 창작마당 폴더 넷 중 하나를 옮기거나 지웠을 때
            // 그 씬의 포맷 테스트가 보호를 멈춘 걸 아무도 모르게 되므로, nil이 아니라
            // 실제 오류를 던져 호출부가 XCTSkip으로 흡수하지 못하게 한다.
            XCTFail("WALLFLOW_TEST_SCENES는 설정되었지만 씬을 찾을 수 없음: \(url.path)")
            throw MissingSceneError(path: url.path)
        }
        return try PkgReader(data: try Data(contentsOf: url))
    }

    /// M2의 목표 씬. 커스텀 셰이더가 없는 유일한 씬이다.
    func testTargetSceneResolvesToOneImageLayer() throws {
        guard let reader = try scenePkg("3714517753") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.orthoWidth, 2048)
        XCTAssertEqual(doc.orthoHeight, 1164)

        let images = doc.layers.filter {
            if case .image = $0.content { return true } else { return false }
        }
        XCTAssertEqual(images.count, 1, "이미지 레이어가 정확히 하나여야 한다")
        let layer = try XCTUnwrap(images.first)
        XCTAssertEqual(layer.content, .image(texturePath: "materials/HFRvNK5aIAA7Q24.tex"))
        XCTAssertEqual(layer.size, Vec2(x: 2048, y: 1164))
        XCTAssertEqual(layer.origin, Vec3(x: 1024, y: 582, z: 0))
    }

    func testTargetSceneTextureDecodesToExpectedSize() throws {
        guard let reader = try scenePkg("3714517753") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/HFRvNK5aIAA7Q24.tex")
        guard case .image(let cg) = try TexDecoder.decode(data) else {
            return XCTFail("JPEG 텍스처여야 한다")
        }
        XCTAssertEqual(cg.width, 2048)
        XCTAssertEqual(cg.height, 1164)
    }

    /// 226MB 텍스처 두 개가 MP4였다. 이 판정이 틀리면 두 씬이 통째로 깨진다.
    func testLargeTexturesAreDetectedAsVideo() throws {
        let cases = [
            ("3536506287", "materials/弗洛洛SYziyv1.tex"),
            ("3616103296", "materials/Utool-20251201-195920953.tex"),
        ]
        for (id, texture) in cases {
            guard let reader = try scenePkg(id) else {
                throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
            }
            let data = try reader.data(for: texture)
            let header = try TexHeader.parse(data)
            XCTAssertTrue(header.isVideo, "\(id)의 \(texture)는 비디오여야 한다")

            guard case .video(let bytes) = try TexDecoder.decode(data) else {
                return XCTFail("\(id): .video여야 한다")
            }
            // MP4 파일은 4바이트 크기 뒤에 'ftyp' 박스가 온다.
            XCTAssertEqual(bytes.subdata(in: 4..<8), Data("ftyp".utf8))
        }
    }

    func testLZ4MaskDecompressesToExactExpectedSize() throws {
        guard let reader = try scenePkg("3536506287") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/masks/waterripple_mask_caee43da.tex")
        guard case .pixels(let bytes, let w, let h, let format) = try TexDecoder.decode(data) else {
            return XCTFail("원시 픽셀이어야 한다")
        }
        XCTAssertEqual(format, .r8, "마스크는 단일 채널이다")
        XCTAssertEqual(w, 1600)
        XCTAssertEqual(h, 900)
        XCTAssertEqual(bytes.count, 1600 * 900, "R8이면 픽셀당 1바이트다")
    }

    /// 어떤 씬도 파싱 중에 던지거나 크래시하지 않아야 한다.
    func testAllOwnedScenesParseWithoutThrowing() throws {
        if let badPath = badPath {
            XCTFail("WALLFLOW_TEST_SCENES가 설정되었지만 디렉토리가 아니거나 존재하지 않음: \(badPath)")
        }
        guard let root else { throw XCTSkip("WALLFLOW_TEST_SCENES 미설정") }
        // 폴더가 전부 씬인 것은 아니다. 비디오·웹 배경화면과, 다른 항목에 딸린
        // 프리셋(`dependency`)은 `scene.pkg`가 아예 없다. 그것까지 "없어졌다"고
        // 실패하면 라이브러리를 하나 받을 때마다 시험이 깨진다.
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.allSatisfy(\.isNumber) }
            .filter {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent($0)
                        .appendingPathComponent("scene.pkg").path)
            }
        XCTAssertFalse(ids.isEmpty, "테스트할 씬이 없다")

        var perspective: [String] = []
        for id in ids {
            guard let reader = try scenePkg(id) else { continue }
            let doc: SceneDocument
            do {
                doc = try SceneDocument.load(from: reader)
            } catch SceneError.perspectiveProjectionUnsupported {
                // 원근 투영 씬은 아직 못 연다(`.mdl` 로더와 카메라가 필요하다).
                // 아는 구멍이라 여기서 실패시키지 않되, 몇 개인지는 남긴다 —
                // 조용히 넘기면 이 구멍이 얼마나 큰지 아무도 모른다.
                perspective.append(id)
                continue
            }
            XCTAssertGreaterThan(doc.layers.count, 0, "\(id)에 레이어가 없다")
            XCTAssertGreaterThan(doc.orthoWidth, 0, "\(id)의 직교 폭이 0이다")

            // 모든 .tex가 헤더 파싱은 되어야 한다.
            for name in reader.names where name.hasSuffix(".tex") {
                let data = try reader.data(for: name)
                XCTAssertNoThrow(try TexHeader.parse(data), "\(id)/\(name) 헤더 파싱 실패")
            }
        }
        if !perspective.isEmpty {
            print("원근 투영이라 아직 못 여는 씬 \(perspective.count)개: "
                + perspective.sorted().joined(separator: ", "))
        }
        XCTAssertLessThan(perspective.count, ids.count,
                          "전부 원근 씬이면 이 시험이 아무것도 보지 않는다")
    }

    /// PNG 페이로드와 TEXB0003 컨테이너를 한 번에 덮는다.
    /// 지금까지 값 단언은 전부 TEXB0004였고, PNG는 디코딩된 적이 없다.
    func testPNGTextureInTEXB0003ContainerDecodes() throws {
        guard let reader = try scenePkg("3616103296") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/workshop/3187908708/Date Area.tex")
        let header = try TexHeader.parse(data)
        XCTAssertEqual(header.kind, .png)
        guard case .image(let cg) = try TexDecoder.decode(data) else {
            return XCTFail("PNG는 .image로 디코딩되어야 한다")
        }
        XCTAssertEqual(cg.width, 1920)
        XCTAssertEqual(cg.height, 313)
    }

    /// LZ4 + rgba8888. 기존 LZ4 테스트는 단일 채널 마스크만 덮었다.
    func testLZ4RGBATextureDecompressesToExactExpectedSize() throws {
        guard let reader = try scenePkg("3536506287") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let data = try reader.data(for: "materials/effects/waterripplenormal.tex")
        guard case .pixels(let bytes, let w, let h, let format) = try TexDecoder.decode(data) else {
            return XCTFail("원시 픽셀이어야 한다")
        }
        XCTAssertEqual(format, .rgba8888)
        XCTAssertEqual(w, 256)
        XCTAssertEqual(h, 256)
        XCTAssertEqual(bytes.count, 256 * 256 * 4, "rgba8888은 픽셀당 4바이트다")
    }

    /// origin이 문자열이 아니라 스크립트 객체인 image 레이어.
    /// 실물에서 이 조건을 만족하는 것은 이 둘뿐이다. particle/text 오브젝트는
    /// image 키가 없어 origin을 읽기 전에 걸러지므로 여기에 넣으면 안 된다.
    /// origin이 스크립트여도 그 객체의 `value`에 편집기가 저장한 좌표가 있다.
    /// M2는 이걸 몰라서 레이어를 통째로 버렸다. 이제는 저장된 좌표로 그리고,
    /// 못 돌린 스크립트를 `unrunScripts`로 알린다 — 조용히 무시하면 사용자가
    /// 레이어가 왜 안 움직이는지 알 수 없다.
    func testScriptedOriginUsesSavedValueAndIsReported() throws {
        for (id, name) in [("3536506287", "Audio bar"), ("3552439823", "cursor")] {
            guard let reader = try scenePkg(id) else {
                throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
            }
            let doc = try SceneDocument.load(from: reader)
            guard let layer = doc.layers.first(where: { $0.name == name }) else {
                XCTFail("\(id)에 레이어 '\(name)'이 없다")
                continue
            }
            // 이제 origin 스크립트는 `SceneScriptHost`가 돌린다. 문서가 그것을 붙여 두는지 본다.
            XCTAssertTrue(layer.scripts.contains { $0.property == "origin" },
                          "\(id)/\(name)의 origin 스크립트를 붙이지 않았다")
            XCTAssertFalse(layer.unrunScripts.contains("origin"))
            // 좌표를 실제로 읽었는지. 전부 0이면 value를 못 읽고 기본값을 쓴 것이다.
            let o = layer.origin
            XCTAssertFalse(o.x == 0 && o.y == 0 && o.z == 0,
                           "\(id)/\(name)의 저장된 좌표를 읽지 못했다")
        }
    }

    /// M2가 버리던 레이어들이 이제 각자의 내용으로 해석되어야 한다.
    /// zzz는 파티클, Song Title과 Clock은 텍스트다. 셋 다 origin이 스크립트라
    /// 예전엔 통째로 unsupported였다.
    func testFormerlyUnsupportedLayersNowResolve() throws {
        guard let assets = try assetsStore() else { throw XCTSkip("환경변수 미설정") }
        for (id, name, kind) in [("3552439823", "zzz", "particle"),
                                 ("3616103296", "Song Title", "text"),
                                 ("3616103296", "Clock", "text")] {
            guard let reader = try scenePkg(id) else { throw XCTSkip("환경변수 미설정") }
            let doc = try SceneDocument.load(from: reader, assets: assets)
            guard let layer = doc.layers.first(where: { $0.name == name }) else {
                XCTFail("\(id)에 '\(name)'이 없다")
                continue
            }
            switch (kind, layer.content) {
            case ("particle", .particle): break
            case ("text", .text): break
            default:
                XCTFail("\(id)/\(name)이 \(kind)로 해석되지 않았다: \(layer.content)")
            }
        }
    }



    /// 값 단언이 한 번도 닿지 않던 씬. PNG 텍스처가 많다.
    func testSmallestSceneResolvesLayers() throws {
        guard let reader = try scenePkg("3552439823") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        let doc = try SceneDocument.load(from: reader)
        XCTAssertEqual(doc.layers.count, 10)
        let images = doc.layers.filter {
            if case .image = $0.content { return true } else { return false }
        }
        XCTAssertFalse(images.isEmpty, "이미지 레이어가 하나도 해석되지 않았다")
    }

    /// assets가 있으면 M2에서 참조가 끊겼던 레이어들이 해석되어야 한다.
    func testAssetsResolveSolidInstanceModels() throws {
        guard let reader = try scenePkg("3616103296") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }

        let without = try SceneDocument.load(from: reader, assets: nil)
        let with = try SceneDocument.load(from: reader, assets: assets)

        func unsupportedCount(_ doc: SceneDocument) -> Int {
            doc.layers.filter { if case .unsupported = $0.content { return true } else { return false } }.count
        }
        XCTAssertLessThan(unsupportedCount(with), unsupportedCount(without),
                          "assets를 주면 해석되는 레이어가 늘어야 한다")
    }

    /// composelayer는 assets가 있어도 렌더 타깃이라 그릴 수 없다. 이유가 구분되어야 한다.
    func testComposeLayerBecomesACompositionLayer() throws {
        guard let reader = try scenePkg("3552439823") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let doc = try SceneDocument.load(from: reader, assets: assets)
        // 실물 오디오 비주얼라이저. `_rt_FullFrameBuffer`를 읽는 합성 레이어이고,
        // 그 위에 오디오 막대 이펙트가 붙는다.
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "Audio Visualizer" })
        XCTAssertEqual(layer.content, .composition)
        XCTAssertFalse(layer.effects.isEmpty, "막대를 그리는 이펙트가 붙어 있어야 한다")
    }

    /// assets의 모든 .tex가 파싱되어야 한다. M2의 이해는 여기서 불완전했다.
    /// 각 파일이 정확히 소비되는지 검증한다 — 파서가 남은 바이트를 남겨두면
    /// 그것을 감지한다. M2의 대결함이 정확히 이것이었다.
    func testAllAssetTexturesParse() throws {
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let root = assets.root
        var checked = 0
        var failures: [String] = []
        var residualFailures: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "tex" else { continue }
            // LUT는 TEXV 매직이 없는 컬러 그레이딩 원시 데이터다.
            guard !url.path.contains("/lut/") else { continue }
            let data = try Data(contentsOf: url)
            checked += 1
            do {
                let header = try TexHeader.parse(data)
                if header.consumedBytes != data.count {
                    residualFailures.append(
                        "\(url.lastPathComponent): parsed \(header.consumedBytes) of \(data.count) bytes"
                    )
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        XCTAssertGreaterThan(checked, 250, "검사한 텍스처가 너무 적다")
        XCTAssertTrue(failures.isEmpty, "파싱 실패 \(failures.count)건: \(failures.prefix(5))")
        XCTAssertTrue(residualFailures.isEmpty, "잔여 바이트 \(residualFailures.count)건: \(residualFailures.prefix(5))")
    }

    /// M4 목표 씬의 파티클 세 개가 해석되어야 한다.
    /// Rain perspective는 visible:false라 렌더 대상이 아니지만 해석은 된다.
    func testTargetSceneParticlesResolve() throws {
        guard let reader = try scenePkg("3714517753"),
              let assets = try assetsStore() else {
            throw XCTSkip("환경변수 미설정")
        }
        let doc = try SceneDocument.load(from: reader, assets: assets)
        let particles = doc.layers.compactMap { layer -> ParticlePreset? in
            if case .particle(let preset, _, _, _, _) = layer.content { return preset }
            return nil
        }
        XCTAssertEqual(particles.count, 3, "Snow flat, Rain perspective, Sakura")
        XCTAssertTrue(particles.allSatisfy { $0.maxCount > 0 }, "maxCount가 0인 프리셋이 있다")
        // 이미터가 없으면 아무것도 방출하지 못한다. dust_motes_0이 실제로 그랬다.
        XCTAssertTrue(particles.allSatisfy { !$0.emitters.isEmpty }, "이미터가 없는 프리셋이 있다")
    }

    /// Task 4b: 실물 씬의 파티클 프리셋에서 malformedNames가 비어 있어야 한다.
    func testRealScenesParticlePresetsAreParsedCorrectly() throws {
        guard let root, let assets = try assetsStore() else {
            throw XCTSkip("환경변수 미설정")
        }

        var allMalformed: [String: [(String, [String])]] = [:]  // scene ID -> [(layer name, malformed names)]
        var dustMotesEmitterCount: [String: Int] = [:]  // scene ID -> emitter count for dust_motes_0

        for id in try FileManager.default.contentsOfDirectory(atPath: root.path)
            where id.allSatisfy(\.isNumber) && FileManager.default.fileExists(
                atPath: root.appendingPathComponent(id)
                    .appendingPathComponent("scene.pkg").path) {
            guard let reader = try scenePkg(id) else { continue }
            do {
                let doc = try SceneDocument.load(from: reader, assets: assets)
                for layer in doc.layers {
                    if case .particle(let preset, _, _, _, _) = layer.content {
                        if !preset.malformedNames.isEmpty {
                            if allMalformed[id] == nil { allMalformed[id] = [] }
                            allMalformed[id]?.append((layer.name, preset.malformedNames))
                        }
                        if layer.name == "dust_motes_0" {
                            dustMotesEmitterCount[id] = preset.emitters.count
                        }
                    }
                }
            } catch {
                // 씬 로드 실패는 무시. 이 테스트는 파티클만 검증한다.
            }
        }

        // 모든 씬의 파티클 프리셋에서 malformedNames가 비어 있어야 한다.
        XCTAssertTrue(allMalformed.isEmpty,
                     "실물 씬의 파티클 필드가 잘못되었다. 씬별 malformed 필드:\n" +
                     allMalformed.sorted { $0.key < $1.key }
                         .map { id, layers in
                             "\(id): " + layers.map { "레이어 '\($0)': \($1.joined(separator: ", "))" }
                                 .joined(separator: "; ")
                         }.joined(separator: "\n"))

        // dust_motes_0의 이미터가 1개 이상이어야 한다.
        if let emitterCount = dustMotesEmitterCount[dustMotesEmitterCount.keys.first ?? ""] {
            XCTAssertGreaterThanOrEqual(emitterCount, 1,
                                       "dust_motes_0 레이어의 이미터가 없다")
        }
    }
}

/// ROOT는 유효한데 이름 붙인 씬 디렉토리가 없을 때 던진다. XCTFail로 이미 실패를
/// 기록한 뒤 이 오류를 던져, 호출부의 XCTSkip 폴백이 그 실패를 "미설정"으로
/// 가려버리지 않게 한다.
private struct MissingSceneError: Error {
    let path: String?

    init(path: String? = nil) {
        self.path = path
    }
}
