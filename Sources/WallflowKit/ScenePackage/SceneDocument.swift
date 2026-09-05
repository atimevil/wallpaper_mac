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
        try load(from: reader, assets: nil)
    }

    public static func load(
        from reader: PkgReader, assets: AssetsStore?
    ) throws -> SceneDocument {
        let raw = try reader.data(for: "scene.json")
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw SceneError.malformedSceneJSON
        }

        let general = root["general"] as? [String: Any] ?? [:]
        guard let ortho = general["orthogonalprojection"] as? [String: Any],
              let width = ortho["width"] as? Int,
              let height = ortho["height"] as? Int,
              width > 0, height > 0 else {
            throw SceneError.missingField("orthogonalprojection")
        }

        let clearColor = (general["clearcolor"] as? String).flatMap(Vec3.parse)
            ?? Vec3(x: 0, y: 0, z: 0)
        let clearEnabled = general["clearenabled"] as? Bool ?? true

        let resolver = ReferenceResolver(pkg: reader, assets: assets)

        // 배열 조건부 캐스트는 전부-아니면-전무다. 원소 하나가 딕셔너리가 아니면
        // 통째로 실패해 정상 레이어까지 사라진다. 원소별로 걸러 그것을 막는다.
        let rawObjects = root["objects"] as? [Any] ?? []
        let objects = rawObjects.compactMap { $0 as? [String: Any] }
        let layers = objects.enumerated().map { index, object in
            makeLayer(object, fallbackID: index, resolver: resolver)
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
        _ object: [String: Any], fallbackID: Int, resolver: ReferenceResolver
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

        let content = resolveContent(modelPath: modelPath, object: object, resolver: resolver)
        return SceneLayer(
            id: id, name: name, visible: visible,
            origin: origin, size: size,
            content: content
        )
    }

    /// 머티리얼을 읽어 이 레이어가 무엇인지 판정한다.
    private static func resolveContent(
        modelPath: String, object: [String: Any], resolver: ReferenceResolver
    ) -> LayerContent {
        guard let model = resolver.json(for: modelPath),
              let materialPath = model["material"] as? String,
              let material = resolver.json(for: materialPath),
              let passes = material["passes"] as? [[String: Any]],
              let pass = passes.first else {
            return .unsupported(reason: "참조를 따라갈 수 없다: \(modelPath)")
        }

        let textures = pass["textures"] as? [Any]
        // 셰이더 flat은 텍스처 없이 색만 칠한다. 못 찾은 것이 아니라 원래 없다.
        if (pass["shader"] as? String) == "flat" || textures == nil {
            let color = (object["color"] as? String).flatMap(Vec3.parse)
                ?? Vec3(x: 1, y: 1, z: 1)
            return .solidColor(color)
        }
        guard let name = textures?.first as? String else {
            return .unsupported(reason: "머티리얼의 첫 텍스처가 없다: \(materialPath)")
        }
        // _rt_ 접두는 파일이 아니라 렌더 타깃이다. FBO 체인이 필요하다.
        if name.hasPrefix("_rt_") {
            return .unsupported(reason: "렌더 타깃 참조라 M6의 이펙트 체인이 필요하다: \(name)")
        }
        return .image(texturePath: "materials/\(name).tex")
    }
}
