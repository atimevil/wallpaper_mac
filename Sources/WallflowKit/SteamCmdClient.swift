import Foundation

public enum SteamCmdError: Error, Equatable {
    case notInstalled
    case invalidWorkshopID(String)
    case downloadFailed(exitCode: Int32, output: String)
    /// 캐시된 자격 증명이 없거나 만료됐다. 사용자가 터미널에서 한 번 로그인해야 한다.
    /// steamcmd는 비밀번호와 Steam Guard 코드를 대화식으로만 받는다.
    case loginRequired(account: String)
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

    /// 스팀 앱이 남긴 `loginusers.vdf`에서 계정 이름을 읽는다.
    ///
    /// 비밀번호가 아니라 계정 이름만이다. 사용자가 매번 타이핑하지 않게 미리
    /// 채워 주려는 것이고, 못 읽으면 그냥 비워 둔다.
    /// 여러 계정이 있으면 `MostRecent`가 1인 것을 고르고, 없으면 첫 번째를 쓴다.
    public static func detectAccountName(
        loginUsers: URL? = nil
    ) -> String? {
        let url = loginUsers ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/config/loginusers.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseAccountName(text)
    }

    static func parseAccountName(_ vdf: String) -> String? {
        // VDF는 `"키"  "값"` 줄의 나열이다. 계정 블록마다 AccountName과 MostRecent가 있다.
        var current: String?
        var first: String?
        for line in vdf.split(separator: "\n") {
            let parts = line.split(separator: "\"").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "AccountName" {
                current = value
                if first == nil { first = value }
            } else if key == "MostRecent", value == "1", let account = current {
                return account
            }
        }
        return first
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

    /// 출력에서 로그인 실패를 알아본다.
    /// steamcmd는 로그인에 실패해도 종료 코드가 0일 때가 있어 코드만 보면 놓친다.
    static func indicatesLoginFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("failed to log in")
            || lowered.contains("invalid password")
            || lowered.contains("two-factor")
            || lowered.contains("rate limit exceeded")
            || lowered.contains("cached credentials not found")
    }

    /// 창작마당 아이템을 받아 내려받은 폴더 경로를 돌려준다.
    ///
    /// 자격 증명은 **여기서 다루지 않는다.** steamcmd는 비밀번호와 Steam Guard 코드를
    /// 대화식으로만 받으므로, 사용자가 터미널에서 한 번 `steamcmd +login <계정>`을
    /// 실행해 캐시를 만들어야 한다. 그 뒤로는 이 호출이 비대화식으로 성공한다.
    ///
    /// - Parameter progress: steamcmd 출력 한 줄마다 불린다. 임의 스레드에서 온다.
    @discardableResult
    public func download(
        workshopID: String,
        login: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> URL {
        guard let executable else { throw SteamCmdError.notInstalled }
        // 인자로 그대로 넘어가므로 숫자만 허용한다.
        guard !workshopID.isEmpty, workshopID.allSatisfy(\.isNumber) else {
            throw SteamCmdError.invalidWorkshopID(workshopID)
        }
        guard !login.isEmpty, !login.contains(where: \.isWhitespace) else {
            throw SteamCmdError.loginRequired(account: login)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(
            login: login, workshopID: workshopID, installDirectory: installDirectory
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 대화식 입력을 막는다. 비밀번호를 물어보면 응답이 없어 영원히 멈추는 것보다
        // 바로 실패하는 편이 낫다.
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // 파이프를 끝까지 한 번에 읽으면 출력이 버퍼를 넘길 때 교착한다.
        // steamcmd는 진행률을 계속 뱉으므로 조금씩 읽어야 한다.
        var output = ""
        var pending = ""
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            let text = String(decoding: chunk, as: UTF8.self)
            output += text
            pending += text
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[pending.startIndex..<newline])
                pending = String(pending[pending.index(after: newline)...])
                if !line.isEmpty { progress?(line) }
            }
        }
        if !pending.isEmpty { progress?(pending) }
        process.waitUntilExit()

        if Self.indicatesLoginFailure(output) {
            throw SteamCmdError.loginRequired(account: login)
        }
        guard process.terminationStatus == 0, output.contains("Success. Downloaded item") else {
            throw SteamCmdError.downloadFailed(
                exitCode: process.terminationStatus,
                // 출력이 수천 줄이라 마지막 몇 줄만 남긴다. 원인은 대개 끝에 있다.
                output: String(output.split(separator: "\n").suffix(6).joined(separator: "\n"))
            )
        }

        return installDirectory
            .appendingPathComponent("steamapps/workshop/content")
            .appendingPathComponent(Self.wallpaperEngineAppID)
            .appendingPathComponent(workshopID)
    }
}
