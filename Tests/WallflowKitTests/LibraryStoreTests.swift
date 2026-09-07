import XCTest
@testable import WallflowKit

final class LibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 창작마당 폴더 하나를 흉내낸다.
    @discardableResult
    private func makeItem(id: String, json: String, files: [String] = []) throws -> URL {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    func testLoadsVideoItem() throws {
        let dir = try makeItem(
            id: "111",
            json: #"{"type":"video","file":"bg.mp4","title":"My Video"}"#,
            files: ["bg.mp4", "preview.jpg"]
        )
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.id, "111")
        XCTAssertEqual(item.title, "My Video")
        XCTAssertEqual(item.type, .video)
        XCTAssertEqual(item.contentURL.lastPathComponent, "bg.mp4")
        XCTAssertEqual(item.previewURL?.lastPathComponent, "preview.jpg")
    }

    /// 실물에서 preview가 .gif인 경우가 있었다(3536506287).
    func testFindsGifPreview() throws {
        let dir = try makeItem(
            id: "222",
            json: #"{"type":"web","file":"index.html","title":"W"}"#,
            files: ["index.html", "preview.gif"]
        )
        XCTAssertEqual(try WallpaperItem.load(from: dir).previewURL?.lastPathComponent, "preview.gif")
    }

    func testMissingPreviewIsNil() throws {
        let dir = try makeItem(
            id: "333",
            json: #"{"type":"video","file":"bg.mp4","title":"V"}"#,
            files: ["bg.mp4"]
        )
        XCTAssertNil(try WallpaperItem.load(from: dir).previewURL)
    }

    func testTitleFallsBackToDirectoryName() throws {
        let dir = try makeItem(
            id: "444",
            json: #"{"type":"video","file":"bg.mp4"}"#,
            files: ["bg.mp4"]
        )
        XCTAssertEqual(try WallpaperItem.load(from: dir).title, "444")
    }

    /// 열 수 없는 항목도 **목록에는 남는다.** 조용히 빼면 사용자는 자기가 받은
    /// 것이 왜 안 보이는지 알 수 없다. 대신 이유를 들고 있다가 말해 준다.
    func testMissingFileFieldIsListedWithReason() throws {
        let dir = try makeItem(id: "555", json: #"{"type":"video","title":"V"}"#)
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.title, "V", "이름은 그대로 보여야 한다")
        XCTAssertEqual(item.type, .unsupported)
        XCTAssertEqual(item.unsupportedReason, "project.json에 file이 없다")
    }

    /// `type`이 없는 것도 마찬가지다.
    func testMissingTypeIsListedWithReason() throws {
        let dir = try makeItem(id: "556", json: #"{"file":"bg.mp4","title":"T"}"#)
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.type, .unsupported)
        XCTAssertEqual(item.unsupportedReason, "project.json에 type이 없다")
    }

    /// 실물 "Project Zomboid pixel"이 이 꼴이다 — `dependency`만 있고 `file`이
    /// 없다. 알맹이가 다른 창작마당 항목에 있어서 이 폴더만으로는 못 연다.
    /// 예전에는 목록에서 통째로 사라져, 검은 화면만 남고 이유가 없었다.
    func testDependencyPresetIsListedWithReason() throws {
        let dir = try makeItem(
            id: "557",
            json: #"{"dependency":"3122339805","title":"Zomboid","preset":{"a":1}}"#)
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.title, "Zomboid")
        XCTAssertEqual(item.type, .unsupported)
        XCTAssertEqual(
            item.unsupportedReason,
            "다른 창작마당 항목(3122339805)에 딸린 프리셋이다. 그 항목도 받아야 한다")
    }

    /// 열 수 있는 것은 이유가 없어야 한다. 전부 이유를 달면 구별이 안 된다.
    func testOpenableItemHasNoReason() throws {
        let dir = try makeItem(
            id: "558", json: #"{"type":"video","file":"bg.mp4","title":"V"}"#,
            files: ["bg.mp4"])
        XCTAssertNil(try WallpaperItem.load(from: dir).unsupportedReason)
    }

    /// webm/mkv는 macOS AVFoundation이 컨테이너 단계에서부터 못 연다(실측,
    /// UnsupportedVideoFormat.swift 참고). VideoRenderer가 검은 화면만 남기고
    /// 조용히 실패하지 않도록, load() 단계에서부터 이유를 달아 목록에 남긴다.
    func testVideoWithWebmExtensionIsListedWithReason() throws {
        let dir = try makeItem(
            id: "600",
            json: #"{"type":"video","file":"bg.webm","title":"WebM 배경"}"#,
            files: ["bg.webm"])
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.title, "WebM 배경")
        XCTAssertEqual(item.type, .unsupported)
        XCTAssertNotNil(item.unsupportedReason)
        XCTAssertTrue(item.unsupportedReason!.contains("WebM"))
    }

    func testVideoWithMkvExtensionIsListedWithReason() throws {
        let dir = try makeItem(
            id: "601",
            json: #"{"type":"video","file":"bg.mkv","title":"MKV 배경"}"#,
            files: ["bg.mkv"])
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.type, .unsupported)
        XCTAssertNotNil(item.unsupportedReason)
    }

    /// web 타입에 붙은 .webm 파일은(있을 법하지 않지만) video가 아니므로
    /// 컨테이너 검사 대상이 아니다 — video 타입에서만 이 검사를 한다.
    func testNonVideoTypeIsNotCheckedForContainer() throws {
        let dir = try makeItem(
            id: "602",
            json: #"{"type":"web","file":"clip.webm","title":"안건드림"}"#,
            files: ["clip.webm"])
        let item = try WallpaperItem.load(from: dir)
        XCTAssertEqual(item.type, .web)
        XCTAssertNil(item.unsupportedReason)
    }

    func testScanReturnsItemsSortedByTitle() throws {
        try makeItem(id: "b", json: #"{"type":"video","file":"a.mp4","title":"Zebra"}"#, files: ["a.mp4"])
        try makeItem(id: "a", json: #"{"type":"video","file":"a.mp4","title":"Apple"}"#, files: ["a.mp4"])
        let items = try LibraryStore(root: root).scan()
        XCTAssertEqual(items.map(\.title), ["Apple", "Zebra"])
    }

    /// 손상된 폴더 하나가 라이브러리 전체를 못 쓰게 만들면 안 된다.
    func testScanSkipsUnreadableDirectories() throws {
        try makeItem(id: "good", json: #"{"type":"video","file":"a.mp4","title":"Good"}"#, files: ["a.mp4"])
        try makeItem(id: "bad", json: "garbage")
        let items = try LibraryStore(root: root).scan()
        XCTAssertEqual(items.map(\.title), ["Good"])
    }

    func testScanIgnoresLooseFiles() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try makeItem(id: "good", json: #"{"type":"video","file":"a.mp4","title":"Good"}"#, files: ["a.mp4"])
        XCTAssertEqual(try LibraryStore(root: root).scan().count, 1)
    }

    /// 배경화면은 용량이 커서 라이브러리 밖에 두고 링크로 참조하는 것이 자연스럽다.
    /// URL의 isDirectoryKey는 심볼릭 링크를 디렉터리로 보지 않으므로 별도 처리가 필요하다.
    func testScanFollowsDirectorySymlinks() throws {
        let outside = root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let real = outside.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(#"{"type":"video","file":"a.mp4","title":"Linked"}"#.utf8)
            .write(to: real.appendingPathComponent("project.json"))
        try Data("x".utf8).write(to: real.appendingPathComponent("a.mp4"))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: real
        )

        let titles = try LibraryStore(root: root).scan().map(\.title)
        XCTAssertTrue(titles.contains("Linked"), "심볼릭 링크로 참조한 배경화면이 목록에 없다: \(titles)")
    }

    func testScanOnMissingRootReturnsEmpty() throws {
        let missing = root.appendingPathComponent("nope")
        XCTAssertEqual(try LibraryStore(root: missing).scan(), [])
    }
}

extension LibraryStoreTests {
    /// project.json의 file이 가리키는 이름으로 .pkg를 찾아야 한다.
    /// 실물 창작마당 씬에 gifscene.json / gifscene.pkg인 것이 있다.
    /// scene.pkg로 하드코딩하면 그런 씬은 통째로 열리지 않는다.
    func testPackageNameFollowsProjectFile() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-pkgname-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let dir = temp.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","title":"gif","file":"gifscene.json"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("gifscene.pkg"))

        let items = try LibraryStore(root: temp).scan()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.packageURL.lastPathComponent, "gifscene.pkg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.packageURL.path))
    }

    /// 평범한 씬은 그대로 scene.pkg다.
    func testPackageNameDefaultsToScene() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-pkgname2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let dir = temp.appendingPathComponent("456")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","title":"s","file":"scene.json"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("scene.pkg"))
        let item = try XCTUnwrap(try LibraryStore(root: temp).scan().first)
        XCTAssertEqual(item.packageURL.lastPathComponent, "scene.pkg")
    }
}
