import Foundation

public enum WorkshopInstallError: Error, Equatable {
    /// steamcmd가 설치되어 있지 않다.
    case steamCmdMissing
    /// 로그인 계정을 모른다.
    case noAccount
    /// steamcmd가 실패했다. 출력 마지막 줄을 함께 남긴다.
    case downloadFailed(String)
    /// 받긴 했는데 폴더가 없다.
    case downloadedFolderMissing(String)
}

/// 창작마당 아이템을 받아 라이브러리에 넣는다.
///
/// 받은 폴더를 **복사하지 않고 링크한다.** 씬 하나가 1GB를 넘기도 하는데 복사하면
/// 디스크를 두 배로 쓴다. `LibraryStore`는 심볼릭 링크를 디렉터리로 인정한다.
public struct WorkshopInstaller: Sendable {
    /// steamcmd가 받은 것들이 쌓이는 곳. 라이브러리와 분리해 둔다 —
    /// 사용자가 라이브러리에서 링크를 지워도 원본은 남고, 다시 받을 필요가 없다.
    public let downloadRoot: URL
    /// `LibraryStore`가 훑는 폴더.
    public let libraryRoot: URL

    public init(downloadRoot: URL, libraryRoot: URL) {
        self.downloadRoot = downloadRoot
        self.libraryRoot = libraryRoot
    }

    /// steamcmd가 아이템을 풀어 놓는 자리.
    public func downloadedFolder(id: String) -> URL {
        downloadRoot
            .appendingPathComponent("steamapps/workshop/content")
            .appendingPathComponent(SteamCmdClient.wallpaperEngineAppID)
            .appendingPathComponent(id)
    }

    /// 이미 받아 둔 아이템인지.
    public func isInstalled(id: String) -> Bool {
        FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(id).path)
    }

    /// 받은 폴더를 라이브러리에 링크한다. 이미 있으면 링크를 다시 건다.
    public func link(id: String) throws {
        let source = downloadedFolder(id: id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkshopInstallError.downloadedFolderMissing(source.path)
        }
        try FileManager.default.createDirectory(
            at: libraryRoot, withIntermediateDirectories: true)

        let destination = libraryRoot.appendingPathComponent(id)
        // 링크가 이미 있으면 지우고 다시 건다. 원본 경로가 바뀌었을 수 있다.
        // 존재 확인에 fileExists를 쓰면 끊어진 링크를 놓치므로 속성으로 본다.
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    /// 라이브러리에서 링크만 걷어낸다. 받아 둔 원본은 그대로 둔다.
    ///
    /// 링크가 아니라 실제 폴더면 지우지 않는다 — 사용자가 직접 넣은 것일 수 있고,
    /// 그걸 지우면 되돌릴 수 없다.
    public func unlink(id: String) throws -> Bool {
        let destination = libraryRoot.appendingPathComponent(id)
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        guard let type = attributes?[.type] as? FileAttributeType else { return false }
        guard type == .typeSymbolicLink else { return false }
        try FileManager.default.removeItem(at: destination)
        return true
    }

    /// 라이브러리에서 빼고 **받아 둔 원본도 지운다.**
    ///
    /// 링크만 걷어내면 디스크에 수백 MB가 남는데 목록에는 안 보여, 사용자는
    /// 그게 남아 있는지 알 길이 없다. 뺀다는 건 없앤다는 뜻이다. 창작마당에서
    /// 언제든 다시 받을 수 있으므로 되돌릴 수 없는 손실은 아니다.
    ///
    /// **우리가 받아 둔 자리(`downloadRoot`) 안의 폴더만 지운다.** 링크가 다른
    /// 곳을 가리키면(사용자가 직접 넣은 폴더) 링크만 걷어내고 원본은 둔다 —
    /// 남의 폴더를 지우는 것은 배경화면 앱이 할 일이 아니다.
    ///
    /// - Returns: 원본까지 지웠으면 `.deletedDownload`, 링크만 걷어냈으면
    ///   `.unlinkedOnly`, 라이브러리에 없었으면 `nil`.
    @discardableResult
    public func remove(id: String) throws -> RemoveOutcome? {
        let destination = libraryRoot.appendingPathComponent(id)
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        guard let type = attributes?[.type] as? FileAttributeType else { return nil }
        guard type == .typeSymbolicLink else {
            // 실제 폴더는 사용자가 직접 넣은 것이다. 손대지 않는다.
            return nil
        }
        let target = URL(fileURLWithPath: try FileManager.default
            .destinationOfSymbolicLink(atPath: destination.path))
        try FileManager.default.removeItem(at: destination)

        // 우리 자리 안인지 경로를 정규화해 견준다. 링크 문자열만 보면
        // `..`나 대소문자로 빠져나갈 수 있다.
        let ours = downloadRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(ours + "/"),
              resolved.count > ours.count + 1,
              FileManager.default.fileExists(atPath: resolved) else {
            return .unlinkedOnly
        }
        try FileManager.default.removeItem(atPath: resolved)
        return .deletedDownload
    }

    public enum RemoveOutcome: Equatable, Sendable {
        case deletedDownload
        case unlinkedOnly
    }
}
