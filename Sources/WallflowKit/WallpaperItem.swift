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
        let type = try WallpaperType.from(projectJSON: data)

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw WallpaperError.malformedProjectJSON
        }
        guard let file = dict["file"] as? String, !file.isEmpty else {
            throw WallpaperError.missingField("file")
        }

        let id = directory.lastPathComponent
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id

        let preview = previewNames
            .map(directory.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }

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
