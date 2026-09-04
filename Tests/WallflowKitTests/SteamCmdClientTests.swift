import XCTest
@testable import WallflowKit

final class SteamCmdClientTests: XCTestCase {
    private let installDir = URL(fileURLWithPath: "/tmp/wf-install")

    func testArgumentsIncludeWallpaperEngineAppID() {
        let args = SteamCmdClient.arguments(
            login: "someuser", workshopID: "3714517753", installDirectory: installDir
        )
        XCTAssertTrue(args.contains("431960"))
        XCTAssertEqual(SteamCmdClient.wallpaperEngineAppID, "431960")
    }

    func testArgumentsAreInSteamCmdOrder() {
        let args = SteamCmdClient.arguments(
            login: "someuser", workshopID: "3714517753", installDirectory: installDir
        )
        XCTAssertEqual(args, [
            "+force_install_dir", "/tmp/wf-install",
            "+login", "someuser",
            "+workshop_download_item", "431960", "3714517753",
            "+quit",
        ])
    }

    /// force_install_dir는 login보다 먼저 와야 적용된다. steamcmd의 알려진 함정이다.
    func testInstallDirectoryPrecedesLogin() {
        let args = SteamCmdClient.arguments(
            login: "u", workshopID: "1", installDirectory: installDir
        )
        let dirIndex = args.firstIndex(of: "+force_install_dir")!
        let loginIndex = args.firstIndex(of: "+login")!
        XCTAssertLessThan(dirIndex, loginIndex)
    }

    func testUnavailableWhenExecutableIsNil() {
        let client = SteamCmdClient(executable: nil, installDirectory: installDir)
        XCTAssertFalse(client.isAvailable)
    }

    func testDownloadWithoutExecutableThrowsNotInstalled() {
        let client = SteamCmdClient(executable: nil, installDirectory: installDir)
        XCTAssertThrowsError(try client.download(workshopID: "123", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .notInstalled)
        }
    }

    func testRejectsNonNumericWorkshopID() {
        let client = SteamCmdClient(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            installDirectory: installDir
        )
        XCTAssertThrowsError(try client.download(workshopID: "abc; rm -rf /", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .invalidWorkshopID("abc; rm -rf /"))
        }
    }

    func testRejectsEmptyWorkshopID() {
        let client = SteamCmdClient(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            installDirectory: installDir
        )
        XCTAssertThrowsError(try client.download(workshopID: "", login: "u")) { error in
            XCTAssertEqual(error as? SteamCmdError, .invalidWorkshopID(""))
        }
    }

    func testLocateExecutableFindsExistingPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("steamcmd")
        try Data("#!/bin/sh\n".utf8).write(to: fake)

        let missing = dir.appendingPathComponent("nope/steamcmd")
        XCTAssertEqual(SteamCmdClient.locateExecutable(searching: [missing, fake]), fake)
    }

    func testLocateExecutableReturnsNilWhenNoneExist() {
        let missing = URL(fileURLWithPath: "/definitely/not/here/steamcmd")
        XCTAssertNil(SteamCmdClient.locateExecutable(searching: [missing]))
    }
}
