import Foundation

public enum SteamCmdError: Error, Equatable {
    case notInstalled
    case invalidWorkshopID(String)
    case downloadFailed(exitCode: Int32, output: String)
}

/// steamcmd를 감싸 창작마당 아이템을 받아온다.
/// 사용자가 Wallpaper Engine을 소유하고 있어야 하며, 본인 계정으로 로그인한다.
public struct SteamCmdClient: Sendable {
    public static let wallpaperEngineAppID = "431960"

    /// brew와 수동 설치의 통상 경로.
    public static let defaultSearchPaths = [
        URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
        URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
    ]

    public let executable: URL?
    public let installDirectory: URL

    public init(executable: URL?, installDirectory: URL) {
        self.executable = executable
        self.installDirectory = installDirectory
    }

    public var isAvailable: Bool { executable != nil }

    public static func locateExecutable(searching paths: [URL] = defaultSearchPaths) -> URL? {
        paths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// steamcmd는 인자 순서에 민감하다. force_install_dir가 login보다 앞서야 적용된다.
    public static func arguments(
        login: String, workshopID: String, installDirectory: URL
    ) -> [String] {
        [
            "+force_install_dir", installDirectory.path,
            "+login", login,
            "+workshop_download_item", wallpaperEngineAppID, workshopID,
            "+quit",
        ]
    }

    /// 창작마당 아이템을 받아 내려받은 폴더 경로를 돌려준다.
    /// Steam Guard가 걸려 있으면 실패한다. 그 경우 수동 폴더 임포트를 쓴다.
    @discardableResult
    public func download(workshopID: String, login: String) throws -> URL {
        guard let executable else { throw SteamCmdError.notInstalled }
        // 인자로 그대로 넘어가므로 숫자만 허용한다.
        guard !workshopID.isEmpty, workshopID.allSatisfy(\.isNumber) else {
            throw SteamCmdError.invalidWorkshopID(workshopID)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(
            login: login, workshopID: workshopID, installDirectory: installDirectory
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SteamCmdError.downloadFailed(
                exitCode: process.terminationStatus, output: output
            )
        }

        return installDirectory
            .appendingPathComponent("steamapps/workshop/content")
            .appendingPathComponent(Self.wallpaperEngineAppID)
            .appendingPathComponent(workshopID)
    }
}
