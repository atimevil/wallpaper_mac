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

    /// 프리셋 항목이면 그 알맹이인 창작마당 번호. 프리셋은 다른 배경화면의 설정 묶음이다.
    public let dependencyID: String?
    /// 프리셋이 정한 사용자 속성 값. 사용자가 설정 창에서 바꾼 값이 이 위에 얹힌다.
    public let presetValues: [String: UserPropertyValue]
    /// 프리셋 항목의 폴더. 프리셋이 든 그림·영상(`files/…`)이 여기 있다.
    public let presetDirectory: URL?

    public init(id: String, title: String, type: WallpaperType, directory: URL,
                contentURL: URL, previewURL: URL?, unsupportedReason: String? = nil,
                dependencyID: String? = nil, presetValues: [String: UserPropertyValue] = [:],
                presetDirectory: URL? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.directory = directory
        self.contentURL = contentURL
        self.previewURL = previewURL
        self.unsupportedReason = unsupportedReason
        self.dependencyID = dependencyID
        self.presetValues = presetValues
        self.presetDirectory = presetDirectory
    }

    /// 프리셋의 날것 값을 알맹이의 속성 종류에 맞춰 읽는다.
    ///
    /// 텍스처 속성의 값은 `files/x.gif`처럼 프리셋 폴더 기준 상대 경로다. 절대 경로로
    /// 바꾸되 **프리셋 폴더 밖을 가리키면 버린다** — 창작마당 파일이 `../`로 남의
    /// 파일을 읽게 두면 안 된다.
    public static func presetValues(
        from raw: [String: Any], properties: [UserProperty], presetDirectory: URL
    ) -> [String: UserPropertyValue] {
        let kinds = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.kind) })
        var out: [String: UserPropertyValue] = [:]
        let root = presetDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        for (name, value) in raw {
            guard let kind = kinds[name], let parsed = UserPropertyValue.parse(preset: value, kind: kind)
            else { continue }
            if case .texture = kind, case .text(let relative) = parsed {
                guard !relative.isEmpty else { continue }
                let file = presetDirectory.appendingPathComponent(relative)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(root + "/"),
                      FileManager.default.fileExists(atPath: file.path) else { continue }
                out[name] = .text(file.path)
                continue
            }
            out[name] = parsed
        }
        return out
    }

    /// preview는 확장자가 제각각이라 알려진 이름을 순서대로 찾는다.
    private static let previewNames = [
        "preview.jpg", "preview.png", "preview.gif", "preview.jpeg", "preview.webp",
    ]

    public static func load(from directory: URL) throws -> WallpaperItem {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir),
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

        // `dependency`는 다른 창작마당 항목에 딸린 프리셋이다. 알맹이(씬)는 그쪽에
        // 있고, 이 폴더에는 속성 값(`preset`)과 프리셋이 든 파일(`files/`)만 있다.
        // 알맹이가 옆 폴더에 받아져 있으면 그것을 이 프리셋의 값으로 연다.
        if let dependency = dict["dependency"] as? String, !dependency.isEmpty,
           dict["file"] == nil {
            guard dependency.allSatisfy(\.isNumber) else {
                return unopenable("의존 항목 번호가 이상하다: \(dependency)")
            }
            let base = directory.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent(dependency)
            guard fm.fileExists(atPath: base.appendingPathComponent("project.json").path),
                  let core = try? load(from: base), core.unsupportedReason == nil else {
                return WallpaperItem(
                    id: id, title: title, type: .unsupported, directory: directory,
                    contentURL: jsonURL, previewURL: preview,
                    unsupportedReason: "다른 창작마당 항목(\(dependency))에 딸린 프리셋이다. 그 항목도 받아야 한다",
                    dependencyID: dependency)
            }
            let properties = (try? Data(contentsOf: base.appendingPathComponent("project.json")))
                .map(UserProperty.load(projectJSON:)) ?? []
            let values = presetValues(
                from: dict["preset"] as? [String: Any] ?? [:],
                properties: properties, presetDirectory: directory)
            return WallpaperItem(
                id: id, title: title, type: core.type, directory: core.directory,
                contentURL: core.contentURL, previewURL: preview ?? core.previewURL,
                dependencyID: dependency, presetValues: values, presetDirectory: directory)
        }
        guard let type = try? WallpaperType.from(projectJSON: data) else {
            return unopenable("project.json에 type이 없다")
        }
        guard let file = dict["file"] as? String, !file.isEmpty else {
            return unopenable("project.json에 file이 없다")
        }

        let contentURL = directory.appendingPathComponent(file)

        // video인데 컨테이너 자체를 AVFoundation이 못 여는 경우(.webm, .mkv)는
        // 실제로 재생을 시도해보기 전에 걸러낸다. 그냥 두면 VideoRenderer가
        // 검은 화면만 남기고 왜 안 뜨는지 사용자에게 아무 말도 못 한다.
        if type == .video, let reason = UnsupportedVideoFormat.reason(forFile: contentURL) {
            return unopenable(reason)
        }

        return WallpaperItem(
            id: id,
            title: title,
            type: type,
            directory: directory,
            contentURL: contentURL,
            previewURL: preview
        )
    }
}
