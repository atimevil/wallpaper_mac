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
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.allSatisfy(\.isNumber) }
        XCTAssertFalse(ids.isEmpty, "테스트할 씬이 없다")

        for id in ids {
            guard let reader = try scenePkg(id) else { continue }
            let doc = try SceneDocument.load(from: reader)
            XCTAssertGreaterThan(doc.layers.count, 0, "\(id)에 레이어가 없다")
            XCTAssertGreaterThan(doc.orthoWidth, 0, "\(id)의 직교 폭이 0이다")

            // 모든 .tex가 헤더 파싱은 되어야 한다.
            for name in reader.names where name.hasSuffix(".tex") {
                let data = try reader.data(for: name)
                XCTAssertNoThrow(try TexHeader.parse(data), "\(id)/\(name) 헤더 파싱 실패")
            }
        }
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
    func testScriptedOriginImageLayersBecomeUnsupported() throws {
        let cases = [("3536506287", "Audio bar"), ("3552439823", "cursor")]
        for (id, name) in cases {
            guard let reader = try scenePkg(id) else {
                throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
            }
            let doc = try SceneDocument.load(from: reader)
            guard let layer = doc.layers.first(where: { $0.name == name }) else {
                XCTFail("\(id)에 레이어 '\(name)'이 없다")
                continue
            }
            guard case .unsupported(let reason) = layer.content else {
                return XCTFail("\(id)/\(name)은 스크립트 origin이라 unsupported여야 한다")
            }
            // 이유까지 확인해야 origin 가드를 탔다는 것이 증명된다.
            // 다른 가드에 걸려도 unsupported가 되기 때문이다.
            XCTAssertTrue(
                reason.contains("스크립트"),
                "\(id)/\(name)이 origin 가드가 아닌 다른 이유로 걸렸다: \(reason)"
            )
        }
    }

    /// 파티클과 텍스트 레이어는 M2가 그리지 않는다.
    /// origin 가드보다 앞에서 각자의 이유로 걸러져야 한다.
    func testParticleAndTextLayersAreUnsupportedForTheirOwnReason() throws {
        let cases = [
            ("3552439823", "zzz", "파티클"),
            ("3616103296", "Song Title", "텍스트"),
            ("3616103296", "Clock", "텍스트"),
        ]
        for (id, name, expectedReason) in cases {
            guard let reader = try scenePkg(id) else {
                throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
            }
            let doc = try SceneDocument.load(from: reader)
            guard let layer = doc.layers.first(where: { $0.name == name }) else {
                XCTFail("\(id)에 레이어 '\(name)'이 없다")
                continue
            }
            guard case .unsupported(let reason) = layer.content else {
                return XCTFail("\(id)/\(name)은 unsupported여야 한다")
            }
            XCTAssertTrue(
                reason.contains(expectedReason),
                "\(id)/\(name)의 이유가 '\(expectedReason)'을 담지 않는다: \(reason)"
            )
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
    func testComposeLayerReportsRenderTargetEvenWithAssets() throws {
        guard let reader = try scenePkg("3552439823") else {
            throw XCTSkip("WALLFLOW_TEST_SCENES 미설정")
        }
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let doc = try SceneDocument.load(from: reader, assets: assets)
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "Audio Visualizer" })
        guard case .unsupported(let reason) = layer.content else {
            return XCTFail("렌더 타깃 레이어는 여전히 unsupported여야 한다")
        }
        XCTAssertTrue(reason.contains("렌더 타깃"), "이유: \(reason)")
    }

    /// assets의 모든 .tex가 파싱되어야 한다. M2의 이해는 여기서 불완전했다.
    func testAllAssetTexturesParse() throws {
        guard let assets = try assetsStore() else {
            throw XCTSkip("WALLFLOW_TEST_ASSETS 미설정")
        }
        let root = assets.root
        var checked = 0
        var failures: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "tex" else { continue }
            // LUT는 TEXV 매직이 없는 컬러 그레이딩 원시 데이터다.
            guard !url.path.contains("/lut/") else { continue }
            let data = try Data(contentsOf: url)
            checked += 1
            do { _ = try TexHeader.parse(data) }
            catch { failures.append("\(url.lastPathComponent): \(error)") }
        }
        XCTAssertGreaterThan(checked, 250, "검사한 텍스처가 너무 적다")
        XCTAssertTrue(failures.isEmpty, "파싱 실패 \(failures.count)건: \(failures.prefix(5))")
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
