import XCTest
@testable import WallflowKit

final class WorkshopInstallerTests: XCTestCase {
    private var temp: URL!
    private var installer: WorkshopInstaller!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-install-\(UUID().uuidString)")
        installer = WorkshopInstaller(
            downloadRoot: temp.appendingPathComponent("downloads"),
            libraryRoot: temp.appendingPathComponent("library"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeDownloaded(_ id: String) throws -> URL {
        let folder = installer.downloadedFolder(id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    /// 복사가 아니라 링크여야 한다. 씬 하나가 1GB를 넘기도 한다.
    func testLinksInsteadOfCopying() throws {
        let source = try makeDownloaded("123")
        try installer.link(id: "123")
        let linked = installer.libraryRoot.appendingPathComponent("123")
        let type = try FileManager.default.attributesOfItem(atPath: linked.path)[.type]
            as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "복사하면 디스크를 두 배로 쓴다")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linked.path),
            source.path)
        XCTAssertTrue(installer.isInstalled(id: "123"))
    }

    func testLinkIsIdempotent() throws {
        _ = try makeDownloaded("123")
        try installer.link(id: "123")
        try installer.link(id: "123")
        XCTAssertTrue(installer.isInstalled(id: "123"))
    }

    /// 원본 경로가 바뀌어 링크가 끊어졌으면 다시 걸어야 한다.
    /// fileExists는 끊어진 링크를 없다고 답하므로 그것만 보면 다시 걸지 못한다.
    func testRelinksBrokenLink() throws {
        try FileManager.default.createDirectory(
            at: installer.libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.libraryRoot.appendingPathComponent("123"),
            withDestinationURL: URL(fileURLWithPath: "/없는/경로"))
        let source = try makeDownloaded("123")
        try installer.link(id: "123")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: installer.libraryRoot.appendingPathComponent("123").path),
            source.path)
    }

    func testLinkWithoutDownloadThrows() {
        XCTAssertThrowsError(try installer.link(id: "999")) { error in
            guard case WorkshopInstallError.downloadedFolderMissing = error else {
                return XCTFail("받은 폴더가 없다고 알려야 한다: \(error)")
            }
        }
    }

    /// unlink는 링크만 걷는다. 원본은 남아야 다시 받지 않는다.
    func testUnlinkKeepsDownload() throws {
        _ = try makeDownloaded("123")
        try installer.link(id: "123")
        XCTAssertTrue(try installer.unlink(id: "123"))
        XCTAssertFalse(installer.isInstalled(id: "123"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.downloadedFolder(id: "123").path), "원본까지 지우면 안 된다")
    }

    /// 사용자가 직접 넣은 실제 폴더는 지우지 않는다. 되돌릴 수 없다.
    func testUnlinkRefusesRealDirectory() throws {
        let real = installer.libraryRoot.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        XCTAssertFalse(try installer.unlink(id: "mine"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }
}
