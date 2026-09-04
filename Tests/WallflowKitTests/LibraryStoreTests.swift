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

    func testMissingFileFieldThrows() throws {
        let dir = try makeItem(id: "555", json: #"{"type":"video","title":"V"}"#)
        XCTAssertThrowsError(try WallpaperItem.load(from: dir)) { error in
            guard case WallpaperError.missingField(let f) = error else {
                return XCTFail("expected missingField, got \(error)")
            }
            XCTAssertEqual(f, "file")
        }
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
