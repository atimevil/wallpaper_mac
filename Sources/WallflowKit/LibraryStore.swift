import Foundation

/// 배경화면 라이브러리 디렉터리를 읽는다.
/// 창작마당 구조는 <root>/<워크샵ID>/project.json 이다.
public struct LibraryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 라이브러리를 스캔한다. 읽을 수 없는 항목은 건너뛴다.
    /// 배경화면 하나가 깨졌다고 목록 전체를 못 쓰게 만들지 않는다.
    public func scan() throws -> [WallpaperItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return entries
            .filter(Self.isDirectory)
            .compactMap { try? WallpaperItem.load(from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 심볼릭 링크도 디렉터리로 인정한다.
    /// 배경화면은 용량이 커서 라이브러리 밖에 두고 링크로 참조하는 것이 자연스럽고,
    /// URL의 isDirectoryKey는 링크 자체를 보므로 디렉터리로 판정하지 않는다.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        // fileExists는 링크를 따라가므로 대상이 디렉터리면 true를 준다.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
