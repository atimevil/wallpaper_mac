import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallflowKit

/// 창작마당 프리셋 항목: 다른 배경화면(`dependency`)의 설정 묶음이다. 알맹이 옆에
/// 받아져 있으면 그 씬을 프리셋의 값으로 연다. 실물 "Project Zomboid pixel"이 이 꼴이다.
final class PresetItemTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private let dependencyProject = """
    {"title": "Pixels", "type": "scene", "file": "scene.json",
     "general": {"properties": {
        "city1": {"type": "textinput", "value": "TYO", "text": "City 1"},
        "rate": {"type": "slider", "min": 0, "max": 200, "value": 60, "text": "Rate"},
        "hideeyes": {"type": "bool", "value": false, "text": "Hide"},
        "schemecolor": {"type": "color", "value": "1 1 1", "text": "ui_browse_properties_scheme_color"},
        "customimageleft": {"type": "scenetexture", "value": "", "text": "Left Custom Image"}
     }}}
    """

    private func makePair(presetFiles: Bool = true) throws {
        try write("3122339805/project.json", dependencyProject)
        try write("3122339805/scene.json", "{}")
        try write("3793977966/project.json", """
        {"title": "Project Zomboid pixel", "dependency": "3122339805", "preview": "preview.jpg",
         "preset": {"city1": "MOSCOW", "rate": 116, "hideeyes": true, "schemecolor": "0 0 0",
                    "customimageleft": "files/spiffo.gif", "unknown": 5}}
        """)
        if presetFiles { try write("3793977966/files/spiffo.gif", "GIF89a") }
    }

    func testPresetOpensTheDependencyWithItsValues() throws {
        try makePair()
        let item = try WallpaperItem.load(from: root.appendingPathComponent("3793977966"))
        XCTAssertNil(item.unsupportedReason)
        XCTAssertEqual(item.id, "3793977966")
        XCTAssertEqual(item.title, "Project Zomboid pixel")
        XCTAssertEqual(item.type, .scene)
        XCTAssertEqual(item.dependencyID, "3122339805")
        XCTAssertEqual(item.directory.lastPathComponent, "3122339805")
        XCTAssertEqual(item.contentURL.lastPathComponent, "scene.json")
        XCTAssertEqual(item.presetDirectory?.lastPathComponent, "3793977966")
        XCTAssertEqual(item.presetValues["city1"], .text("MOSCOW"))
        XCTAssertEqual(item.presetValues["rate"], .number(116))
        XCTAssertEqual(item.presetValues["hideeyes"], .toggle(true))
        XCTAssertEqual(item.presetValues["schemecolor"], .color(Vec3(x: 0, y: 0, z: 0)))
        // 텍스처는 프리셋 폴더 안의 절대 경로가 된다.
        guard case .text(let path)? = item.presetValues["customimageleft"] else {
            return XCTFail("텍스처 값이 없다")
        }
        XCTAssertTrue(path.hasSuffix("3793977966/files/spiffo.gif"), path)
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertNil(item.presetValues["unknown"], "알맹이에 없는 속성은 버린다")
    }

    func testPresetWithoutDependencyStaysUnopenableButNamesIt() throws {
        try write("3793977966/project.json", """
        {"title": "P", "dependency": "3122339805", "preset": {}}
        """)
        let item = try WallpaperItem.load(from: root.appendingPathComponent("3793977966"))
        XCTAssertNotNil(item.unsupportedReason)
        XCTAssertEqual(item.dependencyID, "3122339805")
        XCTAssertEqual(item.type, .unsupported)
    }

    /// 프리셋 폴더 밖을 가리키는 텍스처 경로는 버린다.
    func testTexturePathOutsidePresetFolderIsDropped() throws {
        try write("3122339805/project.json", dependencyProject)
        try write("3122339805/scene.json", "{}")
        try write("secret.txt", "x")
        try write("3793977966/project.json", """
        {"title": "P", "dependency": "3122339805", "preset": {"customimageleft": "../secret.txt"}}
        """)
        let item = try WallpaperItem.load(from: root.appendingPathComponent("3793977966"))
        XCTAssertNil(item.presetValues["customimageleft"])
    }

    /// 없는 파일도 버린다 — 씬이 빈 텍스처를 그리려다 죽지 않게.
    func testMissingTextureFileIsDropped() throws {
        try makePair(presetFiles: false)
        let item = try WallpaperItem.load(from: root.appendingPathComponent("3793977966"))
        XCTAssertNil(item.presetValues["customimageleft"])
    }

    func testSceneTextureKindIsRead() {
        let properties = UserProperty.load(projectJSON: Data(dependencyProject.utf8))
        let texture = properties.first { $0.name == "customimageleft" }
        XCTAssertEqual(texture?.kind, .texture)
        XCTAssertEqual(texture?.defaultValue, .text(""))
        XCTAssertEqual(texture?.label, "Left Custom Image")
    }

    /// 재질의 `usertextures` 슬롯에 값이 있으면 그 파일이 레이어의 그림이다.
    func testUserTextureReplacesMaterialSlot() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "City Video", "image": "models/city.json",
                      "origin": "0 0 0", "size": "10 10"}]}
        """
        let entries: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/city.json", Data(#"{"material": "materials/city.json"}"#.utf8)),
            ("materials/city.json", Data(#"{"passes": [{"shader": "genericimage3", "textures": ["city"], "usertextures": ["customimageright"]}]}"#.utf8)),
        ]
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: entries))
        let plain = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(plain.layers[0].content, .image(texturePath: "materials/city.tex"))
        let custom = try SceneDocument.load(
            from: reader, assets: nil, userTextures: ["customimageright": "/tmp/p/files/a.mp4"])
        XCTAssertEqual(custom.layers[0].content, .image(texturePath: "@file:/tmp/p/files/a.mp4"))
        // 다른 속성의 값은 이 슬롯과 무관하다.
        let other = try SceneDocument.load(
            from: reader, assets: nil, userTextures: ["customimageleft": "/tmp/p/files/a.mp4"])
        XCTAssertEqual(other.layers[0].content, .image(texturePath: "materials/city.tex"))
    }

    /// 단색(flat) 레이어의 색이 사용자 속성에 묶여 있으면 그 값을 쓴다 — 프리셋이 창 색을 바꾼다.
    func testSolidLayerColorBoundToUserPropertyIsHonored() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "name": "Window", "image": "models/solid.json", "origin": "0 0 0",
                      "size": "10 10", "color": {"user": "basecolor", "value": "0.9 0.9 0.9"}}]}
        """
        let entries: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/solid.json", Data(#"{"material": "materials/solid.json"}"#.utf8)),
            ("materials/solid.json", Data(#"{"passes": [{"shader": "flat"}]}"#.utf8)),
        ]
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: entries))
        let stored = try SceneDocument.load(from: reader, assets: nil)
        XCTAssertEqual(stored.layers[0].content, .solidColor(Vec3(x: 0.9, y: 0.9, z: 0.9)))
        let preset = try SceneDocument.load(
            from: reader, assets: nil, userOverrides: ["basecolor": .color(Vec3(x: 0.2, y: 0.2, z: 0.2))])
        XCTAssertEqual(preset.layers[0].content, .solidColor(Vec3(x: 0.2, y: 0.2, z: 0.2)))
    }

    /// 바깥 파일은 허용된 폴더 안에서만 읽는다.
    func testResolverReadsExternalFilesOnlyUnderAllowedRoots() throws {
        try write("preset/files/a.bin", "hello")
        try write("outside.bin", "secret")
        let reader = try PkgReader(data: buildPkg(version: "PKGV0023", entries: [("scene.json", Data("{}".utf8))]))
        let resolver = ReferenceResolver(pkg: reader, assets: nil,
                                         externalRoots: [root.appendingPathComponent("preset")])
        let inside = ReferenceResolver.externalPrefix + root.appendingPathComponent("preset/files/a.bin").path
        XCTAssertEqual(resolver.data(for: inside), Data("hello".utf8))
        let outside = ReferenceResolver.externalPrefix + root.appendingPathComponent("outside.bin").path
        XCTAssertNil(resolver.data(for: outside))
        let sneaky = ReferenceResolver.externalPrefix + root.appendingPathComponent("preset/files/../../outside.bin").path
        XCTAssertNil(resolver.data(for: sneaky))
        XCTAssertNil(ReferenceResolver(pkg: reader, assets: nil).data(for: inside), "허용 폴더가 없으면 아무것도 못 읽는다")
    }

    /// 보통 파일 디코더: png는 그림, `ftyp`는 영상, 쓰레기는 오류.
    func testDecodeFileHandlesImagesAndVideo() throws {
        let png = try Self.makePNG(width: 4, height: 3)
        guard case .image(let image) = try TexDecoder.decodeFile(png) else { return XCTFail("그림이 아니다") }
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        var mp4 = Data([0, 0, 0, 0x18])
        mp4.append(contentsOf: Array("ftypisom".utf8))
        mp4.append(contentsOf: [UInt8](repeating: 0, count: 16))
        guard case .video(let payload) = try TexDecoder.decodeFile(mp4) else { return XCTFail("영상이 아니다") }
        XCTAssertEqual(payload, mp4)
        XCTAssertThrowsError(try TexDecoder.decodeFile(Data("not an image".utf8)))
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw TexError.imageDecodeFailed }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { throw TexError.imageDecodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TexError.imageDecodeFailed }
        return out as Data
    }
}
