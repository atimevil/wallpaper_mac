import Foundation

public enum SceneError: Error, Equatable {
    case malformedSceneJSON
    case missingField(String)
}

/// scene.json과 그것이 참조하는 models/·materials/를 따라가
/// "무엇을 어디에 그릴지"의 목록으로 바꾼다.
///
/// 참조 사슬 (실물에서 확인):
///   object.image → models/X.json의 "material"
///                → materials/Y.json의 passes[0].textures[0]
///                → materials/<그 이름>.tex
public struct SceneDocument: Sendable {
    public let orthoWidth: Int
    public let orthoHeight: Int
    public let clearColor: Vec3
    public let clearEnabled: Bool
    public let layers: [SceneLayer]

    public static func load(from reader: PkgReader) throws -> SceneDocument {
        let raw = try reader.data(for: "scene.json")
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }

        let general = root["general"] as? [String: Any] ?? [:]
        guard let ortho = general["orthogonalprojection"] as? [String: Any],
              let width = ortho["width"] as? Int,
              let height = ortho["height"] as? Int else {
            throw SceneError.missingField("orthogonalprojection")
        }

        let clearColor = (general["clearcolor"] as? String).flatMap(Vec3.parse)
            ?? Vec3(x: 0, y: 0, z: 0)
        let clearEnabled = general["clearenabled"] as? Bool ?? true

        let objects = root["objects"] as? [[String: Any]] ?? []
        let layers = objects.enumerated().map { index, object in
            makeLayer(object, fallbackID: index, reader: reader)
        }

        return SceneDocument(
            orthoWidth: width, orthoHeight: height,
            clearColor: clearColor, clearEnabled: clearEnabled,
            layers: layers
        )
    }

    /// 레이어 하나가 해석되지 않아도 씬 전체를 버리지 않는다.
    /// 그릴 수 없는 것은 이유를 달아 unsupported로 남긴다.
    private static func makeLayer(
        _ object: [String: Any], fallbackID: Int, reader: PkgReader
    ) -> SceneLayer {
        let id = object["id"] as? Int ?? fallbackID
        let name = object["name"] as? String ?? "object\(fallbackID)"
        let visible = object["visible"] as? Bool ?? true

        // origin/scale이 문자열이 아니라 {"script": ...} 객체인 씬이 실제로 있다.
        let origin = (object["origin"] as? String).flatMap(Vec3.parse)
        let size = (object["size"] as? String).flatMap(Vec2.parse)

        func unsupported(_ reason: String) -> SceneLayer {
            SceneLayer(
                id: id, name: name, visible: visible,
                origin: origin ?? Vec3(x: 0, y: 0, z: 0),
                size: size ?? Vec2(x: 0, y: 0),
                content: .unsupported(reason: reason)
            )
        }

        guard let modelPath = object["image"] as? String else {
            if object["particle"] != nil { return unsupported("파티클은 M3에서 지원한다") }
            if object["text"] != nil { return unsupported("텍스트는 M3에서 지원한다") }
            if object["sound"] != nil { return unsupported("사운드는 M4에서 지원한다") }
            return unsupported("알 수 없는 레이어 종류")
        }
        guard let origin, let size else {
            return unsupported("origin이나 size가 스크립트다. 스크립팅은 M4에서 지원한다")
        }
        guard let texturePath = resolveTexture(modelPath: modelPath, reader: reader) else {
            return unsupported("텍스처 참조를 따라갈 수 없다: \(modelPath)")
        }

        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: .image(texturePath: texturePath)
        )
    }

    private static func resolveTexture(modelPath: String, reader: PkgReader) -> String? {
        guard let modelData = try? reader.data(for: modelPath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = try? reader.data(for: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [[String: Any]],
              let textures = passes.first?["textures"] as? [Any],
              // 첫 항목이 null인 머티리얼이 실제로 있다 (waterripple).
              let name = textures.first as? String
        else { return nil }

        return "materials/\(name).tex"
    }
}
