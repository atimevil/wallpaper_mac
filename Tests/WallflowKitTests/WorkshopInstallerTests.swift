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

/// "지우기"는 링크만 걷는 게 아니라 **받아 둔 원본까지** 지운다.
///
/// 링크만 걷어내면 디스크에 수백 MB가 남는데 목록에는 안 보여, 사용자는
/// 그게 남아 있는지 알 길이 없다. 다만 우리가 받은 자리 안의 폴더만 지운다 —
/// 사용자가 직접 넣은 폴더를 지우는 것은 배경화면 앱이 할 일이 아니다.
extension WorkshopInstallerTests {
    func testRemoveDeletesOurDownload() throws {
        let source = try makeDownloadedForRemove("777")
        try installer.link(id: "777")
        XCTAssertEqual(try installer.remove(id: "777"), .deletedDownload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "원본이 남았다")
        XCTAssertFalse(installer.isInstalled(id: "777"), "링크가 남았다")
    }

    /// 링크가 우리 자리 밖을 가리키면 링크만 걷고 원본은 둔다.
    func testRemoveKeepsForeignFolder() throws {
        let foreign = temp.appendingPathComponent("elsewhere/888")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installer.libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.libraryRoot.appendingPathComponent("888"),
            withDestinationURL: foreign)
        XCTAssertEqual(try installer.remove(id: "888"), .unlinkedOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "남의 폴더를 지웠다")
        XCTAssertFalse(installer.isInstalled(id: "888"))
    }

    /// `..`로 우리 자리를 빠져나가는 링크도 밖으로 본다.
    func testRemoveRefusesEscapingLink() throws {
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installer.downloadRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installer.libraryRoot, withIntermediateDirectories: true)
        let sneaky = installer.downloadRoot.appendingPathComponent("../outside").path
        try FileManager.default.createSymbolicLink(
            atPath: installer.libraryRoot.appendingPathComponent("999").path,
            withDestinationPath: sneaky)
        XCTAssertEqual(try installer.remove(id: "999"), .unlinkedOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// 실제 폴더(링크가 아닌 것)는 건드리지 않는다.
    func testRemoveRefusesRealDirectory() throws {
        let real = installer.libraryRoot.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        XCTAssertNil(try installer.remove(id: "mine"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    private func makeDownloadedForRemove(_ id: String) throws -> URL {
        let folder = installer.downloadedFolder(id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }
}
