import XCTest
@testable import WallflowKit

final class LocalVideoImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-local-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 임의 바이트로 "동영상" 더미를 만든다. Kit 임포터는 내용을 보지 않고
    /// 복사·project.json 작성만 하므로 실제 영상일 필요가 없다.
    private func makeSource(name: String, bytes: String = "video-bytes") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func testImportCreatesDiscoverableVideoItem() throws {
        let source = try makeSource(name: "My Clip.mp4")
        let item = try LocalVideoImporter.importVideo(from: source, title: nil, into: root)

        XCTAssertTrue(item.id.hasPrefix("local-"), "로컬 항목 id는 local- 접두사여야 한다")
        XCTAssertEqual(item.type, .video)
        XCTAssertEqual(item.title, "My Clip", "제목 없으면 파일명(확장자 제외)")
        XCTAssertNil(item.unsupportedReason)

        // 라이브러리 스캔이 그대로 발견해야 한다(새 렌더 경로 없음).
        let scanned = try LibraryStore(root: root).scan()
        XCTAssertEqual(scanned.map(\.id), [item.id])

        // 원본은 복사되고 그대로 남는다.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.contentURL.path))
    }

    func testImportUsesGivenTitle() throws {
        let source = try makeSource(name: "clip.mov")
        let item = try LocalVideoImporter.importVideo(from: source, title: "내 배경", into: root)
        XCTAssertEqual(item.title, "내 배경")
        XCTAssertEqual(item.contentURL.pathExtension, "mov")
    }

    /// 확장자 없는 파일은 mp4로 가정한다(AVFoundation이 대개 연다).
    func testImportWithoutExtensionAssumesMp4() throws {
        let source = try makeSource(name: "noext")
        let item = try LocalVideoImporter.importVideo(from: source, title: nil, into: root)
        XCTAssertEqual(item.contentURL.lastPathComponent, "video.mp4")
        XCTAssertEqual(item.type, .video)
    }

    /// 복사가 실패하면(원본 없음) 깨진 폴더를 남기지 않는다.
    func testFailedImportLeavesNoBrokenFolder() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        XCTAssertThrowsError(try LocalVideoImporter.importVideo(from: missing, title: nil, into: root))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, [], "실패 후 local- 폴더가 남으면 안 된다")
    }

    func testDeleteRemovesLocalItem() throws {
        let source = try makeSource(name: "clip.mp4")
        let item = try LocalVideoImporter.importVideo(from: source, title: nil, into: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.directory.path))

        try LocalVideoImporter.deleteLocal(item, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.directory.path))
    }

    /// 마커 없는 폴더(창작마당 항목)는 절대 지우지 않는다.
    func testDeleteRefusesNonLocalFolder() throws {
        let dir = root.appendingPathComponent("123456")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"video","file":"bg.mp4","title":"창작마당"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("bg.mp4"))
        let item = try WallpaperItem.load(from: dir)

        XCTAssertThrowsError(try LocalVideoImporter.deleteLocal(item, root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "창작마당 폴더가 지워지면 안 된다")
    }

    /// 심볼릭 링크(창작마당 설치 링크)는 절대 지우지 않는다.
    func testDeleteRefusesSymlink() throws {
        // 바깥에 진짜 로컬 항목을 하나 만들고, root 안에는 그 폴더로의 링크만 둔다.
        let outside = try makeSource(name: "clip.mp4")
        let realItem = try LocalVideoImporter.importVideo(
            from: outside, title: nil,
            into: FileManager.default.temporaryDirectory
                .appendingPathComponent("wf-outside-\(UUID().uuidString)", isDirectory: true))
        // 바깥 루트를 만들어 둔다
        try FileManager.default.createDirectory(
            at: realItem.directory.deletingLastPathComponent(), withIntermediateDirectories: true)

        let link = root.appendingPathComponent("local-linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realItem.directory)
        let linkedItem = try WallpaperItem.load(from: link)

        XCTAssertThrowsError(try LocalVideoImporter.deleteLocal(linkedItem, root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realItem.directory.path),
                      "링크 대상(실제 폴더)이 지워지면 안 된다")
    }
}
