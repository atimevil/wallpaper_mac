import Foundation

public struct WallpaperItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: WallpaperType
    public let directory: URL
    /// project.json의 `file`이 가리키는 실제 콘텐츠. video면 mp4, web이면 html, scene이면 scene.json.
    public let contentURL: URL

    /// 씬 데이터가 든 `.pkg`. `project.json`의 `file`이 `scene.json`을 가리키면
    /// 실제 데이터는 같은 이름의 `scene.pkg`에 있다.
    ///
    /// 이름이 늘 `scene`인 것은 아니다. 실물 창작마당 씬에 `gifscene.json` /
    /// `gifscene.pkg`인 것이 있다. 하드코딩하면 그런 씬은 통째로 열리지 않는다.
    public var packageURL: URL {
        contentURL.deletingPathExtension().appendingPathExtension("pkg")
    }
    public let previewURL: URL?
    /// 열 수 없는 배경화면이면 그 이유. 열 수 있으면 nil이다.
    ///
    /// **목록에서 조용히 빼지 않는다.** 빼 버리면 사용자는 자기가 받은 것이
    /// 왜 안 보이는지 알 수 없다. 실물에서 `dependency`만 있고 `type`이 없는
    /// 항목(다른 창작마당 항목에 딸린 프리셋)이 그렇게 사라져 있었다.
    public let unsupportedReason: String?

    public init(id: String, title: String, type: WallpaperType, directory: URL,
                contentURL: URL, previewURL: URL?, unsupportedReason: String? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.directory = directory
        self.contentURL = contentURL
        self.previewURL = previewURL
        self.unsupportedReason = unsupportedReason
    }

    /// preview는 확장자가 제각각이라 알려진 이름을 순서대로 찾는다.
    private static let previewNames = [
        "preview.jpg", "preview.png", "preview.gif", "preview.jpeg", "preview.webp",
    ]

    public static func load(from directory: URL) throws -> WallpaperItem {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw WallpaperError.notADirectory(directory)
        }

        let jsonURL = directory.appendingPathComponent("project.json")
        let data = try Data(contentsOf: jsonURL)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw WallpaperError.malformedProjectJSON
        }

        let id = directory.lastPathComponent
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let preview = previewNames
            .map(directory.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }

        // 열 수 없는 항목도 이름과 미리보기를 달아 목록에 남긴다. 이유를 함께
        // 들고 있다가 사용자가 고르면 말해 준다.
        func unopenable(_ reason: String) -> WallpaperItem {
            WallpaperItem(
                id: id, title: title, type: .unsupported, directory: directory,
                contentURL: jsonURL, previewURL: preview, unsupportedReason: reason)
        }

        // `dependency`는 다른 창작마당 항목에 딸린 프리셋이다. 알맹이가 그쪽에
        // 있어서 이 폴더만으로는 열 수 없다.
        if let dependency = dict["dependency"] as? String, !dependency.isEmpty,
           dict["file"] == nil {
            return unopenable(
                "다른 창작마당 항목(\(dependency))에 딸린 프리셋이다. 그 항목도 받아야 한다")
        }
        guard let type = try? WallpaperType.from(projectJSON: data) else {
            return unopenable("project.json에 type이 없다")
        }
        guard let file = dict["file"] as? String, !file.isEmpty else {
            return unopenable("project.json에 file이 없다")
        }

        return WallpaperItem(
            id: id,
            title: title,
            type: type,
            directory: directory,
            contentURL: directory.appendingPathComponent(file),
            previewURL: preview
        )
    }
}
