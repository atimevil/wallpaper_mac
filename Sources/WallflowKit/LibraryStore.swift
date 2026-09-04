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
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { try? WallpaperItem.load(from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
