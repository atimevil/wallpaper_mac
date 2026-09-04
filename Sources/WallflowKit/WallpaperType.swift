import Foundation

public enum WallpaperError: Error, Equatable {
    case malformedProjectJSON
    case missingField(String)
    case notADirectory(URL)
}

public enum WallpaperType: String, Sendable, Equatable {
    case video
    case web
    case scene
    case unsupported

    /// project.json의 `type` 필드를 읽는다.
    /// 창작마당 실물 파일에서 "scene"과 "Scene"이 모두 관측되므로 소문자로 정규화한다.
    public static func from(projectJSON data: Data) throws -> WallpaperType {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw WallpaperError.malformedProjectJSON
        }
        guard let raw = dict["type"] as? String else {
            throw WallpaperError.missingField("type")
        }
        return WallpaperType(rawValue: raw.lowercased()) ?? .unsupported
    }
}
